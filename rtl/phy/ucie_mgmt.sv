// =============================================================================
// ucie_mgmt : 管理通道骨架（对应 UCIe 2.0 的 manageability，**自定简化版**）
// -----------------------------------------------------------------------------
// ⚠ **重要声明（讲的时候不要说过头）**
//   本模块是**按 UCIe 2.0 公开白皮书列出的机制清单自行设计的简化实现**，
//   **不是规范合规实现**：规范全文是会员制的，本机没有，因此寄存器映射、
//   消息编码、握手时序**全部为自定义**。
//   它证明的是"我知道管理通道要做什么、它在数字侧长什么样"，
//   **不是**"我实现了 UCIe 2.0 的可管理性"。
//
// 依据（UCIe 2.0 白皮书，官网公开 PDF）原文列出的机制：
//   discovery of chiplets and their configuration / initialization /
//   firmware download / power and thermal management / error reporting /
//   telemetry / log and crash dump / test and debug / self-test status /
//   chiplet security，并写明
//   "may be realized through hardware and/or firmware"（→ 纯数字/固件活，不需硬件）。
//
// 本模块覆盖其中**三类**（最小可验证子集）：
//   1) Discovery       : 读 CHIPLET_ID 与通道版本
//   2) Status query    : 读链路状态（LTSSM 态 / link_active / 有效 lane / 修复标志）
//   3) Error reporting : 读两侧错误计数（CRC 错 / NAK / 重传）
//   另附一个控制位：远程请求重训（写 REG_CTRL）—— 对应白皮书 "test and debug" 的一个最小落点。
//
// 架构对应白皮书的 "bridging function + 外部接口"：
//   本地 req/resp 访问接口相当于 SMBus/PCIe 桥接过来的下游；
//   跨 die 发现握手走 sideband。
// =============================================================================
`ifndef UCIE_MGMT_SV
`define UCIE_MGMT_SV

module ucie_mgmt #(
    parameter logic [7:0] CHIPLET_ID = 8'hA0,   // 本 chiplet 标识（发现用）
    parameter logic [7:0] MGMT_VER   = 8'h20    // 管理通道版本（借 2.0 编号，自定）
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---------------- 本地管理访问（模拟 SMBus/PCIe 桥接的下游）----------------
    input  logic        req_valid,
    input  logic        req_we,      // 1 = 写，0 = 读
                                     // （缺了它会导致"读操作顺带写寄存器"——踩过）
    input  logic [7:0]  req_addr,
    input  logic [31:0] req_wdata,
    output logic [31:0] resp_rdata,
    output logic        resp_valid,

    // ---------------- 被采集的链路状态 ----------------
    input  logic [3:0]  ltssm_state,
    input  logic        link_active,
    input  logic [7:0]  valid_lanes,
    input  logic        repair_used,
    input  logic [15:0] a_crc_err,
    input  logic [15:0] a_nak_sent,
    input  logic [15:0] a_retry,
    input  logic [15:0] b_crc_err,

    // ---------------- 跨 die 发现（sideband）----------------
    output logic        sb_tx_valid,
    output logic [7:0]  sb_tx_msg,
    input  logic        sb_rx_valid,
    input  logic [7:0]  sb_rx_msg,

    // ---------------- 控制输出 ----------------
    output logic        remote_retrain_req
);
    // 管理通道专用 sideband 消息码（自定；与 LTSSM 的 SB_MSG_* 不冲突即可）
    localparam logic [7:0] MGMT_MSG_DISCOVER = 8'hD0;  // 请求对端上报身份
    localparam logic [7:0] MGMT_MSG_ID       = 8'hD1;  // 身份响应

    // 寄存器地址映射（**自定**，非规范定义）
    localparam logic [7:0] REG_CHIPLET_ID  = 8'h00;  // RO [7:0] id / [15:8] mgmt ver
    localparam logic [7:0] REG_LINK_STATUS = 8'h01;  // RO [3:0] ltssm 态 / [4] active /
                                                     //    [12:5] valid_lanes / [13] repair_used
    localparam logic [7:0] REG_ERR_A       = 8'h02;  // RO [7:0] crc_err / [15:8] nak / [23:16] retry
    localparam logic [7:0] REG_ERR_B       = 8'h03;  // RO [7:0] crc_err
    localparam logic [7:0] REG_CTRL        = 8'h04;  // RW [0] 远程重训请求
                                                     //    [1] 发起一次发现（自清）
    localparam logic [7:0] REG_SCRATCH     = 8'h05;  // RW [31:0] 读写回环（验证写通路）

    localparam logic [31:0] RDATA_INVALID = 32'hDEAD_BEEF;   // 非法地址的哨兵值

    // ---------------- 读通路（组合）----------------
    always_comb begin
        case (req_addr)
            REG_CHIPLET_ID : resp_rdata = {16'h0000, MGMT_VER, CHIPLET_ID};
            REG_LINK_STATUS: resp_rdata = {18'h0, repair_used, valid_lanes, link_active, ltssm_state};
            REG_ERR_A      : resp_rdata = {a_retry[15:0], a_crc_err[15:0]};
            REG_ERR_B      : resp_rdata = {a_nak_sent[15:0], b_crc_err[15:0]};
            REG_CTRL       : resp_rdata = {31'h0, remote_retrain_req};
            REG_SCRATCH    : resp_rdata = scratch_q;
            default        : resp_rdata = RDATA_INVALID;
        endcase
    end

    // 响应：请求后一拍拉高（单周期脉冲）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) resp_valid <= 1'b0;
        else        resp_valid <= req_valid;
    end

    // ---------------- 写通路：REG_CTRL 的控制位 + REG_SCRATCH 的读写回环 ----------------
    logic [31:0] scratch_q;
    logic        discover_req_q;   // REG_CTRL[1]：发起一次发现（发出后自清）

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            remote_retrain_req <= 1'b0;
            scratch_q          <= 32'h0;
            discover_req_q     <= 1'b0;
        end else begin
            discover_req_q <= 1'b0;                  // 默认自清 → 单拍触发
            if (req_valid && req_we) begin
                if (req_addr == REG_CTRL) begin
                    remote_retrain_req <= req_wdata[0];
                    if (req_wdata[1]) discover_req_q <= 1'b1;
                end
                if (req_addr == REG_SCRATCH) scratch_q <= req_wdata;
            end
        end
    end

    // ---------------- 跨 die 发现握手（sideband）----------------
    // 收到 DISCOVER 请求即回一个 ID 响应；本 demo 里 sideband 在顶层环回，
    // 所以发起方可直接观测到这条响应 —— 真实芯片上是跨 die 的低速串行通道。
    // 发送优先级：本端发起的 DISCOVER > 对端 DISCOVER 的 ID 响应
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sb_tx_valid <= 1'b0;
            sb_tx_msg   <= 8'h00;
        end else if (discover_req_q) begin
            sb_tx_valid <= 1'b1;
            sb_tx_msg   <= MGMT_MSG_DISCOVER;   // 主动发起
        end else if (sb_rx_valid && (sb_rx_msg == MGMT_MSG_DISCOVER)) begin
            sb_tx_valid <= 1'b1;
            sb_tx_msg   <= MGMT_MSG_ID;         // 应答对端
        end else begin
            sb_tx_valid <= 1'b0;
        end
    end

endmodule

`endif  // UCIE_MGMT_SV
