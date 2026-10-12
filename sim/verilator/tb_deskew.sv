// =============================================================================
// tb_deskew.sv : ucie_deskew 单元级验证台
// -----------------------------------------------------------------------------
// 验证目标（对应 需求第 3 条 的「时序对齐」）：
//   1) **测量正确性**：给各 lane 注入已知的不同到达延迟，测得的 skew 必须与注一致
//   2) **对齐正确性**：在真偏斜下，对齐后所有 lane 的数据必须落在**同一拍**
//   3) **旁路不改行为**：未训练/训练期，dsk_* 必须等于 pl_*（直通）
//
// 做法：不引入注入端口，直接在本 TB 里**按 skew_target[l] 控制每个 lane 的到达时刻**
//   —— lane l 的 pattern/数据只在第 skew_target[l] 拍出现，其余拍该 lane 无效。
//   这比在顶层硬塞偏斜注入端口干净，也符合"模块级验证"的做法。
// =============================================================================
`timescale 1ns/1ps

module tb_deskew;
    import ucie_pkg::*;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5.0 clk = ~clk;

    localparam logic [7:0] PATTERN = 8'hA5;

    // ---------------- DUT 端口 ----------------
    logic [LANES-1:0] lane_valid;
    logic             train_mode, train_clr;
    logic [7:0]       train_pattern;
    logic             pl_valid;
    rdi_data_t        pl_data;
    rdi_mask_t        pl_mask;
    logic             dsk_valid;
    rdi_data_t        dsk_data;
    rdi_mask_t        dsk_mask;
    logic [LANES-1:0][SKEW_CNT_WIDTH-1:0] skew_measured;
    logic [SKEW_CNT_WIDTH-1:0]            max_skew;
    logic                                 deskew_done;

    ucie_deskew dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .lane_valid    (lane_valid),
        .train_mode    (train_mode),
        .train_clr     (train_clr),
        .train_pattern (train_pattern),
        .pl_valid      (pl_valid),
        .pl_data       (pl_data),
        .pl_mask       (pl_mask),
        .dsk_valid     (dsk_valid),
        .dsk_data      (dsk_data),
        .dsk_mask      (dsk_mask),
        .skew_measured (skew_measured),
        .max_skew      (max_skew),
        .deskew_done   (deskew_done)
    );

    // ---------------- 注入的偏斜（单位：UI/周期）----------------
    // lane 0 为参考（最早，skew=0）；4 号取到 SKEW_MAX_UI 边界。
    int skew_target [LANES];
    int fail_cnt = 0;

    task automatic check(input string name, input bit cond);
        if (cond) $display("  [PASS] %s", name);
        else begin $display("  [FAIL] %s", name); fail_cnt++; end
    endtask

    // 按 skew_target 摆放各 lane 的到达时刻：只有 t == skew_target[l] 那一拍该 lane 有效
    task automatic drive_slanted(input logic [7:0] base, input bit is_pattern);
        pl_valid = 1'b1;
        pl_data  = '0;
        pl_mask  = '0;
        for (int l = 0; l < LANES; l++) begin
            if (t_cur == skew_target[l]) begin
                pl_data[l*8 +: 8] = is_pattern ? PATTERN : (8'h10 + 8'(l));
                pl_mask[l]        = 1'b1;
            end
        end
    endtask

    int t_cur = 0;

    // ---------------- 主流程 ----------------
    initial begin
        $display("");
        $display("================================================================");
        $display(" ucie_deskew 单元验证（lane 间偏斜注入 → 测量 → 对齐）");
        $display("================================================================");

        // 注入的偏斜图案
        for (int l = 0; l < LANES; l++) skew_target[l] = 0;
        skew_target[0] = 0;   // 参考 lane（最早到达）
        skew_target[1] = 1;
        skew_target[2] = 2;
        skew_target[3] = 3;
        skew_target[4] = SKEW_MAX_UI;   // 边界值（=4）
        skew_target[5] = 2;
        skew_target[6] = 1;
        skew_target[7] = 3;

        // 初值
        lane_valid    = '1;
        train_mode    = 1'b0;
        train_clr     = 1'b0;
        train_pattern = PATTERN;
        pl_valid      = 1'b0;
        pl_data       = '0;
        pl_mask       = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------------- C1: 旁路行为（未训练）----------------
        // 训练前 dsk_* 应直通 pl_*
        pl_valid = 1'b1;
        pl_data  = {LANES{8'h3C}};
        pl_mask  = '1;
        @(posedge clk); #1;
        check("C1 未训练时直通 pl_valid", dsk_valid === pl_valid);
        check("C1 未训练时直通 pl_data",  dsk_data  === pl_data);
        pl_valid = 1'b0;
        pl_data  = '0;
        pl_mask  = '0;
        @(posedge clk); #1;

        // ---------------- C2: 训练测量 ----------------
        $display("[阶段] 训练：注入 per-lane 偏斜并测量");
        train_clr = 1'b1;
        repeat (2) @(posedge clk);
        train_clr = 1'b0;
        train_mode = 1'b1;

        for (t_cur = 0; t_cur < 16; t_cur++) begin
            drive_slanted(8'h00, 1'b1);
            @(posedge clk);
        end
        pl_valid = 1'b0;
        pl_mask  = '0;
        repeat (4) @(posedge clk);

        check("C2 测量完成（deskew_done）", deskew_done === 1'b1);
        for (int l = 0; l < LANES; l++)
            check($sformatf("C2 skew[%0d] 实测=%0d 注入=%0d",
                            l, skew_measured[l], skew_target[l]),
                  skew_measured[l] == skew_target[l]);
        check("C2 max_skew = 4（边界未被截断）", max_skew == SKEW_MAX_UI);

        // ---------------- C3: 对齐正确性 ----------------
        $display("[阶段] 数据：同样偏斜下，对齐后所有 lane 应落在同一拍");
        train_mode = 1'b0;
        repeat (2) @(posedge clk);

        // 各 lane 送不同数据，但到达时刻仍带偏斜。
        // 注意：**对齐拍出现在数据发送期内**（lane 0 在 t=0 到达、被延迟 max_skew 拍，
        // 正好与 t=max_skew 到达的 lane 4 同拍对齐），所以必须**边送边查** ——
        // 初版把检查放在送完之后，错过了该拍，导致 C3 假失败（TB 时序错误，非 DUT 问题）。
        begin
            bit aligned_seen = 1'b0;
            for (t_cur = 0; t_cur < 24; t_cur++) begin
                if (t_cur < 16) begin
                    drive_slanted(8'h00, 1'b0);
                end else begin
                    pl_valid = 1'b0;
                    pl_mask  = '0;
                    pl_data  = '0;
                end
                @(posedge clk); #1;
                if (!aligned_seen && dsk_valid && (dsk_mask == '1)) begin
                    aligned_seen = 1'b1;
                    for (int l = 0; l < LANES; l++)
                        check($sformatf("C3 对齐后 lane%0d 数据 = %0h",
                                        l, dsk_data[l*8 +: 8]),
                              dsk_data[l*8 +: 8] == (8'h10 + 8'(l)));
                end
            end
            check("C3 出现过全 lane 同时对齐的拍", aligned_seen);
        end

        // ---------------- C4: 重测（train_clr 生效）----------------
        $display("[阶段] 重测：改变偏斜图案后重新测量");
        skew_target[1] = 0;
        skew_target[2] = 0;
        skew_target[3] = 1;
        skew_target[4] = 1;
        skew_target[5] = 0;
        skew_target[6] = 0;
        skew_target[7] = 0;

        train_clr = 1'b1;
        repeat (2) @(posedge clk);
        train_clr = 1'b0;
        train_mode = 1'b1;
        for (t_cur = 0; t_cur < 16; t_cur++) begin
            drive_slanted(8'h00, 1'b1);
            @(posedge clk);
        end
        pl_valid = 1'b0;
        pl_mask  = '0;
        repeat (4) @(posedge clk);
        check("C4 重测后 max_skew = 1", max_skew == 3'd1);
        check("C4 重测后 skew[3] = 1", skew_measured[3] == 3'd1);
        check("C4 重测后 skew[4] = 1", skew_measured[4] == 3'd1);
        check("C4 重测后 skew[1] = 0", skew_measured[1] == 3'd0);

        // ---------------- 收尾 ----------------
        $display("");
        if (fail_cnt == 0) begin
            $display("=========== deskew 验证全部通过 (ALL PASS) ===========");
            $display("");
            $finish;
        end else begin
            $display("=========== 有 %0d 项失败 (FAILED) ===========", fail_cnt);
            $display("");
            $fatal(1, "deskew test failed");
        end
    end

    // 看门狗
    initial begin
        repeat (200000) @(posedge clk);
        $display("[WATCHDOG] 仿真超时");
        $fatal(1, "watchdog");
    end

endmodule
