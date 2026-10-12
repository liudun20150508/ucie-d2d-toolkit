// =============================================================================
// ucie_link_retry : 链路层重传缓冲 + 发送窗口管理（UCIe Link Retry 的简化实现）
// -----------------------------------------------------------------------------
// 对应设计目标里的「高可靠性设计 / 容错」：
//   - 每个发出的数据 flit 都留存在 retry buffer 里，直到被对端 ACK
//   - 收到 NAK(seq) 或本地超时 -> 从 ack_ptr / nak_seq 起整段重发
//   - 窗口深度 = RETRY_BUF_DEPTH，窗口满则对上游反压（in_ready=0）
//
// 语义约定（与 UCIe 一致的要点）：
//   * ACK 是**累积确认**：ACK(seq) 表示 seq 及之前全部正确收到
//   * NAK 是**回退请求**：NAK(seq) 表示从 seq 起重发
//   * seq 为 8 bit 回绕，窗口比较一律走 in_window()（模 256 区间判断），
//     不能直接用大小比较——这是回绕序号设计的经典坑。
// =============================================================================
`ifndef UCIE_LINK_RETRY_SV
`define UCIE_LINK_RETRY_SV

module ucie_link_retry #(
    parameter int DEPTH          = ucie_pkg::RETRY_BUF_DEPTH,
    parameter int TIMEOUT_CYCLES = 48
)(
    input  logic clk,
    input  logic rst_n,

    // 上游：新 flit 入队（来自 ucie_flit_tx）
    input  logic        in_valid,
    input  ucie_pkg::flit_t in_flit,
    output logic        in_ready,

    // 下游：送链路
    output logic        out_valid,
    output ucie_pkg::flit_t out_flit,
    input  logic        out_ready,

    // 对端反馈
    input  logic        ack_valid,
    input  logic [7:0]  ack_seq,
    input  logic        nak_valid,
    input  logic [7:0]  nak_seq,

    // 遥测
    output logic [7:0]  inflight,
    output logic [15:0] retry_cnt
);
    import ucie_pkg::*;

    localparam int IDX_W = $clog2(DEPTH);

    flit_t retry_mem [0:DEPTH-1];   // 注：不能叫 buf——Verilator 里 buf 是内置 gate primitive 关键字

    logic [7:0] wr_ptr, ack_ptr, tx_ptr;
    logic       out_valid_q;
    flit_t      out_flit_q;
    logic [15:0] tmo_cnt;
    logic [15:0] retry_q;

    logic [7:0] inflight_c;
    assign inflight_c = wr_ptr - ack_ptr;      // 窗口内待确认条目数
    assign inflight   = inflight_c;

    logic enq;
    assign enq      = in_valid && in_ready;
    assign in_ready = (inflight_c < DEPTH[7:0]);

    // seq 是否落在 [base, base+n) 的模 256 区间内
    function automatic logic in_window(input logic [7:0] s, input logic [7:0] base, input logic [7:0] n);
        logic [7:0] d;
        d = s - base;
        return (d < n);
    endfunction

    logic [7:0]  wr_ptr_n;
    assign wr_ptr_n = wr_ptr + (enq ? 8'd1 : 8'd0);

    // ---------------------------------------------------------------- 组合
    logic [7:0]  n_tx_ptr, n_ack_ptr;
    logic        n_out_valid, n_retry;
    flit_t       n_out_flit;
    logic [15:0] n_tmo;

    always_comb begin
        n_tx_ptr    = tx_ptr;
        n_ack_ptr   = ack_ptr;
        n_out_valid = out_valid_q;
        n_out_flit  = out_flit_q;
        n_tmo       = tmo_cnt;
        n_retry     = 1'b0;

        // (1) NAK 优先：指针回退，触发重发
        if (nak_valid && in_window(nak_seq, ack_ptr, inflight_c)) begin
            n_tx_ptr = nak_seq;
            n_retry  = 1'b1;
            n_tmo    = '0;
        end
        // (2) 累积 ACK：确认指针前移
        else if (ack_valid && in_window(ack_seq, ack_ptr, inflight_c)) begin
            n_ack_ptr = ack_seq + 8'd1;
            n_tmo     = '0;
        end
        // (3) 重传超时：对端长时间无反馈，从 ack_ptr 整段重发
        else if ((inflight_c != 0) && (tmo_cnt >= TIMEOUT_CYCLES[15:0])) begin
            n_tx_ptr = ack_ptr;
            n_retry  = 1'b1;
            n_tmo    = '0;
        end
        // (4) 正常计时
        else if (inflight_c != 0) begin
            n_tmo = tmo_cnt + 16'd1;
        end

        // (5) 发送引擎：先把当前 flit 送走，再装载下一个（含刚回退的指针）
        if (n_out_valid && out_ready) begin
            n_out_valid = 1'b0;
        end
        if (!n_out_valid && (n_tx_ptr != wr_ptr_n)) begin
            n_out_flit  = retry_mem[n_tx_ptr[IDX_W-1:0]];
            n_out_valid = 1'b1;
            n_tx_ptr    = n_tx_ptr + 8'd1;
        end
    end

    // ---------------------------------------------------------------- 时序
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= 8'h00;
            ack_ptr     <= 8'h00;
            tx_ptr      <= 8'h00;
            out_valid_q <= 1'b0;
            out_flit_q  <= '0;
            tmo_cnt     <= 16'h0000;
            retry_q     <= 16'h0000;
        end else begin
            wr_ptr      <= wr_ptr_n;
            ack_ptr     <= n_ack_ptr;
            tx_ptr      <= n_tx_ptr;
            out_valid_q <= n_out_valid;
            out_flit_q  <= n_out_flit;
            tmo_cnt     <= n_tmo;
            retry_q     <= retry_q + (n_retry ? 16'd1 : 16'd0);

            if (enq) begin
                retry_mem[wr_ptr[IDX_W-1:0]] <= in_flit;
            end
        end
    end

    assign out_valid = out_valid_q;
    assign out_flit  = out_flit_q;
    assign retry_cnt = retry_q;

    // ------------------------------------------------------------ 断言
`ifndef SYNTHESIS
    // rst_n 在这里被"双重身份"使用：always_ff 里作异步复位，断言里作 disable iff，
    // 于是 lint 会报 SYNCASYNCNET（同一信号既同步又异步）。断言整块由
    // `ifndef SYNTHESIS 包住、综合时不存在，故属 SVA 语义带来的误报，局部抑制；
    // 抑制范围仅限本块，不影响其他 SYNCASYNCNET 检查。
    /* verilator lint_off SYNCASYNCNET */
    // 窗口绝不可超过缓冲深度（回绕指针一旦算错，这条断言会立刻抓住）
    a_window: assert property (@(posedge clk) disable iff (!rst_n) (inflight_c <= DEPTH));
    // 上游只有窗口满时才被反压
    a_backpressure: assert property (@(posedge clk) disable iff (!rst_n)
        ((inflight_c == DEPTH) |-> !in_ready));
    /* verilator lint_on SYNCASYNCNET */
`endif

endmodule

`endif  // UCIE_LINK_RETRY_SV
