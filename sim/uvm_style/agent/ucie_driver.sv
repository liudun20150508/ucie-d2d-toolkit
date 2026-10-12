// =============================================================================
// agent/ucie_driver.sv — driver（UVM 对应：driver，把 transaction 变成引脚时序）
// -----------------------------------------------------------------------------
// 目录规范参照 ref_project/tb/agent/pe_driver.sv
// =============================================================================
`ifndef UCIE_DRIVER_SV
`define UCIE_DRIVER_SV

import ucie_pkg::*;

class ucie_driver;
    virtual ucie_if vif;
    int unsigned n_sent;

    function new(virtual ucie_if v);
        vif    = v;
        n_sent = 0;
    endfunction

    task automatic reset();
        vif.a_tx_valid = 1'b0;
        vif.a_tx_data  = '0;
        vif.a_rx_ready = 1'b1;
        @(posedge vif.clk);
    endtask

    // 驱动一笔事务到 A 侧协议层接口（valid/ready 握手）
    task automatic send(ucie_txn t);
        @(posedge vif.clk);
        vif.a_tx_valid = 1'b1;
        vif.a_tx_data  = t.payload;
        do @(posedge vif.clk); while (vif.a_tx_ready !== 1'b1);
        vif.a_tx_valid = 1'b0;
        n_sent++;
    endtask
endclass

`endif  // UCIE_DRIVER_SV
