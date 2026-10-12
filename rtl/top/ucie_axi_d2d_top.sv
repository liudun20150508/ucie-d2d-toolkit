// =============================================================================
// ucie_axi_d2d_top : AXI4 over UCIe —— 带协议层的 Chiplet D2D 顶层
// -----------------------------------------------------------------------------
// 分层复用关系（链路部分一行未改，只在协议层加了 AXI）：
//
//   A 侧 AXI master（CPU/DMA）
//        │  AXI4 slave 端口
//        ▼
//   ucie_axi_slv_bridge ──┐
//                         │ 64B 事务口
//                         ▼
//                    ucie_d2d_top   ← 原有全部链路：DLL(flit/CRC/retry/credit)
//                         │            + LTSSM + lane_repair + RDI + CDC
//                         │ 64B 事务口
//                         ▼
//   ucie_axi_mst_bridge ──┘
//        │  AXI4 master 端口
//        ▼
//   B 侧 AXI slave（内存模型）
//
// 这样组织的好处：协议层（AXI）与链路层（UCIe D2D）解耦，互不影响，
// 也便于将来把 AXI 换成 CHI 或 PCIe/CXL 而不动链路。
// =============================================================================
`ifndef UCIE_AXI_D2D_TOP_SV
`define UCIE_AXI_D2D_TOP_SV

module ucie_axi_d2d_top #(
    parameter int ACK_EVERY     = 1,
    parameter int RETRY_TIMEOUT = 48
)(
    input  logic lclk,
    input  logic lrst_n,
    input  logic rdi_clk,
    input  logic rrst_n,

    // ---------------- A 侧：AXI4 slave 端口（本端 master 连这里）----------------
    input  logic                  a_awvalid,
    output logic                  a_awready,
    input  ucie_axi_pkg::axi_ax_t a_aw,
    input  logic                  a_wvalid,
    output logic                  a_wready,
    input  logic [511:0]          a_wdata,
    input  logic [63:0]           a_wstrb,
    input  logic                  a_wlast,
    output logic                  a_bvalid,
    input  logic                  a_bready,
    output logic [3:0]            a_bid,
    output logic [1:0]            a_bresp,
    input  logic                  a_arvalid,
    output logic                  a_arready,
    input  ucie_axi_pkg::axi_ax_t a_ar,
    output logic                  a_rvalid,
    input  logic                  a_rready,
    output logic [3:0]            a_rid,
    output logic [511:0]          a_rdata,
    output logic [1:0]            a_rresp,
    output logic                  a_rlast,

    // ---------------- B 侧：AXI4 master 端口（连到本端 slave 内存模型）----------------
    output logic                  b_awvalid,
    input  logic                  b_awready,
    output ucie_axi_pkg::axi_ax_t b_aw,
    output logic                  b_wvalid,
    input  logic                  b_wready,
    output logic [511:0]          b_wdata,
    output logic [63:0]           b_wstrb,
    output logic                  b_wlast,
    input  logic                  b_bvalid,
    output logic                  b_bready,
    input  logic [3:0]            b_bid,
    input  logic [1:0]            b_bresp,
    output logic                  b_arvalid,
    input  logic                  b_arready,
    output ucie_axi_pkg::axi_ax_t b_ar,
    input  logic                  b_rvalid,
    output logic                  b_rready,
    input  logic [3:0]            b_rid,
    input  logic [511:0]          b_rdata,
    input  logic [1:0]            b_rresp,
    input  logic                  b_rlast,

    // ---------------- PHY / 训练控制（透传）----------------
    input  logic [ucie_pkg::LANES_TOTAL-1:0] lane_good,
    input  logic                             reversal_detect,
    input  logic                             train_enable,
    input  logic                             link_err_inject,
    input  logic                             err_inject_a2b,
    input  logic                             err_inject_b2a,

    // ---------------- 观测 / 统计 ----------------
    output ucie_pkg::ltssm_e           ltssm_state,
    output logic                       link_active,
    output logic [7:0]                 valid_lanes,
    output logic                       repair_used,
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::MAP_W-1:0] lane_map_out,
    output logic [ucie_pkg::LANES-1:0] effective_mask,
    output logic [15:0]                a_wr_req,
    output logic [15:0]                a_rd_req,
    output logic [15:0]                a_wr_data,
    output logic [15:0]                a_b_resp,
    output logic [15:0]                a_r_beat,
    output logic [15:0]                b_wr_req,
    output logic [15:0]                b_wr_data,
    output logic [15:0]                b_b_resp,
    output logic [15:0]                b_r_beat,
    output logic [15:0]                d2d_delivered_b,
    output logic [15:0]                d2d_retry_a
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    // 桥接 <-> 链路 的 64B 事务口
    logic         a_tx_valid, a_tx_ready;
    logic [511:0] a_tx_data;
    logic         a_rx_valid, a_rx_ready;
    logic [511:0] a_rx_data;

    logic         b_tx_valid, b_tx_ready;
    logic [511:0] b_tx_data;
    logic         b_rx_valid, b_rx_ready;
    logic [511:0] b_rx_data;

    // 注意（踩过的坑）：AXI 的 AW/AR 是 packed struct 端口。把「output struct 端口的
    // 字段」直接当作子模块 output 的连接目标，Verilator 实测会失效 ——
    // 表现为从端收到的 addr/len 恒为 0（而 id 恰好对，因为值小），
    // 于是 burst 被当成单拍：T2 单拍还能"假通过"（读写地址都变 0，自洽），
    // 一跑 T3 的 4 拍突发就暴露。
    // 解决：用内部变量接字段，再整体 assign 给端口。
    axi_ax_t b_aw_w, b_ar_w;
    assign b_aw = b_aw_w;
    assign b_ar = b_ar_w;

    // =========================================================================
    // A 侧：AXI slave 端口 <-> 链路
    // =========================================================================
    ucie_axi_slv_bridge u_slv (
        .clk         (lclk),
        .rst_n       (lrst_n),
        .s_awvalid   (a_awvalid),
        .s_awready   (a_awready),
        .s_aw        (a_aw),
        .s_wvalid    (a_wvalid),
        .s_wready    (a_wready),
        .s_wdata     (a_wdata),
        .s_wstrb     (a_wstrb),
        .s_wlast     (a_wlast),
        .s_bvalid    (a_bvalid),
        .s_bready    (a_bready),
        .s_bid       (a_bid),
        .s_bresp     (a_bresp),
        .s_arvalid   (a_arvalid),
        .s_arready   (a_arready),
        .s_ar        (a_ar),
        .s_rvalid    (a_rvalid),
        .s_rready    (a_rready),
        .s_rid       (a_rid),
        .s_rdata     (a_rdata),
        .s_rresp     (a_rresp),
        .s_rlast     (a_rlast),
        .l_tx_valid  (a_tx_valid),
        .l_tx_ready  (a_tx_ready),
        .l_tx_data   (a_tx_data),
        .l_rx_valid  (a_rx_valid),
        .l_rx_ready  (a_rx_ready),
        .l_rx_data   (a_rx_data),
        .cnt_wr_req  (a_wr_req),
        .cnt_rd_req  (a_rd_req),
        .cnt_wr_data (a_wr_data),
        .cnt_b       (a_b_resp),
        .cnt_r       (a_r_beat),
        .cnt_err     (),
        .cnt_tx_flit (),
        .cnt_rx_flit ()
    );

    // =========================================================================
    // B 侧：链路 <-> AXI master 端口
    // =========================================================================
    ucie_axi_mst_bridge u_mst (
        .clk         (lclk),
        .rst_n       (lrst_n),
        .m_awvalid   (b_awvalid),
        .m_awready   (b_awready),
        .m_awid      (b_aw_w.id),
        .m_awaddr    (b_aw_w.addr),
        .m_awlen     (b_aw_w.len),
        .m_awsize    (b_aw_w.size),
        .m_awburst   (b_aw_w.burst),
        .m_wvalid    (b_wvalid),
        .m_wready    (b_wready),
        .m_wdata     (b_wdata),
        .m_wstrb     (b_wstrb),
        .m_wlast     (b_wlast),
        .m_bvalid    (b_bvalid),
        .m_bready    (b_bready),
        .m_bid       (b_bid),
        .m_bresp     (b_bresp),
        .m_arvalid   (b_arvalid),
        .m_arready   (b_arready),
        .m_arid      (b_ar_w.id),
        .m_araddr    (b_ar_w.addr),
        .m_arlen     (b_ar_w.len),
        .m_arsize    (b_ar_w.size),
        .m_arburst   (b_ar_w.burst),
        .m_rvalid    (b_rvalid),
        .m_rready    (b_rready),
        .m_rid       (b_rid),
        .m_rdata     (b_rdata),
        .m_rresp     (b_rresp),
        .m_rlast     (b_rlast),
        .l_tx_valid  (b_tx_valid),
        .l_tx_ready  (b_tx_ready),
        .l_tx_data   (b_tx_data),
        .l_rx_valid  (b_rx_valid),
        .l_rx_ready  (b_rx_ready),
        .l_rx_data   (b_rx_data),
        .cnt_wr_req  (b_wr_req),
        .cnt_rd_req  (),
        .cnt_wr_data (b_wr_data),
        .cnt_b       (b_b_resp),
        .cnt_r       (b_r_beat),
        .cnt_err     (),
        .cnt_tx_flit (),
        .cnt_rx_flit ()
    );

    // =========================================================================
    // 链路：完全复用既有的 UCIe D2D 实现
    // =========================================================================
    ucie_d2d_top #(
        .ACK_EVERY     (ACK_EVERY),
        .RETRY_TIMEOUT (RETRY_TIMEOUT)
    ) u_d2d (
        .lclk            (lclk),
        .lrst_n          (lrst_n),
        .rdi_clk         (rdi_clk),
        .rrst_n          (rrst_n),
        .a_tx_valid      (a_tx_valid),
        .a_tx_ready      (a_tx_ready),
        .a_tx_data       (a_tx_data),
        .a_rx_valid      (a_rx_valid),
        .a_rx_ready      (a_rx_ready),
        .a_rx_data       (a_rx_data),
        .b_tx_valid      (b_tx_valid),
        .b_tx_ready      (b_tx_ready),
        .b_tx_data       (b_tx_data),
        .b_rx_valid      (b_rx_valid),
        .b_rx_ready      (b_rx_ready),
        .b_rx_data       (b_rx_data),
        .lane_good       (lane_good),
        .reversal_detect (reversal_detect),
        .train_enable    (train_enable),
        .link_err_inject (link_err_inject),
        .err_inject_a2b  (err_inject_a2b),
        .err_inject_b2a  (err_inject_b2a),
        .ltssm_state     (ltssm_state),
        .link_active     (link_active),
        .valid_lanes     (valid_lanes),
        .repair_used     (repair_used),
        .lane_map_out    (lane_map_out),
        .effective_mask  (effective_mask),
        .a_delivered     (),
        .a_crc_err       (),
        .a_nak_sent      (),
        .a_retry         (d2d_retry_a),
        .b_delivered     (d2d_delivered_b),
        .b_crc_err       (),
        .b_nak_sent      (),
        .a_credit_left   (),
        .a_inflight      ()
    );

endmodule

`endif  // UCIE_AXI_D2D_TOP_SV
