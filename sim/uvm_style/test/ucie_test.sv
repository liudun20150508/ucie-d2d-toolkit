// =============================================================================
// test/ucie_test.sv — test 用例装配（UVM 对应：test，把 seq/agent/env 组装成场景）
// -----------------------------------------------------------------------------
// 目录规范参照 ref_project/tb/test/pe_test.sv
// =============================================================================
`ifndef UCIE_TEST_SV
`define UCIE_TEST_SV

import ucie_pkg::*;

class ucie_test;
    ucie_env env;
    ucie_seq seq;
    int      fail_cnt;

    function new(virtual ucie_if v);
        env      = new(v);
        seq      = new();
        fail_cnt = 0;
    endfunction

    function void check(input string name, input bit cond);
        if (cond) $display("  [PASS] %s", name);
        else begin $display("  [FAIL] %s", name); fail_cnt++; end
    endfunction

    // 等待收到 n 笔（带超时），用于把"数量"作为检查点
    task automatic wait_rx(input int unsigned n, input int timeout, output bit ok);
        int g = 0;
        ok = 1'b0;
        while ((env.mon.n_got < n) && (g < timeout)) begin
            @(posedge env.vif.clk);
            g++;
        end
        if (env.mon.n_got >= n) ok = 1'b1;
    endtask

    task automatic run(input int n_rand);
        bit ok;
        int unsigned base;

        // ---------------- D1: 训练 ----------------
        $display("[DIR] 定向用例");
        env.bringup();
        check("D1 链路训练进入 ACTIVE", env.vif.link_active);

        // ---------------- D2: 单笔 ----------------
        base = env.mon.n_got;
        seq.body(ucie_seq::SEQ_DIR, 1, 1, env.drv, env.scb, env.cov);
        wait_rx(base + 1, 4000, ok);
        check("D2 单笔事务送达", ok);

        // ---------------- D3: 背靠背 8 笔 ----------------
        base = env.mon.n_got;
        seq.body(ucie_seq::SEQ_DIR, 8, 100, env.drv, env.scb, env.cov);
        wait_rx(base + 8, 8000, ok);
        check("D3 背靠背 8 笔全部送达", ok);

        // ---------------- D4: 误码注入下的事务（靠重传保证正确）----------------
        base = env.mon.n_got;
        fork
            begin
                for (int k = 0; k < 3; k++) begin
                    @(posedge env.vif.rdi_clk);
                    env.vif.err_inject_a2b = 1'b1;
                    @(posedge env.vif.rdi_clk);
                    env.vif.err_inject_a2b = 1'b0;
                    repeat (8) @(posedge env.vif.rdi_clk);
                end
            end
            begin
                env.cov.set_kind(1);
                seq.body(ucie_seq::SEQ_DIR, 8, 200, env.drv, env.scb, env.cov);
            end
        join
        wait_rx(base + 8, 12000, ok);
        check("D4 误码下 8 笔仍正确送达", ok);

        // ---------------- D5: 打坏 1 条 lane -> 冗余顶替 ----------------
        env.vif.lane_good[3] = 1'b0;
        env.vif.link_err_inject = 1'b1;
        repeat (6) @(posedge env.vif.clk);
        env.vif.link_err_inject = 1'b0;
        while (!env.vif.link_active) @(posedge env.vif.clk);
        check("D5 lane 修复后 valid_lanes=16", env.vif.valid_lanes == 8'd16);
        check("D5 已动用冗余 lane", env.vif.repair_used == 1'b1);
        base = env.mon.n_got;
        env.cov.set_kind(2);
        env.cov.set_lane_mask(env.vif.lane_good);
        seq.body(ucie_seq::SEQ_DIR, 4, 300, env.drv, env.scb, env.cov);
        wait_rx(base + 4, 8000, ok);
        check("D5 修复后事务仍正确", ok);

        // ---------------- D6: 再打坏 1 条 -> 降级到 15 lane ----------------
        env.vif.lane_good[5] = 1'b0;
        env.vif.link_err_inject = 1'b1;
        repeat (6) @(posedge env.vif.clk);
        env.vif.link_err_inject = 1'b0;
        while (!env.vif.link_active) @(posedge env.vif.clk);
        check("D6 降级到 15 lane", env.vif.valid_lanes == 8'd15);
        base = env.mon.n_got;
        env.cov.set_kind(2);
        env.cov.set_lane_mask(env.vif.lane_good);
        seq.body(ucie_seq::SEQ_DIR, 4, 400, env.drv, env.scb, env.cov);
        wait_rx(base + 4, 12000, ok);
        check("D6 降级后事务仍正确", ok);

        // ---------------- D7: 载荷字段边界 ----------------
        base = env.mon.n_got;
        env.cov.set_kind(0);
        seq.body(ucie_seq::SEQ_BOUNDARY, 4, 0, env.drv, env.scb, env.cov);
        wait_rx(base + 4, 8000, ok);
        check("D7 载荷边界模式送达", ok);

        // ---------------- R1: 随机 ----------------
        $display("[RND] 随机用例 %0d 笔", n_rand);
        base = env.mon.n_got;
        seq.body(ucie_seq::SEQ_RAND, n_rand, 0, env.drv, env.scb, env.cov);
        wait_rx(base + n_rand, 20000 + n_rand * 400, ok);
        check($sformatf("R1 随机 %0d 笔全部送达", n_rand), ok);

        // ---------------- 收尾 ----------------
        repeat (200) @(posedge env.vif.clk);
        env.report_all();

        check("汇总：发送数 = 接收数", env.drv.n_sent == env.mon.n_got);
        check("汇总：零字节错配", env.scb.n_mismatch == 0);
    endtask
endclass

`endif  // UCIE_TEST_SV
