// =============================================================================
// tb_mgmt : 管理通道骨架的功能验证（自定版，**非 UCIe 2.0 合规实现**）
// -----------------------------------------------------------------------------
// 验证四件事：
//   T1 Discovery      —— 读 CHIPLET_ID / 管理通道版本
//   T2 Status query   —— 链路训练到 ACTIVE 后读链路状态
//   T3 Error report   —— 读两侧错误计数（字段布局正确；链路跑过后数值可用）
//   T4 写通路          —— 写 SCRATCH 再读回比对（验证写路径真的通）
//   T5 发现握手        —— sideband 上的 DISCOVER → ID 响应
//
// 用法：make mgmt
// =============================================================================
`timescale 1ns/1ps

module tb_mgmt;
    import ucie_pkg::*;

    // ---------------- 时钟 / 复位 ----------------
    logic lclk = 0, rdi_clk = 0, lrst_n = 0;
    always #5    lclk    = ~lclk;      // 100.0 MHz
    always #3.75 rdi_clk = ~rdi_clk;   // 133.3 MHz

    // ---------------- 事务接口（本 tb 不发数据，只接出观察）----------------
    logic         a_tx_valid = 0, a_tx_ready;
    logic [511:0] a_tx_data  = '0;
    logic         a_rx_valid,     a_rx_ready = 1'b1;
    logic [511:0] a_rx_data;
    logic         b_tx_valid = 0, b_tx_ready;
    logic [511:0] b_tx_data  = '0;
    logic         b_rx_valid,     b_rx_ready = 1'b1;
    logic [511:0] b_rx_data;

    // ---------------- PHY / 训练控制 ----------------
    logic [LANES_TOTAL-1:0] lane_good = '1;
    logic reversal_detect = 1'b0, train_enable = 1'b0, link_err_inject = 1'b0;
    logic err_inject_a2b  = 1'b0, err_inject_b2a = 1'b0;

    // ---------------- 观测 ----------------
    ltssm_e ltssm_state;
    logic   link_active, repair_used, deskew_done_a2b, deskew_done_b2a;
    logic [7:0] valid_lanes, a_credit_left, a_inflight;
    logic [LANES-1:0] effective_mask;
    logic [LANES-1:0][MAP_W-1:0] lane_map_out;
    logic [15:0] a_delivered, a_crc_err, a_nak_sent, a_retry;
    logic [15:0] b_delivered, b_crc_err, b_nak_sent;
    logic [LANES-1:0][SKEW_CNT_WIDTH-1:0] skew_a2b, skew_b2a;
    logic [SKEW_CNT_WIDTH-1:0] max_skew_a2b, max_skew_b2a;

    // ---------------- 管理通道 ----------------
    logic        mgmt_req_valid = 1'b0;
    logic        mgmt_req_we    = 1'b0;
    logic [7:0]  mgmt_req_addr  = 8'h00;
    logic [31:0] mgmt_req_wdata = 32'h0;
    logic [31:0] mgmt_resp_rdata;
    logic        mgmt_resp_valid, mgmt_remote_retrain;
    logic        mgmt_sb_tx_valid;
    logic [7:0]  mgmt_sb_tx_msg;

    ucie_d2d_top dut (
        .lclk, .lrst_n, .rdi_clk, .rrst_n (lrst_n),
        .a_tx_valid, .a_tx_ready, .a_tx_data,
        .a_rx_valid, .a_rx_ready, .a_rx_data,
        .b_tx_valid, .b_tx_ready, .b_tx_data,
        .b_rx_valid, .b_rx_ready, .b_rx_data,
        .lane_good, .reversal_detect, .train_enable, .link_err_inject,
        .err_inject_a2b, .err_inject_b2a,
        .ltssm_state, .link_active, .valid_lanes, .repair_used, .effective_mask,
        .lane_map_out,
        .a_delivered, .a_crc_err, .a_nak_sent, .a_retry,
        .b_delivered, .b_crc_err, .b_nak_sent,
        .a_credit_left, .a_inflight,
        .skew_measured_a2b (skew_a2b), .max_skew_a2b, .deskew_done_a2b,
        .skew_measured_b2a (skew_b2a), .max_skew_b2a, .deskew_done_b2a,
        .mgmt_req_valid, .mgmt_req_we, .mgmt_req_addr, .mgmt_req_wdata,
        .mgmt_resp_rdata, .mgmt_resp_valid, .mgmt_remote_retrain,
        .mgmt_sb_tx_valid, .mgmt_sb_tx_msg
    );

    // ---------------- 统计 ----------------
    int checks = 0, errors = 0;

    task automatic chk(input string name, input logic cond);
        checks++;
        if (cond) $display("  [PASS] %s", name);
        else begin
            errors++;
            $display("  [FAIL] %s", name);
        end
    endtask

    // ---------------- 管理通道访问 ----------------
    // 读：拉 req 一拍 → 等 resp_valid → 取 rdata
    task automatic mgmt_read(input logic [7:0] addr, output logic [31:0] rdata);
        @(negedge lclk);
        mgmt_req_addr  = addr;
        mgmt_req_wdata = 32'h0;
        mgmt_req_we    = 1'b0;          // 读：不写任何寄存器
        mgmt_req_valid = 1'b1;
        @(negedge lclk);
        mgmt_req_valid = 1'b0;
        wait (mgmt_resp_valid === 1'b1);
        rdata = mgmt_resp_rdata;
        @(negedge lclk);
    endtask

    // 写：拉 req 一拍即可（写通路在 req_valid 拍生效）
    task automatic mgmt_write(input logic [7:0] addr, input logic [31:0] wdata);
        @(negedge lclk);
        mgmt_req_addr  = addr;
        mgmt_req_wdata = wdata;
        mgmt_req_we    = 1'b1;          // 写
        mgmt_req_valid = 1'b1;
        @(negedge lclk);
        mgmt_req_valid = 1'b0;
        @(negedge lclk);
    endtask

    // ---------------- 寄存器地址（与 rtl/phy/ucie_mgmt.sv 一致）----------------
    localparam logic [7:0] REG_CHIPLET_ID  = 8'h00;
    localparam logic [7:0] REG_LINK_STATUS = 8'h01;
    localparam logic [7:0] REG_ERR_A       = 8'h02;
    localparam logic [7:0] REG_ERR_B       = 8'h03;
    localparam logic [7:0] REG_CTRL        = 8'h04;
    localparam logic [7:0] REG_SCRATCH     = 8'h05;

    localparam logic [7:0] MGMT_MSG_DISCOVER = 8'hD0;
    localparam logic [7:0] MGMT_MSG_ID       = 8'hD1;

    logic [31:0] rd;

    // ---------------- 主流程 ----------------
    initial begin
        $display("\n================================================================\n 管理通道骨架验证（自定版，非 UCIe 2.0 合规实现）\n================================================================");

        // 复位
        repeat (10) @(negedge lclk);
        lrst_n = 1'b1;
        repeat (5) @(negedge lclk);

        // ---------------- T1 Discovery ----------------
        $display("[T1] Discovery：读 chiplet 身份");
        mgmt_read(REG_CHIPLET_ID, rd);
        $display("      ID/VER = 0x%08h", rd);
        chk("T1 chiplet ID = 0xA0",      rd[7:0]   == 8'hA0);
        chk("T1 管理通道版本 = 0x20",     rd[15:8]  == 8'h20);

        // ---------------- T4 写通路 ----------------
        $display("[T4] 写通路：SCRATCH 写入 → 读回");
        mgmt_write(REG_SCRATCH, 32'hC0DE_1234);
        mgmt_read (REG_SCRATCH, rd);
        $display("      SCRATCH 读回 = 0x%08h（写入 0xC0DE1234）", rd);
        chk("T4 写回读一致 (0xC0DE1234)", rd == 32'hC0DE_1234);
        mgmt_write(REG_SCRATCH, 32'h5A5A_5A5A);
        mgmt_read (REG_SCRATCH, rd);
        chk("T4 二次写回读一致",          rd == 32'h5A5A_5A5A);

        // ---------------- T2 状态查询（需链路先训练起来）----------------
        $display("[T2] Status query：先训练链路，再读状态");
        train_enable = 1'b1;
        // 等 LTSSM 进 ACTIVE（有超时保护，避免死等）
        begin : wait_active
            int guard = 0;
            while (!(link_active === 1'b1) && guard < 200000) begin
                @(negedge lclk);
                guard++;
            end
        end
        chk("T2 链路已训练到 ACTIVE", link_active === 1'b1);

        mgmt_read(REG_LINK_STATUS, rd);
        $display("      LINK_STATUS = 0x%08h (ltssm=%0d active=%b lanes=%0d repair=%b)",
                 rd, rd[3:0], rd[4], rd[12:5], rd[13]);
        chk("T2 状态寄存器反映 link_active", rd[4]      == link_active);
        chk("T2 有效 lane 数与链路一致",     rd[12:5]   == valid_lanes);
        chk("T2 修复标志与链路一致",         rd[13]     == repair_used);

        // ---------------- T3 错误上报 ----------------
        $display("[T3] Error reporting：读两侧错误计数");
        mgmt_read(REG_ERR_A, rd);
        $display("      ERR_A = 0x%08h (crc_err=%0d nak=%0d retry=%0d)",
                 rd, rd[15:0], rd[31:16], rd[31:16]);
        chk("T3 ERR_A 字段与 a_crc_err 一致",  rd[15:0]  == a_crc_err);
        mgmt_read(REG_ERR_B, rd);
        chk("T3 ERR_B 字段与 b_crc_err 一致",  rd[31:16] == b_crc_err);

        // ---------------- T5 发现握手（sideband）----------------
        $display("[T5] 发现握手：本端发起 DISCOVER → 对端回 ID 响应");
        // sideband 在顶层环回（tx 直接回连到 rx），因此必须先由本端主动触发。
        begin : discover
            bit seen_disc = 1'b0, seen_id = 1'b0;
            // 必须**先启动监视、再触发**：DISCOVER 只持续 1 拍，
            // "先写后监视" 会正好错过它（踩过：ID 响应看到了，DISCOVER 没看到）。
            fork
                begin : trigger
                    repeat (3) @(negedge lclk);
                    mgmt_req_addr  = REG_CTRL;
                    mgmt_req_wdata = 32'h0000_0002;   // bit1 = 发起一次发现（自清）
                    mgmt_req_we    = 1'b1;
                    mgmt_req_valid = 1'b1;
                    @(negedge lclk);
                    mgmt_req_valid = 1'b0;
                end
            join_none

            for (int i = 0; i < 300 && !seen_id; i++) begin
                @(negedge lclk);
                if (mgmt_sb_tx_valid === 1'b1) begin
                    if (mgmt_sb_tx_msg === MGMT_MSG_DISCOVER) seen_disc = 1'b1;
                    if (mgmt_sb_tx_msg === MGMT_MSG_ID)       seen_id   = 1'b1;
                end
            end
            chk("T5 观察到本端发出的 DISCOVER(0xD0)", seen_disc);
            chk("T5 观察到对端回的 ID 响应(0xD1)",     seen_id);
        end

        // ---------------- 汇总 ----------------
        $display("----------------------------------------------------------------");
        if (errors == 0) $display("=========== 管理通道验证全部通过 (ALL PASS) ===========");
        else             $display("=========== 有 %0d 项失败（共 %0d 项）===========", errors, checks);
        $display("  检查项 %0d，失败 %0d", checks, errors);
        $finish;
    end

    // 看门狗
    initial begin
        repeat (400000) @(negedge lclk);
        $display("[tb_mgmt] 超时（看门狗）");
        $fatal(1);
    end

endmodule
