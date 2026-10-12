// =============================================================================
// ucie_axi_slv_rx : 协议层字节流 -> AXI4 **slave 端口**的写响应(B) / 读数据(R)
// -----------------------------------------------------------------------------
// 位置：字节流容器（ucie_stream_unpack）与 AXI4 master 的 B/R 通道之间。
//
// 解析规则（事务自描述 + IDLE padding，见 docs/PROTOCOL.md）：
//   * 在**事务边界**读到 0x00 -> 是 flit 尾部 padding，逐个丢弃；
//   * 读到 16 B 事务头 -> 按 txn_type 分派：
//       TXN_WR_RESP -> 驱动 B 通道（一拍）
//       TXN_RD_DATA -> 记下 id/rresp/拍数，进入数据阶段
//       其他类型    -> 不该出现在 master 侧，计错误并丢弃该头
//   * 数据阶段：一个 beat = 1 B beat 头 + 64 B 数据 = 65 B，凑够就驱动 R 通道。
//
// 缓冲策略：维护一个 96 B 的移位累加器，同一拍内“先追加后消费”：
//   追加把 unpack 给的 16 B 写到高端，消费把低端的字段移走。这样 65 B 的
//   beat 跨 UI 也不需要额外握手。
// =============================================================================
`ifndef UCIE_AXI_SLV_RX_SV
`define UCIE_AXI_SLV_RX_SV

module ucie_axi_slv_rx (
    input  logic clk,
    input  logic rst_n,

    // ---- 来自 ucie_stream_unpack 的字节流 ----
    input  logic         st_valid,
    input  logic [127:0] st_data,
    input  logic [4:0]   st_bytes,
    output logic [4:0]   st_taken,

    // ---- AXI4 B（写响应）----
    output logic       bvalid,
    input  logic       bready,
    output logic [3:0] bid,
    output logic [1:0] bresp,

    // ---- AXI4 R（读数据）----
    output logic         rvalid,
    input  logic         rready,
    output logic [3:0]   rid,
    output logic [511:0] rdata,
    output logic [1:0]   rresp,
    output logic         rlast,

    // ---- 统计 ----
    output logic [15:0]  cnt_b,
    output logic [15:0]  cnt_r,
    output logic [15:0]  cnt_err
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    localparam int ACC_BYTES = 96;            // 66B beat + 16B UI + 余量（96 是 16 的整数倍）
    localparam int ACC_W     = ACC_BYTES * 8;
    localparam int BEAT_BYTES = DATA_BEAT_BYTES;   // 66（1B 类型 + 1B beat 头 + 64B 数据）

    // =========================================================================
    // 累加器
    // =========================================================================
    logic [ACC_W-1:0] acc_q, acc_c;
    logic [7:0]       cnt_q, cnt_c;

    typedef enum logic [1:0] { P_HDR, P_BRESP, P_DATA } ps_e;
    ps_e        ps_q, ps_c;

    logic [7:0]  id_q;         // 当前读事务的 AXI ID
    logic [1:0]  rresp_q;
    logic [7:0]  beat_left_q, beat_left_c;
    logic [1:0]  bresp_q;
    logic [7:0]  bid_q;

    // =========================================================================
    // 解析决策（组合）
    // =========================================================================
    wire at_boundary = (ps_q == P_HDR);
    wire is_pad      = at_boundary && (cnt_q != 8'd0) && (acc_q[7:0] == PAD_BYTE);
    wire is_hdr      = at_boundary && (cnt_q >= HDR_BYTES[7:0]) && (acc_q[7:0] != PAD_BYTE);
    wire is_beat     = (ps_q == P_DATA) && (cnt_q >= BEAT_BYTES[7:0]);

    wire [7:0] hdr_type  = is_hdr ? acc_q[7:0] : 8'h00;
    wire       rd_data_t = is_hdr && (hdr_type == TXN_RD_DATA);
    wire       wr_resp_t = is_hdr && (hdr_type == TXN_WR_RESP);
    wire       illegal_t = is_hdr && !rd_data_t && !wr_resp_t;

    // B/R 通道握手
    wire b_fire = bvalid && bready;
    wire r_fire = rvalid && rready;

    assign bvalid = (ps_q == P_BRESP);
    assign bid    = bid_q[3:0];
    assign bresp  = bresp_q;

    assign rvalid = is_beat;
    assign rid    = id_q[3:0];
    assign rdata  = acc_q[2*8 +: AXI_DATA_W];   // 跳过 1B 类型码 + 1B beat 头
    assign rresp  = rresp_q;
    assign rlast  = is_beat && acc_q[12];   // beat 头（byte1）的 bit4 = RLAST（由 mst_tx 携带）

    // =========================================================================
    // 本拍消费多少字节
    // =========================================================================
    logic [7:0] consume_b;
    always_comb begin
        consume_b = 8'd0;
        if (is_pad)                       consume_b = 8'd1;              // 丢 padding
        else if (is_hdr)                  consume_b = HDR_BYTES[7:0];    // 16
        else if (is_beat && rready)       consume_b = BEAT_BYTES[7:0];   // 65
    end

    // =========================================================================
    // 追加 + 消费（同一拍内先追加到高端，再把低端移走）
    // =========================================================================
    wire [8:0] room9       = {1'b0, ACC_BYTES[7:0]} - {1'b0, cnt_q};
    wire       can_append  = st_valid && ({1'b0, st_bytes} <= room9 + {1'b0, consume_b});

    assign st_taken = can_append ? st_bytes : 5'd0;

    always_comb begin
        acc_c = acc_q;
        cnt_c = cnt_q;

        // 1) 追加本拍字节流
        if (can_append) begin
            for (int i = 0; i < 16; i++) begin
                if (i[4:0] < st_bytes) begin
                    acc_c[(cnt_q + i[7:0])*8 +: 8] = st_data[i*8 +: 8];
                end
            end
            cnt_c = cnt_q + st_bytes;
        end

        // 2) 消费低端字段
        if (consume_b != 8'd0) begin
            acc_c = acc_c >> (consume_b * 8);
            cnt_c = cnt_c - consume_b;
        end

        // 3) 状态推进
        ps_c        = ps_q;
        beat_left_c = beat_left_q;
        if (ps_q == P_BRESP) begin
            if (bready) ps_c = P_HDR;
        end else if (is_pad) begin
            // 继续丢 padding，留在 P_HDR
        end else if (wr_resp_t) begin
            ps_c = P_BRESP;
        end else if (rd_data_t) begin
            ps_c        = P_DATA;      // burst 长度由 beat 头的 last 位指示，不依赖头里的 len
            beat_left_c = 8'd0;
        end else if (illegal_t) begin
            ps_c = P_HDR;
        end else if (is_beat && rready) begin
            if (acc_q[12]) ps_c = P_HDR;   // 本 beat 的 RLAST 置起 -> burst 结束
            else           beat_left_c = beat_left_q;
        end
    end

    // =========================================================================
    // 时序
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_q       <= '0;
            cnt_q       <= 8'd0;
            ps_q        <= P_HDR;
            id_q        <= 8'd0;
            rresp_q     <= RESP_OKAY;
            beat_left_q <= 8'd0;
            bresp_q     <= RESP_OKAY;
            bid_q       <= 8'd0;
            cnt_b       <= 16'd0;
            cnt_r       <= 16'd0;
            cnt_err     <= 16'd0;
        end else begin
            acc_q       <= acc_c;
            cnt_q       <= cnt_c;
            ps_q        <= ps_c;
            beat_left_q <= beat_left_c;

            if (rd_data_t) begin
                id_q    <= acc_q[8 +: 8];       // byte1 = AXI ID
                rresp_q <= acc_q[14*8 +: 2];    // byte14[1:0] = RRESP
            end
            if (wr_resp_t) begin
                bid_q   <= acc_q[8 +: 8];
                bresp_q <= acc_q[11*8 +: 2];    // byte11[1:0] = BRESP
            end

            if (b_fire) cnt_b <= cnt_b + 16'd1;
            if (r_fire) cnt_r <= cnt_r + 16'd1;
            if (illegal_t) cnt_err <= cnt_err + 16'd1;
        end
    end

`ifndef SYNTHESIS
    // 同前：disable iff 的复位被判为同步使用，局部抑制 SYNCASYNCNET
    // verilator lint_off SYNCASYNCNET
    // 累加器不越界
    a_acc: assert property (@(posedge clk) disable iff (!rst_n)
        (cnt_q <= ACC_BYTES[7:0]));
    // P_DATA 状态只处理数据 beat，不应再出现非法事务头
    // （原先这里是"beat 数不能为 0"的断言，改用 beat 头 RLAST 判 burst 结束后已失效）
    a_no_illegal_in_data: assert property (@(posedge clk) disable iff (!rst_n)
        ((ps_q == P_DATA)) |-> !illegal_t);
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_AXI_MASTER_RX_SV
