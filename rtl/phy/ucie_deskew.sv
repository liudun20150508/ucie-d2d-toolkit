// =============================================================================
// ucie_deskew : lane 间去偏斜（deskew）
// -----------------------------------------------------------------------------
// 对应 需求第 3 条 的「**时序对齐**」与 UCIe MBTRAIN 阶段的 deskew 子状态。
//
// 为什么需要它：真实封装里各 lane 的走线长度不同 → 到达时刻相差若干 UI（偏斜）。
// 而 RX 侧 ucie_rdi_rx 是按「单拍 pl_valid + 逐 lane 取字节」打包的
// （见 ucie_rdi.sv:112-120），如果 lane 之间存在偏斜，不同 UI 的字节会被拼进
// 同一个 flit，字节顺序错乱 —— 这不是误码，CRC 反而是对的，但数据是错的。
//
// 两阶段实现：
//   1) **测量**（train_mode=1）：各 lane 收到同一个训练 pattern（8'hA5），
//      记录每 lane 首次命中的时刻；取最早到达者为参考时基 →
//      skew[i] = arrive[i] - arrive_min
//   2) **补偿**（train_mode=0 且测量完成）：per-lane 弹性缓冲，
//      给每个 lane 施加 (max_skew - skew[i]) 拍的延迟 ——
//      早到的 lane 多等，晚到的少等，最终所有 lane 在同一拍对齐
//
// **粒度声明**：本 demo 的 RDI 抽象是「每 lane 每 UI 传 1 字节」，
//   因此对齐粒度是 **UI（周期）级**。真实 UCIe 还要在 bit/symbol 级做 deskew，
//   那属于 PHY 的 SERDES 部分，不在本 demo 的数字范围内。
//
// **旁路行为**：未完成测量、或处于训练期时，本模块**直通**（dsk_* = pl_*），
//   不改变原有行为 —— 这样接入后对既有场景是零影响。
// =============================================================================
`ifndef UCIE_DESKEW_SV
`define UCIE_DESKEW_SV

module ucie_deskew (
    input  logic clk,
    input  logic rst_n,

    input  logic [ucie_pkg::LANES-1:0] lane_valid,

    // ---------------- 训练期接口（MBTRAIN）----------------
    input  logic       train_mode,      // 1 = 正在测量偏斜
    input  logic       train_clr,       // 清测量结果（每次进 MBTRAIN 清一次）
    input  logic [7:0] train_pattern,   // 各 lane 共用的训练 pattern

    // ---------------- 数据通路 ----------------
    input  logic                pl_valid,
    input  ucie_pkg::rdi_data_t pl_data,
    input  ucie_pkg::rdi_mask_t pl_mask,

    output logic                dsk_valid,
    output ucie_pkg::rdi_data_t dsk_data,
    output ucie_pkg::rdi_mask_t dsk_mask,

    // ---------------- 观测 ----------------
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::SKEW_CNT_WIDTH-1:0] skew_measured,
    output logic [ucie_pkg::SKEW_CNT_WIDTH-1:0]                      max_skew,
    output logic                                                     deskew_done
);
    import ucie_pkg::*;

    localparam int SW = SKEW_CNT_WIDTH;   // 3
    localparam int D  = SKEW_MAX_UI;      // 4：最大补偿拍数
    // 预定义常量，避免在过程块里写 size cast
    // （`SW:0'(D)` 这类带范围的写法**非法**，Verilator 报 syntax error，踩过）
    localparam logic [SW-1:0] D_SAT = D;      // 饱和后的最大偏斜
    localparam logic [SW:0]   D_EXT = D;      // 扩展一位，便于与 arrive 差值比较

    // =========================================================================
    // 1) 测量：per-lane 到达时刻 → skew
    // =========================================================================
    logic [SW:0]              train_cnt;
    logic [LANES-1:0]         seen_v;
    logic [SW:0]              arrive [LANES];
    logic [SW:0]              arrive_min;
    logic [SW:0]              delta [LANES];   // 原始偏斜 = arrive[i] - arrive_min
    logic [SW:0]              rest  [LANES];   // 补偿拍数 = D - delta（饱和到 0）
    logic [LANES-1:0][SW-1:0] skew_q;
    logic [LANES-1:0][SW-1:0] delay_q;    // = max_skew - skew[i]
    logic [SW-1:0]            max_skew_q;
    logic                     measured_q;

    // 最早到达者作为参考时基
    always_comb begin
        arrive_min = '1;
        for (int l = 0; l < LANES; l++)
            if (seen_v[l] && (arrive[l] < arrive_min))
                arrive_min = arrive[l];
        // 最大偏斜 = 已测 skew 的最大值
        max_skew_q = '0;
        for (int l = 0; l < LANES; l++)
            if (seen_v[l] && (skew_q[l] > max_skew_q))
                max_skew_q = skew_q[l];
        // per-lane 原始偏斜与补偿拍数（提前算好，过程块里只做寄存）
        for (int l = 0; l < LANES; l++) begin
            delta[l] = seen_v[l] ? (arrive[l] - arrive_min) : '0;
            rest[l]  = (delta[l] > D_EXT) ? '0 : (D_EXT - delta[l]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            train_cnt  <= '0;
            seen_v     <= '0;
            measured_q <= 1'b0;
            for (int l = 0; l < LANES; l++) begin
                arrive[l]  <= '0;
                skew_q[l]  <= '0;
                delay_q[l] <= '0;
            end
        end else if (train_clr) begin
            // 每轮 MBTRAIN 重新测
            train_cnt  <= '0;
            seen_v     <= '0;
            measured_q <= 1'b0;
            for (int l = 0; l < LANES; l++) begin
                arrive[l]  <= '0;
                skew_q[l]  <= '0;
                delay_q[l] <= '0;
            end
        end else if (train_mode) begin
            train_cnt <= train_cnt + 1'b1;
            for (int l = 0; l < LANES; l++) begin
                if (lane_valid[l] && !seen_v[l] &&
                    pl_mask[l] && (pl_data[l*8 +: 8] == train_pattern)) begin
                    seen_v[l] <= 1'b1;
                    arrive[l] <= train_cnt;
                end
            end
            // 所有有效 lane 都见过 → 固化 skew 与补偿延迟
            if (seen_v == lane_valid) begin
                measured_q <= 1'b1;
                for (int l = 0; l < LANES; l++) begin
                    // 偏斜饱和到 D：超出补偿窗口就截断
                    skew_q[l]  <= (delta[l] > D_EXT) ? D_SAT : delta[l][SW-1:0];
                    delay_q[l] <= seen_v[l] ? rest[l][SW-1:0] : D_SAT;
                end
            end
        end
    end

    // =========================================================================
    // 2) 补偿：per-lane 弹性缓冲（深度 D+1 的移位线，按 delay_q 抽头）
    // =========================================================================
    logic [7:0] dly_d [LANES][0:D];
    logic       dly_v [LANES][0:D];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int l = 0; l < LANES; l++)
                for (int k = 0; k <= D; k++) begin
                    dly_d[l][k] <= 8'h00;
                    dly_v[l][k] <= 1'b0;
                end
        end else begin
            for (int l = 0; l < LANES; l++) begin
                dly_d[l][0] <= pl_data[l*8 +: 8];
                dly_v[l][0] <= pl_valid && pl_mask[l] && lane_valid[l];
                for (int k = 1; k <= D; k++) begin
                    dly_d[l][k] <= dly_d[l][k-1];
                    dly_v[l][k] <= dly_v[l][k-1];
                end
            end
        end
    end

    // 对齐输出；未测量完 / 训练期 → 直通
    always_comb begin
        dsk_data  = '0;
        dsk_mask  = '0;
        dsk_valid = 1'b0;
        // for 循环同样必须在最外层（理由见 ucie_rdi.sv 的同名改动）：
        // 条件挪进循环体，else 的"直通"逐 lane 展开；dsk_valid 的直通语义在循环后补一次。
        for (int l = 0; l < LANES; l++) begin
            if (measured_q && !train_mode) begin
                dsk_data[l*8 +: 8] = dly_d[l][delay_q[l]];
                dsk_mask[l]        = dly_v[l][delay_q[l]];
                dsk_valid          = dsk_valid | dly_v[l][delay_q[l]];
            end else begin
                dsk_data[l*8 +: 8] = pl_data[l*8 +: 8];
                dsk_mask[l]        = pl_mask[l];
            end
        end
        if (!(measured_q && !train_mode))
            dsk_valid = pl_valid;
    end

    assign skew_measured = skew_q;
    assign max_skew      = max_skew_q;
    assign deskew_done   = measured_q;

`ifndef SYNTHESIS
    // 测量完成后，补偿延迟必须落在缓冲深度内（否则抽头越界）
    // verilator lint_off SYNCASYNCNET
    a_delay_in_range: assert property (@(posedge clk) disable iff (!rst_n)
        measured_q |-> (max_skew_q <= D_SAT));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_DESKEW_SV
