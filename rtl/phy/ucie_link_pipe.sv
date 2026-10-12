// =============================================================================
// ucie_link_pipe : 单向 D2D 链路管道
//   [发送侧本地域 lclk_tx] -> AFIFO -> [链路域 rdi_clk] RDI TX -> 物理 lane
//     -> (错误注入点) -> RDI RX -> AFIFO -> [接收侧本地域 lclk_rx]
// -----------------------------------------------------------------------------
// 这是把「协议层 flit 流」和「物理链路」粘起来的一层，对应真实芯片里
// D2D 控制器与 PHY 之间的那段逻辑：
//   * 两个异步 FIFO 完成 lclk <-> rdi_clk 的跨时钟域（CDC）
//   * RDI TX/RX 完成 flit <-> lane 字节流的串并转换
//   * err_inject 是**验证专用**的错误注入点（模拟链路误码）
//
// 三个时钟域各自独立：发送侧本地域、链路域、接收侧本地域。
// 复位一律用异步低有效（与 AFIFO 内部风格一致）——混用同步/异步复位会让
// CDC 检查工具报 SYNCASYNCNET，且真实芯片上跨域复位本来就该是异步的。
// =============================================================================
`ifndef UCIE_LINK_PIPE_SV
`define UCIE_LINK_PIPE_SV

module ucie_link_pipe #(
    // 低功耗：数据门控透传到 ucie_rdi_tx（0=原版 1=门控）。
    // 参数化的目的：同一份 RTL 能综合出"基线/门控"两个版本做功能等价对比
    parameter int DATA_GATING = 0
) (
    // 发送侧本地域
    input  logic lclk_tx,
    input  logic lrst_tx_n,
    // 接收侧本地域
    input  logic lclk_rx,
    input  logic lrst_rx_n,
    // 链路（RDI）域
    input  logic rdi_clk,
    input  logic rrst_n,

    // 训练结果
    input  logic [ucie_pkg::LANES-1:0] lane_valid,
    input  logic                       pipe_enable,   // 仅 ACTIVE 时放行

    // lane 间去偏斜（deskew）：MBTRAIN 期间测量，之后按 per-lane 值对齐
    input  logic deskew_train,     // 1 = 链路处于 MBTRAIN（测量偏斜）
    input  logic deskew_clr,       // 进 MBTRAIN 时清一次测量结果

    // 验证用错误注入（rdi_clk 域采样，单拍脉冲即可）
    input  logic err_inject,

    // 发送侧：来自本地 DLL 的 flit 流
    input  logic              tx_valid,
    input  ucie_pkg::flit_t   tx_flit,
    output logic              tx_ready,

    // 接收侧：交给对端本地 DLL 的 flit 流
    output logic              rx_valid,
    output ucie_pkg::flit_t   rx_flit,
    input  logic              rx_ready,

    // 观测
    output logic              busy,
    output logic [15:0]       flits_sent,
    output logic [15:0]       errs_injected,

    // deskew 观测（转发自 ucie_deskew）
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::SKEW_CNT_WIDTH-1:0] skew_measured,
    output logic [ucie_pkg::SKEW_CNT_WIDTH-1:0]                      max_skew,
    output logic                                                     deskew_done
);
    import ucie_pkg::*;

    // ---------------- 发送侧本地域 -> 链路域 ----------------
    logic                 tx_fifo_full;
    logic [FLIT_BITS-1:0] tx_fifo_rdata;
    logic                 tx_fifo_empty;
    logic                 tx_fifo_rinc;

    assign tx_ready = !tx_fifo_full;

    ucie_afifo #(.WIDTH(FLIT_BITS), .ADDR_W(3)) u_tx_fifo (
        .wclk   (lclk_tx),
        .wrst_n (lrst_tx_n),
        .winc   (tx_valid && pipe_enable),
        .wdata  (tx_flit),
        .wfull  (tx_fifo_full),
        .rclk   (rdi_clk),
        .rrst_n (rrst_n),
        .rinc   (tx_fifo_rinc),
        .rdata  (tx_fifo_rdata),
        .rempty (tx_fifo_empty)
    );

    // 链路域：从 FIFO 取一个 flit，启动 RDI 发送，直到 done
    logic  rdi_start;
    flit_t rdi_flit;
    logic  load_q;
    logic  rdi_busy, rdi_done;
    rdi_data_t lp_data_raw, lp_data;
    rdi_mask_t lp_mask;
    logic      lp_valid, pl_trdy;

    assign pl_trdy = 1'b1;         // demo：PHY 恒就绪；真实实现由 PHY 反压

    assign tx_fifo_rinc = !rdi_busy && !load_q && !tx_fifo_empty && pipe_enable;

    always_ff @(posedge rdi_clk or negedge rrst_n) begin
        if (!rrst_n) begin
            rdi_start <= 1'b0;
            load_q    <= 1'b0;
            rdi_flit  <= '0;
        end else begin
            rdi_start <= 1'b0;
            load_q    <= 1'b0;
            if (!rdi_busy && !load_q && !tx_fifo_empty && pipe_enable) begin
                rdi_flit  <= tx_fifo_rdata;   // 非 FWFT：当拍读走
                rdi_start <= 1'b1;
                load_q    <= 1'b1;
            end
        end
    end

    ucie_rdi_tx #(.DATA_GATING(DATA_GATING)) u_rdi_tx (
        .clk        (rdi_clk),
        .rst_n      (rrst_n),
        .start      (rdi_start),
        .flit       (rdi_flit),
        .lane_valid (lane_valid),
        .lp_valid   (lp_valid),
        .lp_data    (lp_data_raw),
        .lp_mask    (lp_mask),
        .pl_trdy    (pl_trdy),
        .done       (rdi_done),
        .busy       (rdi_busy)
    );

    assign busy = rdi_busy;

    // ---------------- 错误注入点（链路物理层）----------------
    // 注入时机：err_inject 有效时，在下一个正在传输的 UI 上翻转一个 bit。
    // 因为 flit 是跨多个 UI 传的，任意一拍被污染都会让接收端 CRC 校验失败。
    logic                 err_armed;
    logic [FLIT_BITS-1:0] err_mask;
    logic [15:0]          err_cnt;

    always_ff @(posedge rdi_clk or negedge rrst_n) begin
        if (!rrst_n) begin
            err_armed <= 1'b0;
            err_mask  <= '0;
            err_cnt   <= 16'h0000;
        end else if (err_inject) begin
            err_armed <= 1'b1;
            err_mask  <= (FLIT_BITS'(1) << (err_cnt[7:0] % FLIT_BITS));
        end else if (err_armed && lp_valid) begin
            err_armed <= 1'b0;
            err_cnt   <= err_cnt + 16'd1;
        end
    end

    always_comb begin
        logic [FLIT_BITS-1:0] flat;
        flat = '0;
        for (int l = 0; l < LANES; l++) begin
            flat[l*8 +: 8] = lp_data_raw[l*8 +: 8];
        end
        flat    = flat ^ (err_armed ? err_mask : '0);
        lp_data = '0;
        for (int l = 0; l < LANES; l++) begin
            lp_data[l*8 +: 8] = flat[l*8 +: 8];
        end
    end

    assign errs_injected = err_cnt;

    // ---------------- 链路域 -> 接收侧本地域 ----------------
    logic                 rx_fifo_full;
    logic [FLIT_BITS-1:0] rx_fifo_rdata;
    logic                 rx_fifo_empty;
    logic                 rx_fifo_rinc;
    logic                 rx_flit_valid;
    flit_t                rx_flit_d;
    logic [7:0]           rx_bytes_seen;

    // ---------------- lane 间去偏斜（deskew）----------------
    // 插入位置：**误码注入之后、ucie_rdi_rx 之前**。
    // ucie_rdi_rx 是"单拍 pl_valid + 逐 lane 取字节"打包的，若各 lane 到达时刻
    // 相差若干 UI，不同 UI 的字节会被拼进同一 flit（CRC 还是对的，但数据错乱）——
    // deskew 就是消除这个问题的。
    // 未完成测量时本模块直通（旁路），因此对既有场景零影响。
    localparam logic [7:0] DESKEW_PATTERN = 8'hA5;   // 各 lane 共用的训练 pattern

    rdi_data_t dsk_data;
    rdi_mask_t dsk_mask;
    logic      dsk_valid;

    ucie_deskew u_deskew (
        .clk           (rdi_clk),
        .rst_n         (rrst_n),
        .lane_valid    (lane_valid),
        .train_mode    (deskew_train),
        .train_clr     (deskew_clr),
        .train_pattern (DESKEW_PATTERN),
        .pl_valid      (lp_valid),
        .pl_data       (lp_data),
        .pl_mask       (lp_mask),
        .dsk_valid     (dsk_valid),
        .dsk_data      (dsk_data),
        .dsk_mask      (dsk_mask),
        .skew_measured (skew_measured),
        .max_skew      (max_skew),
        .deskew_done   (deskew_done)
    );

    ucie_rdi_rx u_rdi_rx (
        .clk        (rdi_clk),
        .rst_n      (rrst_n),
        .lane_valid (lane_valid),
        .pl_valid   (dsk_valid),
        .pl_data    (dsk_data),
        .pl_mask    (dsk_mask),
        .flit_valid (rx_flit_valid),
        .flit       (rx_flit_d),
        .bytes_seen (rx_bytes_seen)
    );

    ucie_afifo #(.WIDTH(FLIT_BITS), .ADDR_W(3)) u_rx_fifo (
        .wclk   (rdi_clk),
        .wrst_n (rrst_n),
        .winc   (rx_flit_valid),
        .wdata  (rx_flit_d),
        .wfull  (rx_fifo_full),
        .rclk   (lclk_rx),
        .rrst_n (lrst_rx_n),
        .rinc   (rx_fifo_rinc),
        .rdata  (rx_fifo_rdata),
        .rempty (rx_fifo_empty)
    );

    // 非 FWFT：rempty 无效即当拍数据有效，被消费时 pop
    assign rx_valid     = !rx_fifo_empty;
    assign rx_flit      = rx_fifo_rdata;
    assign rx_fifo_rinc = rx_valid && rx_ready;

    // ---------------- 统计 ----------------
    logic [15:0] sent_q;
    always_ff @(posedge rdi_clk or negedge rrst_n) begin
        if (!rrst_n)       sent_q <= 16'h0000;
        else if (rdi_done) sent_q <= sent_q + 16'd1;
    end
    assign flits_sent = sent_q;

`ifndef SYNTHESIS
    // 非 ACTIVE 期间不应有新的 flit 被推进管道。disable iff 的复位被工具视为
    // 同步用法、而寄存器用异步复位，语义无问题，局部抑制（用行注释 pragma 写法，
    // 注意别把普通注释写成“// verilator ...”，那会被当成 pragma 解析）。
    // verilator lint_off SYNCASYNCNET
    a_gate: assert property (@(posedge rdi_clk) disable iff (!rrst_n)
        (!pipe_enable) |-> (tx_fifo_empty || !rdi_busy));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_LINK_PIPE_SV
