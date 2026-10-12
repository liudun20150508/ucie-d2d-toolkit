// =============================================================================
// ucie_txn.sv — transaction（UVM 对应：sequence item / transaction）
// -----------------------------------------------------------------------------
// 目录规范参照 ref_project/tb/（txn.sv / pe_txn.sv）
// class 直接放 .sv 文件、不用 package 包（与参考实现一致，编译时按依赖顺序列文件）
// =============================================================================
`ifndef UCIE_TXN_SV
`define UCIE_TXN_SV

import ucie_pkg::*;

class ucie_txn;
    // ---- 激励字段 ----
    int unsigned  idx;          // 事务序号（同时决定载荷内容，便于 scoreboard 重算期望）
    bit           use_err;      // 是否伴随误码注入
    bit           lane_down;    // 是否在 lane 降级状态下发出

    // ---- 期望（位精确定义，scoreboard 可独立重算）----
    logic [511:0] payload;

    function void compute();
        for (int b = 0; b < 64; b++)
            payload[b*8 +: 8] = 8'((idx * 31 + b * 7 + 3) & 32'hff);
    endfunction

    // 约束随机的替代：Verilator 不支持 randomize()，用 $urandom_range 手工构造
    function void randomize_manual();
        idx = $urandom_range(0, 100000);
        compute();
    endfunction

    function ucie_txn copy();
        ucie_txn c = new();
        c.idx       = idx;
        c.use_err   = use_err;
        c.lane_down = lane_down;
        c.payload   = payload;
        return c;
    endfunction

    function string convert2string();
        return $sformatf("txn(idx=%0d err=%0b lane_down=%0b)", idx, use_err, lane_down);
    endfunction
endclass

`endif  // UCIE_TXN_SV
