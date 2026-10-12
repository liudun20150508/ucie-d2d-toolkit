// =============================================================================
// ucie_ltssm : 链路训练状态机（Link Training and Status State Machine）
// -----------------------------------------------------------------------------
// 对应设计目标里的「链路训练 / bring-up / 时序对齐」：
//
//   RESET ──> SBINIT ──> MBINIT ──> MBTRAIN ──> LINKINIT ──> ACTIVE
//     ^                                  │                        │
//     │                                  v                        │ link_error
//     └──────── TRAINERROR <────── 训练失败                  PHYRETRAIN
//                  │                                              │
//                  v                                              │
//                 L1 （低功耗 / 降级，等重新使能）  <──────────────┘
//
// 各阶段语义（对齐 UCIe 的分层训练思想）：
//   SBINIT   : 侧带握手，交换 lane 数 / 速率等参数
//   MBINIT   : 主带初始化，协商 lane 映射（含冗余 lane 修复结果）
//   MBTRAIN  : 主带训练——本状态经 ucie_d2d_top 派生出 deskew_train/deskew_clr，
//              驱动 ucie_deskew 完成 per-lane 偏斜测量与对齐；电气参数收敛仍为占位
//   LINKINIT : 链路层初始化——credit / 重传窗口参数握手
//   ACTIVE   : 数据路径放行
//   PHYRETRAIN + TRAINERROR + 重训次数上限 = 真实链路里的容错闭环
//
// 侧带（sideband）在这里是**单工握手 + 超时容错**：发出消息后等对端 ACK
// 或计数超时，二者先到为准——真实链路上侧带也可能丢，超时兜底是必需的。
// =============================================================================
`ifndef UCIE_LTSSM_SV
`define UCIE_LTSSM_SV

module ucie_ltssm #(
    parameter int SBINIT_CYCLES   = 8,
    parameter int MBINIT_CYCLES   = 8,
    parameter int MBTRAIN_CYCLES  = 16,
    parameter int LINKINIT_CYCLES = 8,
    parameter int TRAINERROR_CYCLES = 8,
    parameter int MAX_RETRAIN     = 2
)(
    input  logic clk,
    input  logic rst_n,
    input  logic enable,             // 上位机/CSR 使能训练
    input  logic link_error_in,      // 链路层上报不可恢复错误 -> 触发重训

    // ---- 侧带：本端 -> 对端 ----
    output logic       sb_valid,
    output logic [7:0] sb_msg,
    output logic [7:0] sb_arg,
    input  logic       sb_peer_ack,  // 对端已收妥本端侧带消息

    // ---- 侧带：对端 -> 本端 ----
    input  logic       sb_peer_valid,
    input  logic [7:0] sb_peer_msg,

    // ---- PHY / lane 状态 ----
    input  logic [ucie_pkg::LANES_TOTAL-1:0] lane_good,   // 每条物理 lane 的可用性
    input  logic [7:0]                       valid_lanes, // lane_repair 算出的可用 lane 数

    // ---- 输出 ----
    output ucie_pkg::ltssm_e state,
    output logic             link_active,
    output logic             train_error,
    output logic             retrain_pulse,
    output logic [15:0]      train_cycles,
    output logic [3:0]       retrain_cnt
);
    import ucie_pkg::*;

    ltssm_e      st_q, st_d;
    logic [15:0] cnt_q, cnt_d;
    logic [15:0] total_q, total_d;
    logic [3:0]  rtry_q, rtry_d;

    assign state        = st_q;
    assign link_active  = (st_q == LTS_ACTIVE);
    assign train_error  = (st_q == LTS_TRAINERROR);
    assign train_cycles = total_q;
    assign retrain_cnt  = rtry_q;

    // 本端侧带消息（按阶段驱动）
    always_comb begin
        sb_valid = 1'b0;
        sb_msg   = SB_MSG_NOP;
        sb_arg   = 8'h00;
        if (enable && (cnt_q == 16'd0)) begin
            unique case (st_q)
                LTS_SBINIT: begin
                    sb_valid = 1'b1;
                    sb_msg   = SB_MSG_PARAM_REQ;
                    sb_arg   = LANES[7:0];
                end
                LTS_MBINIT: begin
                    sb_valid = 1'b1;
                    sb_msg   = SB_MSG_LANE_MAP;
                    sb_arg   = valid_lanes;
                end
                LTS_LINKINIT: begin
                    sb_valid = 1'b1;
                    sb_msg   = SB_MSG_TRAIN_DONE;
                    sb_arg   = CREDIT_INIT[7:0];
                end
                default: ;
            endcase
        end
    end

    // 阶段超时：对端 ACK 或计数到期，先到为准
    function automatic logic stage_done(input logic [15:0] c, input int limit,
                                        input logic ack_ok);
        return ack_ok || (c >= limit[15:0]);
    endfunction

    // ------------------------------------------------------------ 次态逻辑
    always_comb begin
        st_d    = st_q;
        cnt_d   = cnt_q + 16'd1;
        total_d = total_q + 16'd1;
        rtry_d  = rtry_q;

        unique case (st_q)
            LTS_RESET: begin
                cnt_d = 16'd0;
                if (enable) begin
                    st_d    = LTS_SBINIT;
                    total_d = 16'd0;
                end
            end

            LTS_SBINIT: begin
                if (stage_done(cnt_q, SBINIT_CYCLES, sb_peer_ack)) begin
                    cnt_d = 16'd0;
                    st_d  = LTS_MBINIT;
                end
            end

            LTS_MBINIT: begin
                if (stage_done(cnt_q, MBINIT_CYCLES, sb_peer_valid && (sb_peer_msg == SB_MSG_PARAM_ACK))) begin
                    cnt_d = 16'd0;
                    st_d  = LTS_MBTRAIN;
                end
            end

            LTS_MBTRAIN: begin
                // 训练收敛条件：时窗结束 且 可用 lane 数不少于一半
                if (cnt_q >= MBTRAIN_CYCLES[15:0]) begin
                    cnt_d = 16'd0;
                    if (valid_lanes >= (LANES / 2)) begin
                        st_d = LTS_LINKINIT;
                    end else begin
                        st_d   = LTS_TRAINERROR;
                        rtry_d = rtry_q + 4'd1;
                    end
                end
            end

            LTS_LINKINIT: begin
                if (stage_done(cnt_q, LINKINIT_CYCLES, sb_peer_valid && (sb_peer_msg == SB_MSG_TRAIN_DONE))) begin
                    cnt_d = 16'd0;
                    st_d  = LTS_ACTIVE;
                end
            end

            LTS_ACTIVE: begin
                cnt_d = 16'd0;
                rtry_d = 4'd0;   // 训练成功即清零计数：否则历史失败会累积，最终误判降级
                if (link_error_in) begin
                    st_d = LTS_PHYRETRAIN;
                end
            end

            LTS_PHYRETRAIN: begin
                if (cnt_q >= MBTRAIN_CYCLES[15:0]) begin
                    cnt_d = 16'd0;
                    if (rtry_q < MAX_RETRAIN[3:0]) begin
                        rtry_d = rtry_q + 4'd1;
                        st_d   = LTS_MBTRAIN;
                    end else begin
                        st_d = LTS_TRAINERROR;
                    end
                end
            end

            LTS_TRAINERROR: begin
                if (cnt_q >= TRAINERROR_CYCLES[15:0]) begin
                    cnt_d = 16'd0;
                    if (rtry_q < MAX_RETRAIN[3:0]) begin
                        st_d = LTS_SBINIT;      // 整链路重训
                    end else begin
                        st_d = LTS_L1;          // 放弃高速模式，降级
                    end
                end
            end

            LTS_L1: begin
                cnt_d = 16'd0;
                if (!enable) begin
                    st_d = LTS_RESET;
                    rtry_d = 4'd0;
                end
            end

            default: st_d = LTS_RESET;
        endcase
    end

    // ------------------------------------------------------------ 状态更新
    logic prev_active;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q       <= LTS_RESET;
            cnt_q      <= 16'd0;
            total_q    <= 16'd0;
            rtry_q     <= 4'd0;
            prev_active<= 1'b0;
        end else begin
            st_q        <= st_d;
            cnt_q       <= cnt_d;
            total_q     <= total_d;
            rtry_q      <= rtry_d;
            prev_active <= (st_q == LTS_ACTIVE);
        end
    end

    // 进入 ACTIVE 的上升沿脉冲（供 top 清计数/清错误）
    assign retrain_pulse = (st_q == LTS_ACTIVE) && !prev_active;

    // ------------------------------------------------------------ 断言
`ifndef SYNTHESIS
    // 同 ucie_link_retry：rst_n 既是异步复位、又是断言的 disable iff，
    // 触发 SYNCASYNCNET 误报（断言综合时不存在）。局部抑制。
    /* verilator lint_off SYNCASYNCNET */
    // 链路错误只可能从 ACTIVE 进重训，不能在训练中途把状态机拽走
    a_err_path: assert property (@(posedge clk) disable iff (!rst_n)
        ((st_q == LTS_SBINIT) || (st_q == LTS_MBINIT) || (st_q == LTS_MBTRAIN))
        |-> (st_d != LTS_ACTIVE) || (st_d == LTS_LINKINIT));
    // L1 只能由 TRAINERROR 进入
    a_l1_src: assert property (@(posedge clk) disable iff (!rst_n)
        ((st_d == LTS_L1) |-> (st_q == LTS_TRAINERROR) || (st_q == LTS_L1)));
    /* verilator lint_on SYNCASYNCNET */
`endif

endmodule

`endif  // UCIE_LTSSM_SV
