// =============================================================================
// cov/ucie_cov.sv — functional coverage（UVM 对应：coverage subscriber）
// -----------------------------------------------------------------------------
// 目录规范与写法参照 ref_project/tb/cov/pe_cov.sv。
//
// 修正记录：本项目早前一版在 ucie_pkg.sv 里写过
//   "Verilator 不支持 covergroup（约束随机是商业仿真器特性），因此手写采样统计"
// —— **前半句是错的**。Verilator 5.050 支持 covergroup / coverpoint / cross，
// 参考实现的 pe_cov.sv 就是用 covergroup 跑通的。
//
// 写法取舍（与 pe_cov.sv 一致）：
//   * 用 covergroup 声明式定义覆盖点与 bins —— 这是 UVM 的规范写法；
//   * bins 命中数由本类自己统计（hits_* 数组），**不调用 get_coverage() /
//     get_inst_coverage()** —— Verilator 对覆盖率查询 API 的支持不完整，
//     自己计数更稳，报告也更可读。
// =============================================================================
`ifndef UCIE_COV_SV
`define UCIE_COV_SV

import ucie_pkg::*;

class ucie_cov;
    mailbox #(logic [511:0]) mb;

    // ---- 采样变量（cg.sample() 读这些变量）----
    int          kind;        // 0=普通数据 1=误码场景 2=lane 降级场景
    logic [7:0]  b0;          // 载荷首字节
    logic [16:0] lane_mask;   // 采样时刻 lane 有效掩码

    covergroup cg;
        cp_kind : coverpoint kind {
            bins data      = {0};
            bins err       = {1};
            bins lane_down = {2};
        }
        cp_b0 : coverpoint b0 {
            bins low  = {[8'h00 : 8'h3F]};
            bins mid  = {[8'h40 : 8'hBF]};
            bins high = {[8'hC0 : 8'hFF]};
        }
        cp_lane : coverpoint lane_mask {
            bins full   = {17'h1FFFF};
            bins repair = {[17'h0FFFE : 17'h1FFFE]};
        }
        // 交叉覆盖：场景 × 载荷区间（证明"降级场景下各种载荷都测过"）
        cx_kind_b0 : cross cp_kind, cp_b0;
    endgroup

    // ---- bins 命中统计（自己算，不依赖覆盖率查询 API）----
    int hits_kind[3];
    int hits_b0[3];
    int hits_lane[2];
    int hits_cross[3][3];
    int unsigned samples = 0;

    function new(mailbox #(logic [511:0]) m);
        mb        = m;
        kind      = 0;
        b0        = 8'h00;
        lane_mask = 17'h1FFFF;
        cg        = new();
    endfunction

    function void set_kind(input int k);
        kind = ((k >= 0) && (k <= 2)) ? k : 0;
    endfunction

    function void set_lane_mask(input logic [16:0] m);
        lane_mask = m;
    endfunction

    function int b0_bin(input logic [7:0] v);
        return (v <= 8'h3F) ? 0 : ((v <= 8'hBF) ? 1 : 2);
    endfunction

    task automatic run();
        forever begin
            logic [511:0] got;
            int kb;
            mb.get(got);
            samples++;
            b0 = got[7:0];
            kb = b0_bin(b0);
            hits_kind[kind]++;
            hits_b0[kb]++;
            if (lane_mask == 17'h1FFFF) hits_lane[0]++;
            else                        hits_lane[1]++;
            hits_cross[kind][kb]++;
            cg.sample();               // 喂给 covergroup
        end
    endtask

    function void report();
        int k_hit = ((hits_kind[0] > 0) + (hits_kind[1] > 0) + (hits_kind[2] > 0));
        int b_hit = ((hits_b0[0] > 0) + (hits_b0[1] > 0) + (hits_b0[2] > 0));
        int l_hit = ((hits_lane[0] > 0) + (hits_lane[1] > 0));
        int c_hit = 0;
        for (int i = 0; i < 3; i++)
            for (int j = 0; j < 3; j++)
                if (hits_cross[i][j] > 0) c_hit++;
        $display("      [COV] 功能覆盖采样 %0d 笔（covergroup: cp_kind / cp_b0 / cp_lane + cross）",
                 samples);
        $display("      [COV] cp_kind bins %0d/3   cp_b0 bins %0d/3   cp_lane bins %0d/2",
                 k_hit, b_hit, l_hit);
        $display("      [COV] cross(cp_kind x cp_b0) bins %0d/9", c_hit);
    endfunction
endclass

`endif  // UCIE_COV_SV
