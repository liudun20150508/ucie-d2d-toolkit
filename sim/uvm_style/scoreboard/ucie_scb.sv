// =============================================================================
// scoreboard/ucie_scb.sv — scoreboard（UVM 对应：scoreboard，参考模型 + 比对 + 统计）
// -----------------------------------------------------------------------------
// 目录规范参照 ref_project/tb/scoreboard/pe_scb.sv
// =============================================================================
`ifndef UCIE_SCB_SV
`define UCIE_SCB_SV

import ucie_pkg::*;

class ucie_scb;
    mailbox #(logic [511:0]) mb;      // 从 monitor 收实际结果

    // ---- 期望队列（FIFO）----
    // driver 每驱动一笔 push 期望序号，monitor 每收一笔 pop 出来比对。
    // **不能拿"接收计数"当期望序号** —— driver 驱动的 idx 是任意值（1 / 100..107 / 200..400），
    // 与接收计数不是同一序号空间。踩过的现象：全部错配，且错配值呈 got(i) = exp(i+1) 的整体偏移。
    int unsigned exp_mem [0:8191];
    int unsigned exp_wr, exp_rd;

    int unsigned n_checked, n_mismatch;

    function new(mailbox #(logic [511:0]) m);
        mb         = m;
        exp_wr     = 0;
        exp_rd     = 0;
        n_checked  = 0;
        n_mismatch = 0;
    endfunction

    function void push(input int unsigned idx);
        exp_mem[exp_wr % 8192] = idx;
        exp_wr++;
    endfunction

    // 参考模型：由 idx 重算位精确期望（与 ucie_txn.compute() 同式）
    function logic [511:0] ref_model(input int unsigned idx);
        logic [511:0] exp;
        for (int b = 0; b < 64; b++)
            exp[b*8 +: 8] = 8'((idx * 31 + b * 7 + 3) & 32'hff);
        return exp;
    endfunction

    task automatic run();
        forever begin
            logic [511:0] got;
            int unsigned  idx;
            logic [511:0] exp;
            mb.get(got);
            if (exp_rd == exp_wr) continue;      // 无待比对期望（防御）
            idx = exp_mem[exp_rd % 8192];
            exp_rd++;
            exp = ref_model(idx);
            n_checked++;
            if (got !== exp) begin
                n_mismatch++;
                if (n_mismatch <= 3)
                    $display("      [SCB] MISMATCH idx=%0d", idx);
            end
        end
    endtask

    function void report();
        $display("      [SCB] 比对 %0d 笔，错配 %0d 笔", n_checked, n_mismatch);
    endfunction
endclass

`endif  // UCIE_SCB_SV
