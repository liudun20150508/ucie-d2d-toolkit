// =============================================================================
// ucie_axi_slv_bridge : AXI4 slave 端口 <-> UCIe 链路（近端桥接）
// -----------------------------------------------------------------------------
// 拓扑角色：本端有一个 AXI master（CPU / DMA / NPU 等）想跨 die 访问远端内存，
// 它连到本模块的 AXI **slave 端口**；本模块把事务打包送进 D2D 链路，
// 并把远端回来的响应还原到 slave 端口的 B/R 通道。
//
//   s_aw/s_w/s_ar  ──▶ ucie_axi_slv_tx ──▶ stream_pack ──▶ l_tx_*  （进链路）
//   l_rx_*  ──▶ stream_unpack ──▶ ucie_axi_slv_rx ──▶ s_b/s_r      （出链路）
//
// 链路侧就是 ucie_dll 的本地 64B 事务口，所以本模块可以直接替换原来的
// 裸事务接口而链路部分完全不动。
// =============================================================================
`ifndef UCIE_AXI_SLV_BRIDGE_SV
`define UCIE_AXI_SLV_BRIDGE_SV

module ucie_axi_slv_bridge (
    input  logic clk,
    input  logic rst_n,

    // ---------------- AXI4 slave 端口 ----------------
    input  logic                  s_awvalid,
    output logic                  s_awready,
    input  ucie_axi_pkg::axi_ax_t s_aw,

    input  logic                  s_wvalid,
    output logic                  s_wready,
    input  logic [511:0]          s_wdata,
    input  logic [63:0]           s_wstrb,
    input  logic                  s_wlast,

    output logic                  s_bvalid,
    input  logic                  s_bready,
    output logic [3:0]            s_bid,
    output logic [1:0]            s_bresp,

    input  logic                  s_arvalid,
    output logic                  s_arready,
    input  ucie_axi_pkg::axi_ax_t s_ar,

    output logic                  s_rvalid,
    input  logic                  s_rready,
    output logic [3:0]            s_rid,
    output logic [511:0]          s_rdata,
    output logic [1:0]            s_rresp,
    output logic                  s_rlast,

    // ---------------- 链路侧（ucie_dll 本地 64B 事务口）----------------
    output logic         l_tx_valid,
    input  logic         l_tx_ready,
    output logic [511:0] l_tx_data,

    input  logic         l_rx_valid,
    output logic         l_rx_ready,
    input  logic [511:0] l_rx_data,

    // ---------------- 统计 ----------------
    output logic [15:0]  cnt_wr_req,
    output logic [15:0]  cnt_rd_req,
    output logic [15:0]  cnt_wr_data,
    output logic [15:0]  cnt_b,
    output logic [15:0]  cnt_r,
    output logic [15:0]  cnt_err,
    output logic [15:0]  cnt_tx_flit,
    output logic [15:0]  cnt_rx_flit
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    // =========================================================================
    // 发送方向：AXI 请求 -> 字节流 -> flit payload
    // =========================================================================
    logic         tx_st_valid;
    logic [127:0] tx_st_data;
    logic [4:0]   tx_st_bytes;
    logic [4:0]   tx_st_taken;

    logic         pk_out_valid;
    logic [511:0] pk_out_payload;

    ucie_axi_slv_tx u_tx (
        .clk         (clk),
        .rst_n       (rst_n),
        .awvalid     (s_awvalid),
        .awready     (s_awready),
        .aw          (s_aw),
        .wvalid      (s_wvalid),
        .wready      (s_wready),
        .wdata       (s_wdata),
        .wstrb       (s_wstrb),
        .wlast       (s_wlast),
        .arvalid     (s_arvalid),
        .arready     (s_arready),
        .ar          (s_ar),
        .st_valid    (tx_st_valid),
        .st_taken    (tx_st_taken),
        .st_data     (tx_st_data),
        .st_bytes    (tx_st_bytes),
        .cnt_wr_req  (cnt_wr_req),
        .cnt_rd_req  (cnt_rd_req),
        .cnt_wr_data (cnt_wr_data)
    );

    ucie_stream_pack u_pack (
        .clk         (clk),
        .rst_n       (rst_n),
        .in_valid    (tx_st_valid),
        .in_data     (tx_st_data),
        .in_bytes    (tx_st_bytes),
        .in_taken    (tx_st_taken),
        .out_valid   (pk_out_valid),
        .out_ready   (l_tx_ready),
        .out_payload (pk_out_payload),
        .st_flits    (cnt_tx_flit),
        .st_bytes    ()
    );

    assign l_tx_valid = pk_out_valid;
    assign l_tx_data  = pk_out_payload;

    // =========================================================================
    // 接收方向：flit payload -> 字节流 -> AXI 响应
    // =========================================================================
    logic         up_out_valid;
    logic [127:0] up_out_data;
    logic [4:0]   up_out_bytes;
    logic [4:0]   up_out_taken;

    ucie_stream_unpack u_unpack (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_valid   (l_rx_valid),
        .in_ready   (l_rx_ready),
        .in_payload (l_rx_data),
        .out_valid  (up_out_valid),
        .out_data   (up_out_data),
        .out_bytes  (up_out_bytes),
        .out_taken  (up_out_taken),
        .flit_taken (),
        .st_flits   (cnt_rx_flit),
        .st_bytes   ()
    );

    ucie_axi_slv_rx u_rx (
        .clk      (clk),
        .rst_n    (rst_n),
        .st_valid (up_out_valid),
        .st_data  (up_out_data),
        .st_bytes (up_out_bytes),
        .st_taken (up_out_taken),
        .bvalid   (s_bvalid),
        .bready   (s_bready),
        .bid      (s_bid),
        .bresp    (s_bresp),
        .rvalid   (s_rvalid),
        .rready   (s_rready),
        .rid      (s_rid),
        .rdata    (s_rdata),
        .rresp    (s_rresp),
        .rlast    (s_rlast),
        .cnt_b    (cnt_b),
        .cnt_r    (cnt_r),
        .cnt_err  (cnt_err)
    );

endmodule

`endif  // UCIE_AXI_SLV_BRIDGE_SV
