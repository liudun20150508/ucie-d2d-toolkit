// =============================================================================
// ucie_afifo : 跨时钟域异步 FIFO（Gray 码指针 + 两级同步）
// -----------------------------------------------------------------------------
// 对应设计目标里的「跨时钟域（CDC）设计」：
//   本地协议层时钟（lclk）与链路/RDI 时钟（rdi_clk）不同源，flit 跨域必须
//   走异步 FIFO。这里用经典 Cummings 结构：
//     * 读写指针用**二进制 + 格雷码**双份表示，跨域只同步格雷码
//       （格雷码相邻只变 1 bit，避免多 bit 同时翻转时采样出中间态）
//     * 深度取 2 的幂，指针多 1 位用于区分“满/空”
//     * 满判据：写指针格雷码 == {~读指针次高位, 读指针其余位}
//       —— 最高两位相反、低位相同，表示绕了一圈撞上
//
// 有意避开的坑：教科书里常见的 `wbin_nxt = wbin + (winc & ~wfull)` 会让
// wfull 依赖自身形成组合环（Verilator 报 UNOPTFLAT，综合工具也会抱怨）。
// 这里改成 `wbin_nxt = wbin + winc` 的“自增候选”，再由候选值判满。
//
// 注意：这是单向数据 FIFO（写侧只写、读侧只读），非 FWFT。
// =============================================================================
`ifndef UCIE_AFIFO_SV
`define UCIE_AFIFO_SV

module ucie_afifo #(
    parameter int WIDTH   = 544,   // 默认放一个 flit（68B）
    parameter int ADDR_W  = 3,     // 深度 = 2^ADDR_W
    parameter int DEPTH   = 1 << ADDR_W
)(
    // 写侧（本地时钟域）
    input  logic             wclk,
    input  logic             wrst_n,
    input  logic             winc,
    input  logic [WIDTH-1:0] wdata,
    output logic             wfull,

    // 读侧（链路/RDI 时钟域）
    input  logic             rclk,
    input  logic             rrst_n,
    input  logic             rinc,
    output logic [WIDTH-1:0] rdata,
    output logic             rempty
);
    // 双口存储：写侧写、读侧读（真实实现里映射为双口 SRAM）
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    logic [ADDR_W:0] wbin, wgray, rbin, rgray;
    logic [ADDR_W:0] wbin_nxt, wgray_nxt;
    logic [ADDR_W:0] rbin_nxt, rgray_nxt;
    logic [ADDR_W:0] wq1_rgray, wq2_rgray;   // 读指针同步到写域
    logic [ADDR_W:0] rq1_wgray, rq2_wgray;   // 写指针同步到读域

    // ---- 二进制 -> 格雷码 ----
    function automatic logic [ADDR_W:0] bin2gray(input logic [ADDR_W:0] b);
        return b ^ (b >> 1);
    endfunction

    // ---------------- 写侧 ----------------
    assign wbin_nxt  = wbin + {{ADDR_W{1'b0}}, winc};   // 自增候选（不依赖 wfull）
    assign wgray_nxt = bin2gray(wbin_nxt);
    assign wfull     = (wgray_nxt == {~wq2_rgray[ADDR_W:ADDR_W-1], wq2_rgray[ADDR_W-2:0]});

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= '0;
            wgray <= '0;
        end else if (winc && !wfull) begin
            mem[wbin[ADDR_W-1:0]] <= wdata;
            wbin                  <= wbin_nxt;
            wgray                 <= wgray_nxt;
        end
    end

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wq1_rgray <= '0;
            wq2_rgray <= '0;
        end else begin
            wq1_rgray <= rgray;          // 两级同步器
            wq2_rgray <= wq1_rgray;
        end
    end

    // ---------------- 读侧 ----------------
    assign rbin_nxt  = rbin + {{ADDR_W{1'b0}}, rinc};
    assign rgray_nxt = bin2gray(rbin_nxt);
    assign rempty    = (rgray == rq2_wgray);

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin  <= '0;
            rgray <= '0;
        end else if (rinc && !rempty) begin
            rbin  <= rbin_nxt;
            rgray <= rgray_nxt;
        end
    end

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rq1_wgray <= '0;
            rq2_wgray <= '0;
        end else begin
            rq1_wgray <= wgray;          // 两级同步器
            rq2_wgray <= rq1_wgray;
        end
    end

    assign rdata = mem[rbin[ADDR_W-1:0]];

endmodule

`endif  // UCIE_AFIFO_SV
