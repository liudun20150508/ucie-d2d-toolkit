// =============================================================================
// ucie_axi_mst_bridge : UCIe 链路 <-> AXI4 master 端口（远端桥接）
// -----------------------------------------------------------------------------
// 拓扑角色：与 ucie_axi_slv_bridge 对称。本模块代表**远端 die** 去访问本端的
// AXI slave（内存模型 / 外设），所以它对外是 AXI **master 端口**。
//
//   l_rx_*  ──▶ stream_unpack ──▶ ucie_axi_mst_rx ──▶ m_aw/m_w/m_ar （发起访问）
//   m_b/m_r ──▶ ucie_axi_mst_tx ──▶ stream_pack ──▶ l_tx_*           （回响应）
//
// 两侧角色在真实 chiplet 里是对称可配的：A 侧做 slv、B 侧做 mst，
// 或者反过来，取决于谁主动访问谁。这里固定成“A 主动、B 被动”以便验证。
// =============================================================================
`ifndef UCIE_AXI_MST_BRIDGE_SV
`define UCIE_AXI_MST_BRIDGE_SV

module ucie_axi_mst_bridge (
    input  logic clk,
    input  logic rst_n,

    // ---------------- AXI4 master 端口 ----------------
    output logic         m_awvalid,
    input  logic         m_awready,
    output logic [3:0]   m_awid,
    output logic [63:0]  m_awaddr,
    output logic [7:0]   m_awlen,
    output logic [2:0]   m_awsize,
    output logic [1:0]   m_awburst,

    output logic         m_wvalid,
    input  logic         m_wready,
    output logic [511:0] m_wdata,
    output logic [63:0]  m_wstrb,
    output logic         m_wlast,

    input  logic         m_bvalid,
    output logic         m_bready,
    input  logic [3:0]   m_bid,
    input  logic [1:0]   m_bresp,

    output logic         m_arvalid,
    input  logic         m_arready,
    output logic [3:0]   m_arid,
    output logic [63:0]  m_araddr,
    output logic [7:0]   m_arlen,
    output logic [2:0]   m_arsize,
    output logic [1:0]   m_arburst,

    input  logic         m_rvalid,
    output logic         m_rready,
    input  logic [3:0]   m_rid,
    input  logic [511:0] m_rdata,
    input  logic [1:0]   m_rresp,
    input  logic         m_rlast,

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
    // 接收方向：flit payload -> 字节流 -> AXI 请求（发起访问）
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

    ucie_axi_mst_rx u_rx (
        .clk         (clk),
        .rst_n       (rst_n),
        .st_valid    (up_out_valid),
        .st_data     (up_out_data),
        .st_bytes    (up_out_bytes),
        .st_taken    (up_out_taken),
        .awvalid     (m_awvalid),
        .awready     (m_awready),
        .awid        (m_awid),
        .awaddr      (m_awaddr),
        .awlen       (m_awlen),
        .awsize      (m_awsize),
        .awburst     (m_awburst),
        .wvalid      (m_wvalid),
        .wready      (m_wready),
        .wdata       (m_wdata),
        .wstrb       (m_wstrb),
        .wlast       (m_wlast),
        .arvalid     (m_arvalid),
        .arready     (m_arready),
        .arid        (m_arid),
        .araddr      (m_araddr),
        .arlen       (m_arlen),
        .arsize      (m_arsize),
        .arburst     (m_arburst),
        .cnt_wr_req  (cnt_wr_req),
        .cnt_rd_req  (cnt_rd_req),
        .cnt_wr_data (cnt_wr_data),
        .cnt_err     (cnt_err)
    );

    // =========================================================================
    // 发送方向：AXI 响应 -> 字节流 -> flit payload
    // =========================================================================
    logic         tx_st_valid;
    logic [127:0] tx_st_data;
    logic [4:0]   tx_st_bytes;
    logic [4:0]   tx_st_taken;

    logic         pk_out_valid;
    logic [511:0] pk_out_payload;

    ucie_axi_mst_tx u_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .bvalid    (m_bvalid),
        .bready    (m_bready),
        .bid       (m_bid),
        .bresp     (m_bresp),
        .rvalid    (m_rvalid),
        .rready    (m_rready),
        .rid       (m_rid),
        .rdata     (m_rdata),
        .rresp     (m_rresp),
        .rlast     (m_rlast),
        .st_valid  (tx_st_valid),
        .st_taken  (tx_st_taken),
        .st_data   (tx_st_data),
        .st_bytes  (tx_st_bytes),
        .cnt_b     (cnt_b),
        .cnt_r     (cnt_r)
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

    // 注：cnt_b / cnt_r 均由 u_tx（ucie_axi_mst_tx）内部计数后直接引出。

endmodule

`endif  // UCIE_AXI_MST_BRIDGE_SV
