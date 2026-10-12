// =============================================================================
// ucie_if.sv : 验证环境的 virtual interface（对应 UVM 的 virtual interface）
// -----------------------------------------------------------------------------
// 路径：sim/uvm_style/ucie_if.sv
// 作用：把 DUT（rtl/top/ucie_d2d_top.sv）的全部端口聚合成一个接口，
//       供 ucie_pkg.sv 里的 driver / monitor 通过 virtual interface 访问。
// =============================================================================
`ifndef UCIE_IF_SV
`define UCIE_IF_SV

interface ucie_if;

    // 时钟与复位
    logic clk;
    logic rst_n;
    logic rdi_clk;
    logic rrst_n;

    // ---------------- A 侧协议层接口（64B 事务）----------------
    logic         a_tx_valid;
    logic         a_tx_ready;
    logic [511:0] a_tx_data;
    logic         a_rx_valid;
    logic         a_rx_ready;
    logic [511:0] a_rx_data;

    // ---------------- B 侧协议层接口 ----------------
    logic         b_tx_valid;
    logic         b_tx_ready;
    logic [511:0] b_tx_data;
    logic         b_rx_valid;
    logic         b_rx_ready;
    logic [511:0] b_rx_data;

    // ---------------- PHY / 训练控制 ----------------
    logic [ucie_pkg::LANES_TOTAL-1:0] lane_good;
    logic                             reversal_detect;
    logic                             train_enable;
    logic                             link_err_inject;
    logic                             err_inject_a2b;
    logic                             err_inject_b2a;

    // ---------------- 观测 ----------------
    ucie_pkg::ltssm_e                        ltssm_state;
    logic                                    link_active;
    logic [7:0]                              valid_lanes;
    logic                                    repair_used;
    logic [ucie_pkg::LANES-1:0][ucie_pkg::MAP_W-1:0] lane_map_out;
    logic [ucie_pkg::LANES-1:0]              effective_mask;
    logic [15:0] a_delivered, a_crc_err, a_nak_sent, a_retry;
    logic [15:0] b_delivered, b_crc_err, b_nak_sent;
    logic [7:0]  a_credit_left, a_inflight;

endinterface

`endif  // UCIE_IF_SV
