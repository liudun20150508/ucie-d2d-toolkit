// =============================================================================
// ucie-d2d-demo : toolchain smoke test
// -----------------------------------------------------------------------------
// 目的：确认本机 Verilator 能跑 SystemVerilog 自检测试台
//   - 时序控制 (#delay / always_ff)
//   - 并发断言 (SVA assert property)
//   - 覆盖 (cover property)
// 这一条不通，后面 LTSSM/重传的时序测试就不用写了。
// 编译方式： verilator --binary --timing --assert -Wall --top-module tb_smoke ...
// =============================================================================
`timescale 1ns/1ps

module tb_smoke;
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    int   cyc   = 0;
    int   cov_handshake = 0;

    always #5 clk = ~clk;   // 100 MHz

    always_ff @(posedge clk) begin
        if (!rst_n) cyc <= 0;
        else        cyc <= cyc + 1;
    end

    // 断言：复位后计数器不得出现 X
    a_known: assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(cyc))
        else $error("[SMOKE] cyc became X");

    // 覆盖：训练完成握手（这里用 rst_n 释放后第 3 拍模拟）
    c_ready: cover property (@(posedge clk) disable iff (!rst_n) (cyc == 3));

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (8) @(posedge clk);
        if (cyc >= 7 && cov_handshake == 0) begin
            cov_handshake = 1;
        end
        $display("[SMOKE] clk=%0dMHz cycles=%0d time=%0t status=%s",
                 1000 / 10, cyc, $time, (cyc >= 7) ? "PASS" : "FAIL");
        if (cyc < 7) $fatal(1, "[SMOKE] cycle counter did not advance");
        $finish;
    end
endmodule
