// =============================================================================
// test_top.sv — 顶层（UVM 对应：top module / testbench）
// -----------------------------------------------------------------------------
// 结构参照 ref_project/tb/test_top.sv：
//   时钟/复位 + DUT + interface + 启动 test（test 内部装配 env/seq）
// 跑法：sh sim/uvm_style/run.sh [随机笔数]
// =============================================================================
`timescale 1ns/1ps

module test_top;
    import ucie_pkg::*;

    logic clk     = 1'b0;
    logic rst_n   = 1'b0;
    logic rdi_clk = 1'b0;
    logic rrst_n  = 1'b0;

    always #5.0  clk     = ~clk;      // 100 MHz
    always #3.75 rdi_clk = ~rdi_clk;  // 133.3 MHz（异频，CDC 真被验证）

    ucie_if vif();

    assign vif.clk     = clk;
    assign vif.rst_n   = rst_n;
    assign vif.rdi_clk = rdi_clk;
    assign vif.rrst_n  = rrst_n;

    // ---------------- DUT ----------------
    ucie_d2d_top u_dut (
        .lclk            (clk),
        .lrst_n          (rst_n),
        .rdi_clk         (rdi_clk),
        .rrst_n          (rrst_n),
        .a_tx_valid      (vif.a_tx_valid),
        .a_tx_ready      (vif.a_tx_ready),
        .a_tx_data       (vif.a_tx_data),
        .a_rx_valid      (vif.a_rx_valid),
        .a_rx_ready      (vif.a_rx_ready),
        .a_rx_data       (vif.a_rx_data),
        .b_tx_valid      (vif.b_tx_valid),
        .b_tx_ready      (vif.b_tx_ready),
        .b_tx_data       (vif.b_tx_data),
        .b_rx_valid      (vif.b_rx_valid),
        .b_rx_ready      (vif.b_rx_ready),
        .b_rx_data       (vif.b_rx_data),
        .lane_good       (vif.lane_good),
        .reversal_detect (vif.reversal_detect),
        .train_enable    (vif.train_enable),
        .link_err_inject (vif.link_err_inject),
        .err_inject_a2b  (vif.err_inject_a2b),
        .err_inject_b2a  (vif.err_inject_b2a),
        .ltssm_state     (vif.ltssm_state),
        .link_active     (vif.link_active),
        .valid_lanes     (vif.valid_lanes),
        .repair_used     (vif.repair_used),
        .lane_map_out    (vif.lane_map_out),
        .effective_mask  (vif.effective_mask),
        .a_delivered     (vif.a_delivered),
        .a_crc_err       (vif.a_crc_err),
        .a_nak_sent      (vif.a_nak_sent),
        .a_retry         (vif.a_retry),
        .b_delivered     (vif.b_delivered),
        .b_crc_err       (vif.b_crc_err),
        .b_nak_sent      (vif.b_nak_sent),
        .a_credit_left   (vif.a_credit_left),
        .a_inflight      (vif.a_inflight)
    );

    // ---------------- 启动 ----------------
    int n_rand = 20;
    int g_fail = 0;

    initial begin
        if ($value$plusargs("N=%d", n_rand)) ;
        vif.a_tx_valid   = 1'b0;
        vif.a_tx_data    = '0;
        vif.a_rx_ready   = 1'b1;
        vif.b_tx_valid   = 1'b0;
        vif.b_rx_ready   = 1'b1;
        vif.lane_good    = '1;
        vif.train_enable = 1'b0;

        $display("");
        $display("================================================================");
        $display(" UCIe D2D 分层验证环境（UVM 风格，Verilator + covergroup）");
        $display("================================================================");

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        rrst_n = 1'b1;
        repeat (4) @(posedge clk);

        g_test = new(vif);
        g_test.env.start_threads();      // 启动 monitor / scoreboard / coverage
        g_test.run(n_rand);
        g_fail = g_test.fail_cnt;

        if (g_fail == 0) begin
            $display("");
            $display("=========== 全部用例通过 (ALL PASS) ===========");
            $display("");
            $finish;
        end else begin
            $display("");
            $display("=========== 有 %0d 项失败 (FAILED) ===========", g_fail);
            $display("");
            $fatal(1, "uvm_style test failed");
        end
    end

    ucie_test g_test;

    // 看门狗
    initial begin
        repeat (2000000) @(posedge clk);
        $display("[WATCHDOG] 仿真超时");
        $fatal(1, "watchdog");
    end

endmodule
