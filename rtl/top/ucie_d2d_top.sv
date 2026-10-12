// =============================================================================
// ucie_d2d_top : Chiplet D2D 链路顶层（本端 die + 对端 die 的完整闭环）
// -----------------------------------------------------------------------------
//                 ┌─────────────── lclk 域（协议层 / DLL）───────────────┐
//   A 侧事务 ──▶ ucie_dll(A) ──▶ link_pipe(A→B) ──▶ ucie_dll(B) ──▶ B 侧事务
//                 ▲                    │  rdi_clk 域（RDI/PHY 数字）        │
//                 └── link_pipe(B→A) ◀─┘                                   │
//                 │                                                          │
//          ucie_ltssm ◀── link_active 门控 ──┐                              │
//          ucie_lane_repair ── lane_map ─────┘                              │
//                 └──────────────────────────────────────────────────────────┘
//
// 这一层把 UCIe 协议栈的三段拼成一个可跑的系统：
//   协议层接口（64B 事务）→ 适配层 DLL（flit/CRC/retry/credit）
//   → 物理层数字（RDI 字节流 + CDC + 错误注入）→ 对端反向同理
//
// 两个方向各自独立建模（含各自的错误注入点），所以可以验证：
//   * 数据通路端到端正确性（A 发 B 收，逐字节比对）
//   * 链路误码 → CRC 失败 → NAK → 重传 → 最终正确交付
//   * lane 退化（坏 lane）/ 冗余 lane 修复 → 降带宽但不丢数据
//   * 链路层上报不可恢复错误 → LTSSM 进 PHYRETRAIN 重训后恢复
// =============================================================================
`ifndef UCIE_D2D_TOP_SV
`define UCIE_D2D_TOP_SV

module ucie_d2d_top #(
    parameter int ACK_EVERY     = 1,
    parameter int RETRY_TIMEOUT = 48,
    // 低功耗：数据门控透传到两个方向的 link_pipe（0=原版 1=门控）
    parameter int DATA_GATING   = 0
)(
    // 时钟与复位：本地协议层域 + 链路（RDI）域，异步
    input  logic lclk,
    input  logic lrst_n,
    input  logic rdi_clk,
    input  logic rrst_n,

    // ---------------- A 侧协议层接口（64B 事务）----------------
    input  logic         a_tx_valid,
    output logic         a_tx_ready,
    input  logic [511:0] a_tx_data,
    output logic         a_rx_valid,
    input  logic         a_rx_ready,
    output logic [511:0] a_rx_data,

    // ---------------- B 侧协议层接口（64B 事务）----------------
    input  logic         b_tx_valid,
    output logic         b_tx_ready,
    input  logic [511:0] b_tx_data,
    output logic         b_rx_valid,
    input  logic         b_rx_ready,
    output logic [511:0] b_rx_data,

    // ---------------- PHY / 训练控制 ----------------
    input  logic [ucie_pkg::LANES_TOTAL-1:0] lane_good,        // 物理 lane 健康位
    input  logic                             reversal_detect,  // lane 反序
    input  logic                             train_enable,     // 启动训练
    input  logic                             link_err_inject,  // 注入不可恢复链路错误
    input  logic                             err_inject_a2b,   // A→B 方向注入误码
    input  logic                             err_inject_b2a,   // B→A 方向注入误码

    // ---------------- 观测 / 统计 ----------------
    output ucie_pkg::ltssm_e             ltssm_state,
    output logic                         link_active,
    output logic [7:0]                   valid_lanes,
    output logic                         repair_used,
    output logic [ucie_pkg::LANES-1:0]   effective_mask,
    // lane 映射必须可观测：真实设计里它驱动 RDI 的物理 lane 排布，
    // 也是 bring-up / 良率分析时最常读的调试量之一。
    // （踩过的坑：把它留在内部悬空，会被优化掉，repair_used 跟着恒 0。）
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::MAP_W-1:0] lane_map_out,
    output logic [15:0]                  a_delivered,
    output logic [15:0]                  a_crc_err,
    output logic [15:0]                  a_nak_sent,
    output logic [15:0]                  a_retry,
    output logic [15:0]                  b_delivered,
    output logic [15:0]                  b_crc_err,
    output logic [15:0]                  b_nak_sent,
    output logic [7:0]                   a_credit_left,
    output logic [7:0]                   a_inflight,

    // deskew 观测量（A→B / B→A 两个方向）
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::SKEW_CNT_WIDTH-1:0] skew_measured_a2b,
    output logic [ucie_pkg::SKEW_CNT_WIDTH-1:0]                      max_skew_a2b,
    output logic                                                     deskew_done_a2b,
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::SKEW_CNT_WIDTH-1:0] skew_measured_b2a,
    output logic [ucie_pkg::SKEW_CNT_WIDTH-1:0]                      max_skew_b2a,
    output logic                                                     deskew_done_b2a,

    // ---------------- 管理通道（自定版，**非 UCIe 2.0 合规实现**）----------------
    // 对应 UCIe 2.0 的 manageability；本地访问接口相当于 SMBus/PCIe 桥接侧的下游。
    input  logic        mgmt_req_valid,
    input  logic        mgmt_req_we,
    input  logic [7:0]  mgmt_req_addr,
    input  logic [31:0] mgmt_req_wdata,
    output logic [31:0] mgmt_resp_rdata,
    output logic        mgmt_resp_valid,
    output logic        mgmt_remote_retrain,   // 远程重训请求（控制输出）
    // 管理通道 sideband 发送端（本 demo 内环回；真实芯片上是跨 die 低速通道）
    output logic        mgmt_sb_tx_valid,
    output logic [7:0]  mgmt_sb_tx_msg
);
    import ucie_pkg::*;

    // =========================================================================
    // 1. lane 修复 / 重映射（组合）
    // =========================================================================
    logic [LANES-1:0] lane_map_valid_q;

    ucie_lane_repair u_lane_repair (
        .lane_good       (lane_good),
        .reversal_detect (reversal_detect),
        .lane_map        (lane_map_out),
        .lane_map_valid  (lane_map_valid_q),
        .valid_lanes     (valid_lanes),
        .repair_used     (repair_used),
        .effective_mask  (effective_mask)
    );

    // =========================================================================
    // 2. 两个方向的链路管道（内含 CDC + RDI + 错误注入）
    // =========================================================================
    logic        a_lnk_tx_valid, a_lnk_tx_ready;
    flit_t       a_lnk_tx_flit;
    logic        a_lnk_rx_valid, a_lnk_rx_ready;
    flit_t       a_lnk_rx_flit;

    logic        b_lnk_tx_valid, b_lnk_tx_ready;
    flit_t       b_lnk_tx_flit;
    logic        b_lnk_rx_valid, b_lnk_rx_ready;
    flit_t       b_lnk_rx_flit;

    logic        link_active_q;
    logic [15:0] a2b_flits, b2a_flits, a2b_errs, b2a_errs;

    // ---------------- deskew 训练控制 ----------------
    // MBTRAIN 期间测量 lane 间偏斜；非 MBTRAIN 期间保持清零
    // （等价于"每次进 MBTRAIN 清一次测量结果"）。
    // 直接从 ltssm_state 派生，因此**不需要改动 TB 的激励接口**。
    logic deskew_train;
    logic deskew_clr;

    assign deskew_train = (ltssm_state == LTS_MBTRAIN);
    assign deskew_clr   = (ltssm_state != LTS_MBTRAIN);

    ucie_link_pipe #(.DATA_GATING(DATA_GATING)) u_pipe_a2b (
        .lclk_tx        (lclk),
        .lrst_tx_n      (lrst_n),
        .lclk_rx        (lclk),
        .lrst_rx_n      (lrst_n),
        .rdi_clk        (rdi_clk),
        .rrst_n         (rrst_n),
        .lane_valid     (lane_map_valid_q),
        .pipe_enable    (link_active_q),
        .err_inject     (err_inject_a2b),
        .tx_valid       (a_lnk_tx_valid),
        .tx_flit        (a_lnk_tx_flit),
        .tx_ready       (a_lnk_tx_ready),
        .rx_valid       (b_lnk_rx_valid),
        .rx_flit        (b_lnk_rx_flit),
        .rx_ready       (b_lnk_rx_ready),
        .busy           (),
        .flits_sent     (a2b_flits),
        .errs_injected  (a2b_errs),
        .deskew_train   (deskew_train),
        .deskew_clr     (deskew_clr),
        .skew_measured  (skew_measured_a2b),
        .max_skew       (max_skew_a2b),
        .deskew_done    (deskew_done_a2b)
    );

    ucie_link_pipe #(.DATA_GATING(DATA_GATING)) u_pipe_b2a (
        .lclk_tx        (lclk),
        .lrst_tx_n      (lrst_n),
        .lclk_rx        (lclk),
        .lrst_rx_n      (lrst_n),
        .rdi_clk        (rdi_clk),
        .rrst_n         (rrst_n),
        .lane_valid     (lane_map_valid_q),
        .pipe_enable    (link_active_q),
        .err_inject     (err_inject_b2a),
        .tx_valid       (b_lnk_tx_valid),
        .tx_flit        (b_lnk_tx_flit),
        .tx_ready       (b_lnk_tx_ready),
        .rx_valid       (a_lnk_rx_valid),
        .rx_flit        (a_lnk_rx_flit),
        .rx_ready       (a_lnk_rx_ready),
        .busy           (),
        .flits_sent     (b2a_flits),
        .errs_injected  (b2a_errs),
        .deskew_train   (deskew_train),
        .deskew_clr     (deskew_clr),
        .skew_measured  (skew_measured_b2a),
        .max_skew       (max_skew_b2a),
        .deskew_done    (deskew_done_b2a)
    );

    // =========================================================================
    // 3. 两侧 D2D Adapter（DLL）
    // =========================================================================
    logic a_link_error, b_link_error;

    ucie_dll #(
        .ACK_EVERY     (ACK_EVERY),
        .RETRY_TIMEOUT (RETRY_TIMEOUT)
    ) u_dll_a (
        .clk            (lclk),
        .rst_n          (lrst_n),
        .l_tx_valid     (a_tx_valid),
        .l_tx_ready     (a_tx_ready),
        .l_tx_data      (a_tx_data),
        .l_rx_valid     (a_rx_valid),
        .l_rx_ready     (a_rx_ready),
        .l_rx_data      (a_rx_data),
        .lnk_tx_valid   (a_lnk_tx_valid),
        .lnk_tx_flit    (a_lnk_tx_flit),
        .lnk_tx_ready   (a_lnk_tx_ready),
        .lnk_rx_valid   (a_lnk_rx_valid),
        .lnk_rx_flit    (a_lnk_rx_flit),
        .lnk_rx_ready   (a_lnk_rx_ready),
        .st_delivered   (a_delivered),
        .st_crc_err     (a_crc_err),
        .st_ack_sent    (),
        .st_nak_sent    (a_nak_sent),
        .st_credit_sent (),
        .st_duplicate   (),
        .st_retry       (a_retry),
        .st_inflight    (a_inflight),
        .st_credit_left (a_credit_left),
        .link_error     (a_link_error),
        .clr_link_error (ltssm_state == LTS_ACTIVE && link_active_q)
    );

    ucie_dll #(
        .ACK_EVERY     (ACK_EVERY),
        .RETRY_TIMEOUT (RETRY_TIMEOUT)
    ) u_dll_b (
        .clk            (lclk),
        .rst_n          (lrst_n),
        .l_tx_valid     (b_tx_valid),
        .l_tx_ready     (b_tx_ready),
        .l_tx_data      (b_tx_data),
        .l_rx_valid     (b_rx_valid),
        .l_rx_ready     (b_rx_ready),
        .l_rx_data      (b_rx_data),
        .lnk_tx_valid   (b_lnk_tx_valid),
        .lnk_tx_flit    (b_lnk_tx_flit),
        .lnk_tx_ready   (b_lnk_tx_ready),
        .lnk_rx_valid   (b_lnk_rx_valid),
        .lnk_rx_flit    (b_lnk_rx_flit),
        .lnk_rx_ready   (b_lnk_rx_ready),
        .st_delivered   (b_delivered),
        .st_crc_err     (b_crc_err),
        .st_ack_sent    (),
        .st_nak_sent    (b_nak_sent),
        .st_credit_sent (),
        .st_duplicate   (),
        .st_retry       (),
        .st_inflight    (),
        .st_credit_left (),
        .link_error     (b_link_error),
        .clr_link_error (ltssm_state == LTS_ACTIVE && link_active_q)
    );

    // =========================================================================
    // 4. 链路训练状态机（LTSSM）
    // =========================================================================
    logic        sb_valid, sb_peer_ack;
    logic [7:0]  sb_msg, sb_arg;
    logic        sb_peer_valid;
    logic [7:0]  sb_peer_msg;
    logic        retrain_pulse;
    logic [15:0] train_cycles;
    logic [3:0]  retrain_cnt;

    ucie_ltssm u_ltssm (
        .clk            (lclk),
        .rst_n          (lrst_n),
        .enable         (train_enable),
        .link_error_in  (link_err_inject | a_link_error | b_link_error),
        .sb_valid       (sb_valid),
        .sb_msg         (sb_msg),
        .sb_arg         (sb_arg),
        .sb_peer_ack    (sb_peer_ack),
        .sb_peer_valid  (sb_peer_valid),
        .sb_peer_msg    (sb_peer_msg),
        .lane_good      (lane_good),
        .valid_lanes    (valid_lanes),
        .state          (ltssm_state),
        .link_active    (link_active),
        .train_error    (),
        .retrain_pulse  (retrain_pulse),
        .train_cycles   (train_cycles),
        .retrain_cnt    (retrain_cnt)
    );

    // 侧带环回：本 demo 里对端 die 就在同一颗 RTL 里，本端发出的侧带消息
    // 直接回连到本端接收端（真实芯片上是跨 die 的 sideband 通道）。
    assign sb_peer_valid = sb_valid;
    assign sb_peer_msg   = (sb_msg == SB_MSG_PARAM_REQ) ? SB_MSG_PARAM_ACK : sb_msg;
    assign sb_peer_ack   = 1'b1;

    // 数据路径仅在 ACTIVE 时放行（打一拍，避免与状态机组合耦合）
    always_ff @(posedge lclk or negedge lrst_n) begin
        if (!lrst_n) link_active_q <= 1'b0;
        else         link_active_q <= link_active;
    end

    // =========================================================================
    // 5. 管理通道骨架（自定版，**非 UCIe 2.0 合规实现**）
    //    依据 UCIe 2.0 公开白皮书的机制清单自行定义寄存器映射与消息编码，
    //    覆盖 discovery / status query / error reporting；
    //    详见 rtl/phy/ucie_mgmt.sv 头部声明与 docs/SPEC.md。
    // =========================================================================
    logic [3:0] ltssm_state_bits;
    assign ltssm_state_bits = ltssm_state;      // enum → 位向量，供管理通道采集

    ucie_mgmt #(
        .CHIPLET_ID (8'hA0),
        .MGMT_VER   (8'h20)
    ) u_mgmt (
        .clk                (lclk),
        .rst_n              (lrst_n),
        .req_valid          (mgmt_req_valid),
        .req_we             (mgmt_req_we),
        .req_addr           (mgmt_req_addr),
        .req_wdata          (mgmt_req_wdata),
        .resp_rdata         (mgmt_resp_rdata),
        .resp_valid         (mgmt_resp_valid),
        .ltssm_state        (ltssm_state_bits),
        .link_active        (link_active),
        .valid_lanes        (valid_lanes),
        .repair_used        (repair_used),
        .a_crc_err          (a_crc_err),
        .a_nak_sent         (a_nak_sent),
        .a_retry            (a_retry),
        .b_crc_err          (b_crc_err),
        .sb_tx_valid        (mgmt_sb_tx_valid),
        .sb_tx_msg          (mgmt_sb_tx_msg),
        // 发现握手环回：本 demo 里对端 die 就在同一颗 RTL 内（真实芯片是跨 die 通道）
        .sb_rx_valid        (mgmt_sb_tx_valid),
        .sb_rx_msg          (mgmt_sb_tx_msg),
        .remote_retrain_req (mgmt_remote_retrain)
    );

endmodule

`endif  // UCIE_D2D_TOP_SV
