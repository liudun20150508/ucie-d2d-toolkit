// =============================================================================
// tb_gatesim.v — 门级仿真测试台（**纯组合模块，穷举等价比对**）
// -----------------------------------------------------------------------------
// 目标模块：ucie_lane_repair（纯组合）
//   -> 输入 lane_good[16:0] 只有 2^17 种组合，**可以穷举**
//   -> 同一 TB 分别接 RTL(sv2v) 与门级网表，两次运行逐组比对输出
//   -> 组合逻辑的**完备**等价性证明：不是抽样，而是走完整个输入空间
//
// 为什么不用 ucie_ltssm：它含异步低有效复位与侧带握手，在 yosys sim 下复位边沿/
//   初始值语义难控（实测两条 trace 全 x）。组合模块无复位、无时序，语义无歧义，
//   同样的投入得到的证据反而更强。
//
// **端口必须逐个核对（踩过）**：本模块有 **两个输入**（lane_good、reversal_detect）。
//   初版只连了 lane_good，未连接的 reversal_detect = x 并传播到全部输出，
//   于是 RTL 侧整条 trace 全是 x —— 看着像"门级与 RTL 不一致"，其实是我 TB 漏了端口。
//   而门级侧却能算出值，因为 yosys 综合时把未驱动的输入优化成了常量 0。
//   `hierarchy -check` **没有**拦住这个错误（只报了一条 resize 警告）。
//
// yosys sim 的硬约束（都踩过）：
//   1) 不能在 `initial` 里用 `for + @(posedge clk)`（`ERROR: unexpected '@'`）
//   2) 不要调 `$finish`（被当作 ERROR）；时长交给 `sim -n <周期数>`
//   3) 端口宽度要精确，否则 read_verilog 会 resize 并补 x
//
// 跑法：sh flow/gatesim/run_gatesim.sh
// =============================================================================
`timescale 1ns/1ps

module tb_gatesim;
    reg clk = 1'b0;
    always #5.0 clk = ~clk;   // yosys sim 需要一个时钟来推进

    reg  [16:0]      lane_good;
    reg              reversal_detect;
    wire [15:0][4:0] lane_map;         // 16 个逻辑 lane × 5 位 = 80 位
    wire [15:0]      lane_map_valid;
    wire [7:0]       valid_lanes;
    wire             repair_used;
    wire [15:0]      effective_mask;

    ucie_lane_repair u_dut (
        .lane_good       (lane_good),
        .reversal_detect (reversal_detect),
        .lane_map        (lane_map),
        .lane_map_valid  (lane_map_valid),
        .valid_lanes     (valid_lanes),
        .repair_used     (repair_used),
        .effective_mask  (effective_mask)
    );

    integer g;
    initial begin
        g               = 0;
        lane_good       = 17'h00000;
        reversal_detect = 1'b0;      // 无 lane 反序（若漏连此项，整条 trace 会是 x）
    end

    // 相位 1（posedge）：设置本组输入
    always @(posedge clk) begin
        lane_good = g[16:0];
    end

    // 相位 2（negedge）：半周期后组合逻辑已稳定，打印本组输出
    always @(negedge clk) begin
        $display("[GS] %0d lm=%h lmv=%h vl=%0d ru=%0b em=%h",
                 g, lane_map, lane_map_valid, valid_lanes, repair_used, effective_mask);
        if (g < 131072) g = g + 1;
    end

endmodule
