// =============================================================================
// ucie_rdi : RDI（Raw D2D Interface）数字侧收发 —— flit <-> lane 字节流
// -----------------------------------------------------------------------------
// 对应 UCIe 里「物理层数字部分 / RDI」这一层：
//   * 把 68B flit 按 lane 逐字节“铺”到 RDI 数据线上（每 lane 每 UI 传 1B）
//   * 68B 不是 16B/UI 的整数倍，所以最后一个 UI 只有 4B 有效
//     —— 这也是真实 UCIe 里 lp_valid/pl_valid 必须**按字节**而非按拍描述的原因
//   * lane 修复/降级后有效 lane 变少时，每 UI 携带的字节数随之减少，
//     一个 flit 需要的 UI 数自动变多（带宽换可靠性），字节流仍然完整
//
// 两个方向都是“字节指针推进”模型：
//   发送 TX：byte_ptr 从 0 推到 68，每拍把尽可能多的字节放到有效 lane 上
//   接收 RX：按同一顺序把字节收回累加器，收满 68B 即产出一个 flit
//
// 说明：本模块**假设进入的 pl_data 已经对齐**（各 lane 同时到达）。
//       lane 间偏斜的测量与补偿由 rtl/phy/ucie_deskew.sv 负责，它插在
//       ucie_link_pipe 里本模块之前（误码注入点之后）。
//       因此本模块保持"单拍取全 lane"的简单打包逻辑 —— 这正是分层的好处：
//       对齐是独立模块的定位，打包器不必知道偏斜的存在。
// =============================================================================
`ifndef UCIE_RDI_SV
`define UCIE_RDI_SV

// -----------------------------------------------------------------------------
// 发送方向：flit -> RDI lane 字节流
// -----------------------------------------------------------------------------
module ucie_rdi_tx #(
    // =====================================================================
    // 低功耗：数据门控（对应 UCIe L1/L2 低功耗态的思路）
    //   0 = 原版：组合逻辑**始终**读 flit。由于 lp_valid=busy，空闲时输出本无意义，
    //       但它照样随 flit 翻转 —— 这是真实的无效动态功耗。
    //   1 = 门控：只在 busy 时读 flit，空闲期 lp_data 恒 0，翻转被消除；
    //       综合工具也能据此关掉这部分组合逻辑。
    // 用参数字而非条件编译，是为了让**同一份 RTL 综合出两个版本**并做功能等价对比
    // （手法取自既有项目的 tb_tcu_gate.sv：参数字 + 双 DUT 并列）。
    // =====================================================================
    parameter int DATA_GATING = 0
) (
    input  logic clk,
    input  logic rst_n,

    input  logic                    start,        // 上层要求发送一个 flit
    input  ucie_pkg::flit_t         flit,
    input  logic [ucie_pkg::LANES-1:0] lane_valid, // 训练后的有效 lane 掩码

    output logic                    lp_valid,     // 本 UI 有字节在传
    output ucie_pkg::rdi_data_t     lp_data,      // 按逻辑 lane 排布
    output ucie_pkg::rdi_mask_t     lp_mask,      // 每 lane 字节有效
    input  logic                    pl_trdy,      // PHY 就绪（可接收本 UI）

    output logic                    done,         // 一个 flit 传完（脉冲）
    output logic                    busy
);
    import ucie_pkg::*;

    logic [7:0] byte_ptr;   // 0..FLIT_BYTES

    logic [7:0] nxt_ptr;
    logic [7:0] carry_cnt;  // 本 UI 实际携带的字节数

    // 门控使能：门控版仅在 busy 时读 flit；原版恒为 1（行为与改动前逐字一致）
    logic rd_en;
    assign rd_en = (DATA_GATING == 0) ? 1'b1 : busy;

    always_comb begin
        lp_data   = '0;
        lp_mask   = '0;
        nxt_ptr   = byte_ptr;
        carry_cnt = 8'd0;

        for (int l = 0; l < LANES; l++) begin
            if (rd_en && lane_valid[l] && (nxt_ptr < FLIT_BYTES[7:0])) begin
                lp_data[l*8 +: 8] = flit[nxt_ptr*8 +: 8];
                lp_mask[l]        = 1'b1;
                nxt_ptr           = nxt_ptr + 8'd1;
                carry_cnt         = carry_cnt + 8'd1;
            end
        end
    end

    assign lp_valid = busy;
    assign done     = busy && pl_trdy && (nxt_ptr >= FLIT_BYTES[7:0]) && (carry_cnt != 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            byte_ptr <= 8'h00;
        end else if (!busy) begin
            if (start) begin
                busy     <= 1'b1;
                byte_ptr <= 8'h00;
            end
        end else if (pl_trdy) begin
            if (nxt_ptr >= FLIT_BYTES[7:0]) begin
                busy     <= 1'b0;
                byte_ptr <= 8'h00;
            end else begin
                byte_ptr <= nxt_ptr;
            end
        end
    end

    // ---------------------------------------------------------------------
    // 低功耗观测量（仅仿真，不进综合）：统计 lp_data 的位翻转数
    //   动态功耗 ∝ 翻转次数（P ≈ C·V²·f）。门控版在**空闲期**的翻转应恒为 0，
    //   这正是门控省下来的那部分 —— 用 tog_idle 与 tog_total 量化收益。
    // ---------------------------------------------------------------------
`ifndef SYNTHESIS
    logic [LANES*8-1:0] lp_data_q;
    logic [15:0]        tog_total;    // 累计翻转位数（全部周期）
    logic [15:0]        tog_idle;     // 累计翻转位数（空闲周期）
    logic [15:0]        idle_cycles;  // 空闲周期数

    function automatic logic [7:0] popcnt(input logic [LANES*8-1:0] v);
        logic [7:0] c;
        c = '0;
        for (int i = 0; i < LANES*8; i++) c = c + 8'(v[i]);
        return c;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lp_data_q   <= '0;
            tog_total   <= '0;
            tog_idle    <= '0;
            idle_cycles <= '0;
        end else begin
            lp_data_q <= lp_data;
            tog_total <= tog_total + 16'(popcnt(lp_data ^ lp_data_q));
            if (!busy) begin
                tog_idle    <= tog_idle + 16'(popcnt(lp_data ^ lp_data_q));
                idle_cycles <= idle_cycles + 16'd1;
            end
        end
    end
`endif

endmodule

// -----------------------------------------------------------------------------
// 接收方向：RDI lane 字节流 -> flit
// -----------------------------------------------------------------------------
module ucie_rdi_rx (
    input  logic clk,
    input  logic rst_n,

    input  logic [ucie_pkg::LANES-1:0] lane_valid,
    input  logic                    pl_valid,
    input  ucie_pkg::rdi_data_t     pl_data,
    input  ucie_pkg::rdi_mask_t     pl_mask,

    output logic                flit_valid,
    output ucie_pkg::flit_t     flit,
    output logic [7:0]          bytes_seen
);
    import ucie_pkg::*;

    logic [FLIT_BITS-1:0] acc_q, acc_c;
    logic [7:0]           cnt_q, cnt_c;
    logic                 complete;

    always_comb begin
        acc_c = acc_q;
        cnt_c = cnt_q;
        // for 循环必须在 always_comb 的**最外层**，不能包在 if 里：
        // 包在 if 里时 sv2v 会把循环变量提升为块内变量，而该变量在 if 为假时
        // 没有赋值，综合工具据此推断出 latch（`make dft` 报 NOT-SCAN-READY 的根因之一）。
        // 把 pl_valid 挪进循环体是等价的 —— 它是循环不变量。
        for (int l = 0; l < LANES; l++) begin
            if (pl_valid && lane_valid[l] && pl_mask[l] && (cnt_c < FLIT_BYTES[7:0])) begin
                acc_c[cnt_c*8 +: 8] = pl_data[l*8 +: 8];
                cnt_c               = cnt_c + 8'd1;
            end
        end
    end

    assign complete = pl_valid && (cnt_c >= FLIT_BYTES[7:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_q      <= '0;
            cnt_q      <= 8'h00;
            flit       <= '0;
            flit_valid <= 1'b0;
        end else begin
            flit_valid <= 1'b0;
            if (complete) begin
                flit       <= acc_c;      // 收满 68B，交出完整 flit
                flit_valid <= 1'b1;
                cnt_q      <= 8'h00;
                acc_q      <= '0;
            end else if (pl_valid) begin
                acc_q <= acc_c;
                cnt_q <= cnt_c;
            end
        end
    end

    assign bytes_seen = cnt_q;

endmodule

`endif  // UCIE_RDI_SV
