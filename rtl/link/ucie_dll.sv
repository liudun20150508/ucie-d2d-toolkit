// =============================================================================
// ucie_dll : D2D Adapter / Data Link Layer（数据链路层）
// -----------------------------------------------------------------------------
// 对应 UCIe 协议栈「适配层（D2D Adapter）」的数字实现，是本 demo 的核心：
//   A. 发送方向：本地 64B 事务 -> flit 组包 -> retry buffer -> 链路
//   B. 接收方向：链路 flit -> 拆包/CRC 校验 -> seq 检查 -> 交付本地
//   C. 可靠性：正确收到 -> 累积 ACK；CRC 错 / seq 跳号 -> NAK 触发重传
//   D. 流控：credit-based（发送消耗信用，接收侧按交付返还，ACK flit 顺带携带）
//   E. 仲裁：控制 flit（ACK/NAK/CREDIT）优先于数据 flit，共享同一条 flit 通道
//
// 结构约定（有意为之）：
//   * 全部决策写在唯一的 always_comb 里（push_en / credit / ack-nak 事件），
//     全部状态更新写在唯一的 always_ff 里。避免多驱动与竞态——
//     这是可综合 RTL 能过 lint 又能过形式化检查的基本纪律。
//   * 控制 flit 的 payload 布局：byte0=msg, byte1=arg, byte2=aux(credit 数)
// =============================================================================
`ifndef UCIE_DLL_SV
`define UCIE_DLL_SV

module ucie_dll #(
    parameter int ACK_EVERY       = 1,   // 累积 ACK 间隔（1 = 每个数据 flit 立即确认）
    parameter int RETRY_TIMEOUT   = 48,  // 重传超时（本地时钟周期）
    parameter int CTRL_FIFO_DEPTH = 8,
    parameter int RX_FIFO_DEPTH   = 4
)(
    input  logic clk,
    input  logic rst_n,

    // ---------------- 协议层侧（本地，64B 事务）----------------
    input  logic        l_tx_valid,
    output logic        l_tx_ready,
    input  logic [ucie_pkg::FLIT_PAYLOAD_BYTES*8-1:0] l_tx_data,

    output logic        l_rx_valid,
    input  logic        l_rx_ready,
    output logic [ucie_pkg::FLIT_PAYLOAD_BYTES*8-1:0] l_rx_data,

    // ---------------- 链路侧（对端 flit 流）----------------
    output logic        lnk_tx_valid,
    output ucie_pkg::flit_t lnk_tx_flit,
    input  logic        lnk_tx_ready,

    input  logic        lnk_rx_valid,
    input  ucie_pkg::flit_t lnk_rx_flit,
    output logic        lnk_rx_ready,

    // ---------------- 遥测 / 上报 ----------------
    output logic [15:0] st_delivered,
    output logic [15:0] st_crc_err,
    output logic [15:0] st_ack_sent,
    output logic [15:0] st_nak_sent,
    output logic [15:0] st_credit_sent,
    output logic [15:0] st_duplicate,
    output logic [15:0] st_retry,
    output logic [7:0]  st_inflight,
    output logic [7:0]  st_credit_left,
    output logic        link_error,          // 不可恢复错误上报（供 LTSSM 重训/降级）
    input  logic        clr_link_error
);
    import ucie_pkg::*;

    localparam int CTRL_IDX_W = $clog2(CTRL_FIFO_DEPTH);
    localparam int RX_IDX_W   = $clog2(RX_FIFO_DEPTH);
    localparam logic [7:0] CREDIT_MAX = 8'd32;

    // =========================================================================
    // A. 发送方向：事务 -> flit -> retry buffer -> 链路
    // =========================================================================
    logic        credit_ok;
    logic        ftx_valid, ftx_ready;
    flit_t       ftx_flit;
    logic [7:0]  credit_cnt;
    logic        rty_out_valid, rty_out_ready;
    flit_t       rty_out_flit;

    assign credit_ok  = (credit_cnt != 8'h00);
    assign l_tx_ready = ftx_ready && credit_ok;

    ucie_flit_tx u_flit_tx (
        .clk        (clk),
        .rst_n      (rst_n),
        .tx_valid   (l_tx_valid && credit_ok),
        // 注意：这里**不能**连 .tx_ready —— 它与 .flit_ready 同义，
        // 两边都连会与 retry 的 in_ready 形成组合环（Verilator 直接报 circular logic）
        .tx_data    (l_tx_data),
        .flit_valid (ftx_valid),
        .flit       (ftx_flit),
        .flit_ready (ftx_ready),
        .seq_out    (),
        .hdr_out    ()
    );

    logic        ack_valid, nak_valid;
    logic [7:0]  ack_seq, nak_seq;

    ucie_link_retry #(
        .DEPTH          (RETRY_BUF_DEPTH),
        .TIMEOUT_CYCLES (RETRY_TIMEOUT)
    ) u_retry (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (ftx_valid),
        .in_flit   (ftx_flit),
        .in_ready  (ftx_ready),
        .out_valid (rty_out_valid),
        .out_flit  (rty_out_flit),
        .out_ready (rty_out_ready),
        .ack_valid (ack_valid),
        .ack_seq   (ack_seq),
        .nak_valid (nak_valid),
        .nak_seq   (nak_seq),
        .inflight  (st_inflight),
        .retry_cnt (st_retry)
    );

    // =========================================================================
    // C-1. 控制 flit 队列（ACK / NAK / CREDIT），一拍最多入队一条
    // =========================================================================
    logic [23:0]         cq_mem [0:CTRL_FIFO_DEPTH-1];
    logic [CTRL_IDX_W:0] cq_wr, cq_rd;
    logic                cq_pop, cq_empty, cq_full;
    logic [23:0]         cq_dout;

    assign cq_empty = (cq_wr == cq_rd);
    assign cq_full  = ((cq_wr - cq_rd) == CTRL_FIFO_DEPTH[CTRL_IDX_W:0]);
    assign cq_dout  = cq_mem[cq_rd[CTRL_IDX_W-1:0]];

    logic        ctrl_valid;
    flit_t       ctrl_flit;

    assign ctrl_valid = !cq_empty;

    always_comb begin
        flit_hdr_t ch;
        logic [FLIT_PAYLOAD_BYTES*8-1:0] cp;
        ch = '{rsvd: 1'b0, fmt: FMT_CTRL, proto: PROTO_MGMT, seq: 8'h00};
        cp = {488'b0, cq_dout};       // byte0=msg, byte1=arg, byte2=aux
        ctrl_flit = flit_pack(ch, cp, crc16_flit(ch, cp));
    end

    // 控制 flit 优先仲裁（与 UCIe 中控制 flit 占同一 flit 通道一致）
    assign lnk_tx_valid  = ctrl_valid | rty_out_valid;
    assign lnk_tx_flit   = ctrl_valid ? ctrl_flit : rty_out_flit;
    assign rty_out_ready = lnk_tx_ready && !ctrl_valid;
    assign cq_pop        = ctrl_valid && lnk_tx_ready;

    // =========================================================================
    // B. 接收方向：拆包 + CRC 校验
    // =========================================================================
    logic        frx_valid, frx_ready;
    logic [FLIT_PAYLOAD_BYTES*8-1:0] frx_data;
    flit_hdr_t   frx_hdr;
    logic        frx_crc_ok;

    assign frx_ready = 1'b1;     // 单拍处理完，无背压

    ucie_flit_rx u_flit_rx (
        .clk           (clk),
        .rst_n         (rst_n),
        .flit_valid    (lnk_rx_valid),
        .flit          (lnk_rx_flit),
        .flit_ready    (lnk_rx_ready),
        .out_valid     (frx_valid),
        .out_ready     (frx_ready),
        .out_data      (frx_data),
        .out_hdr       (frx_hdr),
        .out_crc_ok    (frx_crc_ok),
        .crc_err_pulse ()
    );

    // ---------------- 接收交付 FIFO（把交付与本地 ready 解耦）----------------
    logic [FLIT_PAYLOAD_BYTES*8-1:0] rxf_mem [0:RX_FIFO_DEPTH-1];
    logic [RX_IDX_W:0]               rxf_wr, rxf_rd;
    logic                            rxf_empty, rxf_full, rxf_pop;

    assign rxf_empty = (rxf_wr == rxf_rd);
    assign rxf_full  = ((rxf_wr - rxf_rd) == RX_FIFO_DEPTH[RX_IDX_W:0]);
    assign l_rx_valid = !rxf_empty;
    assign l_rx_data  = rxf_mem[rxf_rd[RX_IDX_W-1:0]];
    assign rxf_pop    = l_rx_valid && l_rx_ready;

    // =========================================================================
    // 决策（组合）：一拍内产生至多一条控制 flit + 一个交付
    // =========================================================================
    logic [7:0]  exp_seq, ack_cnt;
    logic        push_en;
    logic [23:0] push_data;
    logic        rxf_push_en;
    logic [7:0]  credit_dec, credit_inc;
    logic        ack_now, nak_now, linkerr_now;
    logic [7:0]  ack_now_seq, nak_now_seq, ctrl_msg_in;
    logic        rx_crc_bad, rx_dup, rx_gap, rx_ok_new;
    logic        push_ack, push_nak, push_credit;

    assign ctrl_msg_in = frx_data[7:0];

    always_comb begin
        push_en     = 1'b0;
        push_data   = 24'h0;
        rxf_push_en = 1'b0;
        credit_dec  = 8'd0;
        credit_inc  = 8'd0;
        ack_now     = 1'b0;
        nak_now     = 1'b0;
        linkerr_now = 1'b0;
        ack_now_seq = 8'h00;
        nak_now_seq = 8'h00;

        // 信用消耗：数据 flit 真正进入 retry 窗口
        if (ftx_valid && ftx_ready) credit_dec = 8'd1;

        if (frx_valid && frx_ready) begin
            if (frx_hdr.fmt == FMT_CTRL) begin
                unique case (ctrl_msg_in)
                    DLL_MSG_ACK: begin
                        ack_now     = 1'b1;
                        ack_now_seq = frx_data[15:8];
                        credit_inc  = frx_data[23:16];   // ACK 顺带携带返还的信用
                    end
                    DLL_MSG_NAK: begin
                        nak_now     = 1'b1;
                        nak_now_seq = frx_data[15:8];
                    end
                    DLL_MSG_CREDIT: credit_inc = frx_data[15:8];
                    DLL_MSG_LINKERR: linkerr_now = 1'b1;
                    default: ;
                endcase
            end else if (!frx_crc_ok) begin
                // CRC 失败 -> NAK(期望序号)，让对端从 exp_seq 重发
                push_en   = !cq_full;
                push_data = {8'h00, exp_seq, DLL_MSG_NAK};
            end else if (frx_hdr.fmt == FMT_DATA) begin
                if (frx_hdr.seq == exp_seq) begin
                    rxf_push_en = 1'b1;
                    if ((ack_cnt + 8'd1) >= ACK_EVERY[7:0]) begin
                        push_en   = !cq_full;
                        push_data = {8'd01, frx_hdr.seq, DLL_MSG_ACK};   // aux=返还 1 个信用
                    end
                end else if ((frx_hdr.seq - exp_seq) > 8'd128) begin
                    // 序号“更旧”的副本：说明是对端重传，去重后再确认一次
                    push_en   = !cq_full;
                    push_data = {8'h00, frx_hdr.seq, DLL_MSG_ACK};
                end else begin
                    // 跳号：中间丢失，请求从 exp_seq 重传
                    push_en   = !cq_full;
                    push_data = {8'h00, exp_seq, DLL_MSG_NAK};
                end
            end
            // FMT_NULL / FMT_TRAIN 在此阶段无链路层语义，直接丢弃
        end
    end

    assign push_ack    = push_en && (push_data[7:0] == DLL_MSG_ACK);
    assign push_nak    = push_en && (push_data[7:0] == DLL_MSG_NAK);
    assign push_credit = push_en && (push_data[23:16] != 8'h00);

    assign rx_crc_bad = frx_valid && frx_ready && (frx_hdr.fmt != FMT_CTRL) && !frx_crc_ok;
    assign rx_ok_new  = rxf_push_en;
    assign rx_dup     = frx_valid && frx_ready && (frx_hdr.fmt == FMT_DATA) && frx_crc_ok &&
                        (frx_hdr.seq != exp_seq) && ((frx_hdr.seq - exp_seq) > 8'd128);
    assign rx_gap     = frx_valid && frx_ready && (frx_hdr.fmt == FMT_DATA) && frx_crc_ok &&
                        (frx_hdr.seq != exp_seq) && ((frx_hdr.seq - exp_seq) <= 8'd128);

    // 信用：先扣后加，饱和到 CREDIT_MAX
    logic [8:0] credit_raw;
    assign credit_raw = {1'b0, credit_cnt} - {1'b0, credit_dec} + {1'b0, credit_inc};

    // =========================================================================
    // 唯一的状态更新点
    // =========================================================================
    logic [15:0] delivered_q, crc_err_q, ack_sent_q, nak_sent_q, credit_sent_q, dup_q;
    logic        link_error_q;

    assign st_delivered   = delivered_q;
    assign st_crc_err     = crc_err_q;
    assign st_ack_sent    = ack_sent_q;
    assign st_nak_sent    = nak_sent_q;
    assign st_credit_sent = credit_sent_q;
    assign st_duplicate   = dup_q;
    assign st_credit_left = credit_cnt;
    assign link_error     = link_error_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cq_wr         <= '0;
            cq_rd         <= '0;
            rxf_wr        <= '0;
            rxf_rd        <= '0;
            exp_seq       <= 8'h00;
            ack_cnt       <= 8'h00;
            credit_cnt    <= CREDIT_INIT[7:0];
            ack_valid     <= 1'b0;
            nak_valid     <= 1'b0;
            ack_seq       <= 8'h00;
            nak_seq       <= 8'h00;
            delivered_q   <= 16'h0000;
            crc_err_q     <= 16'h0000;
            ack_sent_q    <= 16'h0000;
            nak_sent_q    <= 16'h0000;
            credit_sent_q <= 16'h0000;
            dup_q         <= 16'h0000;
            link_error_q  <= 1'b0;
        end else begin
            // ---- 控制 flit 队列 ----
            if (cq_pop) cq_rd <= cq_rd + 1'b1;
            if (push_en) begin
                cq_mem[cq_wr[CTRL_IDX_W-1:0]] <= push_data;
                cq_wr <= cq_wr + 1'b1;
            end

            // ---- 交付 FIFO ----
            if (rxf_push_en && !rxf_full) begin
                rxf_mem[rxf_wr[RX_IDX_W-1:0]] <= frx_data;
                rxf_wr <= rxf_wr + 1'b1;
            end
            if (rxf_pop) rxf_rd <= rxf_rd + 1'b1;

            // ---- 接收序号跟踪 ----
            if (rx_ok_new) begin
                exp_seq     <= exp_seq + 8'd1;
                delivered_q <= delivered_q + 16'd1;
                ack_cnt     <= push_ack ? 8'h00 : (ack_cnt + 8'd1);
            end

            // ---- 对端反馈事件（单拍脉冲）----
            ack_valid <= ack_now;
            nak_valid <= nak_now;
            if (ack_now) ack_seq <= ack_now_seq;
            if (nak_now) nak_seq <= nak_now_seq;

            // ---- 信用 ----
            credit_cnt <= (credit_raw > {1'b0, CREDIT_MAX}) ? CREDIT_MAX : credit_raw[7:0];

            // ---- 统计 ----
            if (rx_crc_bad)    crc_err_q     <= crc_err_q + 16'd1;
            if (rx_dup)        dup_q         <= dup_q + 16'd1;
            if (push_ack)      ack_sent_q    <= ack_sent_q + 16'd1;
            if (push_nak)      nak_sent_q    <= nak_sent_q + 16'd1;
            if (push_credit)   credit_sent_q <= credit_sent_q + 16'd1;

            // ---- 链路错误上报（可清除）----
            if (clr_link_error)   link_error_q <= 1'b0;
            else if (linkerr_now) link_error_q <= 1'b1;
        end
    end

    // =========================================================================
    // 断言：把“绝不该发生”的事写成 SVA，交给仿真/形式化
    // =========================================================================
`ifndef SYNTHESIS
    // 工具会把断言里的 disable iff(!rst_n) 记作“同步复位使用”，而本模块寄存器
    // 用的是异步复位，于是报 SYNCASYNCNET。断言语义没有问题（disable iff 本身
    // 就是异步语义），这里局部抑制。
    // 坑：注释不能写成“// verilator ...”，那本身就是 pragma 语法，
    //     内容不被识别时会直接报 BADVLTPRAGMA。
    // verilator lint_off SYNCASYNCNET
    a_ctrl_no_drop: assert property (@(posedge clk) disable iff (!rst_n)
        (frx_valid && (frx_hdr.fmt != FMT_CTRL) && frx_crc_ok && (frx_hdr.fmt == FMT_DATA))
        |-> (rxf_push_en || push_nak || push_ack));

    a_rxf_no_overflow: assert property (@(posedge clk) disable iff (!rst_n)
        (rxf_push_en |-> !rxf_full));

    a_credit_range: assert property (@(posedge clk) disable iff (!rst_n)
        (credit_cnt <= CREDIT_MAX));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_DLL_SV
