// =============================================================================
// agent/ucie_monitor.sv — monitor（UVM 对应：monitor，被动采样不驱动）
// -----------------------------------------------------------------------------
// 目录规范参照 ref_project/tb/agent/pe_monitor.sv
// 采样到的实际事务推给 scoreboard 与 coverage（用 mailbox 解耦，与参考实现一致）
// =============================================================================
`ifndef UCIE_MONITOR_SV
`define UCIE_MONITOR_SV

import ucie_pkg::*;

class ucie_monitor;
    virtual ucie_if vif;
    int unsigned     n_got;

    mailbox #(logic [511:0]) mb;      // -> scoreboard
    mailbox #(logic [511:0]) mb_cov;  // -> coverage

    function new(virtual ucie_if v);
        vif   = v;
        n_got = 0;
        mb     = new();
        mb_cov = new();
    endfunction

    // 采样线程：监视 B 侧收到的每一笔（被动，不驱动任何信号）
    task automatic run();
        forever begin
            @(posedge vif.clk);
            if (vif.b_rx_valid && vif.b_rx_ready) begin
                n_got++;
                mb.put(vif.b_rx_data);
                mb_cov.put(vif.b_rx_data);
            end
        end
    endtask
endclass

`endif  // UCIE_MONITOR_SV
