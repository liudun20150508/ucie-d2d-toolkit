// =============================================================================
// ucie_env.sv — env（UVM 对应：env，装配 agent/scoreboard/coverage 并管理线程）
// =============================================================================
`ifndef UCIE_ENV_SV
`define UCIE_ENV_SV

import ucie_pkg::*;

class ucie_env;
    virtual ucie_if vif;
    ucie_driver     drv;
    ucie_monitor    mon;
    ucie_scb        scb;
    ucie_cov        cov;

    function new(virtual ucie_if v);
        vif = v;
        drv = new(v);
        mon = new(v);
        scb = new(mon.mb);          // monitor -> scoreboard
        cov = new(mon.mb_cov);      // monitor -> coverage
    endfunction

    // 启动三个常驻组件线程（monitor 采样 / scoreboard 比对 / coverage 采样）
    task automatic start_threads();
        fork
            mon.run();
            scb.run();
            cov.run();
        join_none
    endtask

    // 复位 + 推链路进入 ACTIVE
    task automatic bringup();
        vif.train_enable    = 1'b0;
        vif.link_err_inject = 1'b0;
        vif.err_inject_a2b  = 1'b0;
        vif.err_inject_b2a  = 1'b0;
        vif.lane_good       = '1;
        vif.reversal_detect = 1'b0;
        vif.b_tx_valid      = 1'b0;
        vif.b_rx_ready      = 1'b1;
        repeat (12) @(posedge vif.clk);
        vif.train_enable = 1'b1;
        while (!vif.link_active) @(posedge vif.clk);
    endtask

    task automatic report_all();
        scb.report();
        cov.report();
    endtask
endclass

`endif  // UCIE_ENV_SV
