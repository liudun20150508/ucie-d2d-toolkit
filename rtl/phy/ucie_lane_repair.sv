// =============================================================================
// ucie_lane_repair : lane 修复 / 重映射（冗余 lane 顶替坏 lane）
// -----------------------------------------------------------------------------
// 对应设计目标里的「lane repair / 高可靠性 / 良率提升」：
//
//   x16 module 额外提供 1 条冗余 lane（LANES_TOTAL = 17）。
//   训练阶段 PHY 给出每条物理 lane 的健康位 lane_good[]，本模块算出：
//     * lane_map[k]       —— 第 k 个**逻辑数据 lane** 落在哪条**物理 lane** 上
//     * lane_map_valid[k] —— 该逻辑 lane 是否真的可用（好 lane 不够时置 0）
//     * valid_lanes       —— 可用逻辑 lane 总数（供 LTSSM 判定是否降级）
//     * repair_used       —— 是否动用了冗余 lane（良率统计关注点）
//
// 还支持 lane reversal（走线反序）检测：反序时按逆序分配，等价于物理走线
// 交叉但逻辑上仍然对齐——真实芯片上这是常见的封装/走线差异。
//
// 位宽陷阱（踩过一次）：物理 lane 编号范围是 0..LANES_TOTAL-1，需要
// $clog2(LANES_TOTAL) 位。若照抄数据 lane 的宽度 [LANES-1:0]，冗余 lane 的
// 编号（16）会被截成 0，repair_used 永远算不出来、映射也会错位。
//
// 组合映射：训练结果一旦确定就固定，数据期不再变化。
// =============================================================================
`ifndef UCIE_LANE_REPAIR_SV
`define UCIE_LANE_REPAIR_SV

module ucie_lane_repair (
    input  logic [ucie_pkg::LANES_TOTAL-1:0] lane_good,       // 物理 lane 健康位
    input  logic                             reversal_detect, // 检测到 lane 反序
    // lane_map 是**数组**：16 个元素、每个 MAP_W(5) 位。
    // 坑：若写成 [MAP_W-1:0] 的一条 5 位向量，lane_map[k] 就变成“选第 k 个 bit”，
    // 映射表整个失效（表现为 repair_used 恒 0）。必须是 [LANES-1:0][MAP_W-1:0]。
    output logic [ucie_pkg::LANES-1:0][ucie_pkg::MAP_W-1:0] lane_map,
    output logic [ucie_pkg::LANES-1:0]       lane_map_valid,
    output logic [7:0]                       valid_lanes,
    output logic                             repair_used,
    output logic [ucie_pkg::LANES-1:0]       effective_mask    // 数据期使用的 lane 掩码
);
    import ucie_pkg::*;

    logic [LANES_TOTAL-1:0] scan;   // 按扫描顺序排列的物理 lane 健康位

    // lane reversal：物理走线反序时，把扫描顺序倒过来即可对齐
    assign scan = reversal_detect
                ? {<<{lane_good}}
                : lane_good;

    always_comb begin
        int unsigned k;
        k = 0;
        lane_map       = '0;
        lane_map_valid = '0;

        for (int i = 0; i < LANES_TOTAL; i++) begin
            if (scan[i] && (k < LANES)) begin
                lane_map[k]       = i[MAP_W-1:0];
                lane_map_valid[k] = 1'b1;
                k = k + 1;
            end
        end
        valid_lanes = k[7:0];

        // 是否用到了冗余 lane（物理编号 >= LANES 的那条）。
        // 这里刻意用“和整数常量比”的朴素写法：早期写成 MAP_W'(LANES) 的尺寸转换，
        // 结果判据没生效（repair_used 恒 0），改成 lane_map[i] > LANES-1 后正常。
        repair_used = 1'b0;
        for (int i = 0; i < LANES; i++) begin
            if (lane_map_valid[i] && (lane_map[i] > LANES - 1)) repair_used = 1'b1;
        end
    end

    assign effective_mask = lane_map_valid;

endmodule

`endif  // UCIE_LANE_REPAIR_SV
