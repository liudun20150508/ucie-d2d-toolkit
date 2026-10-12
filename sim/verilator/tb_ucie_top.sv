// =============================================================================
// tb_ucie_top : ucie-d2d-demo 自检测试台（SystemVerilog，Verilator 可直接跑）
// -----------------------------------------------------------------------------
// 覆盖 5 组场景，全部对应需求 里的能力点：
//   T1 链路训练      LTSSM 走完 SBINIT→MBINIT→MBTRAIN→LINKINIT→ACTIVE
//   T2 端到端通路    A 侧发 64B 事务，B 侧逐字节比对（背靠背打满）
//   T3 误码重传      注入 CRC 错误 -> NAK -> 重传 -> 数据仍 100% 正确
//   T4 lane 修复     打坏 1~2 条物理 lane -> 冗余 lane 顶替 -> 不丢数据
//   T5 重训练        链路层上报错误 -> PHYRETRAIN -> 回到 ACTIVE
//
// 两个时钟刻意做成异频异步（100MHz / 133.3MHz），让 CDC 真的被验证到。
// 判定标准：任何 mismatch / 丢包 / 训练超时都算 FAIL，退出码非零。
// =============================================================================
`timescale 1ns/1ps

module tb_ucie_top;
    import ucie_pkg::*;

    // ---------------- 时钟与复位 ----------------
    logic lclk = 1'b0;
    logic rdi_clk = 1'b0;
    logic lrst_n = 1'b0;
    logic rrst_n = 1'b0;

    always #5.0   lclk    = ~lclk;      // 100.0 MHz 本地域
    always #3.75  rdi_clk = ~rdi_clk;   // 133.3 MHz 链路域（异频，验证 CDC）

    // ---------------- DUT 接口 ----------------
    logic         a_tx_valid = 1'b0;
    logic         a_tx_ready;
    logic [511:0] a_tx_data  = '0;
    logic         a_rx_valid;
    logic         a_rx_ready = 1'b1;
    logic [511:0] a_rx_data;

    logic         b_tx_valid = 1'b0;
    logic         b_tx_ready;
    logic [511:0] b_tx_data  = '0;
    logic         b_rx_valid;
    logic         b_rx_ready = 1'b1;
    logic [511:0] b_rx_data;

    logic [LANES_TOTAL-1:0] lane_good       = '1;   // 初始：17 条物理 lane 全好
    logic                   reversal_detect = 1'b0;
    logic                   train_enable    = 1'b0;
    logic                   link_err_inject = 1'b0;
    logic                   err_inject_a2b  = 1'b0;
    logic                   err_inject_b2a  = 1'b0;

    ltssm_e             ltssm_state;
    logic               link_active;
    logic [7:0]         valid_lanes;
    logic               repair_used;
    logic [LANES-1:0]   effective_mask;
    logic [LANES-1:0][MAP_W-1:0] lane_map_out;
    logic [15:0]        a_delivered, a_crc_err, a_nak_sent, a_retry;
    logic [15:0]        b_delivered, b_crc_err, b_nak_sent;
    logic [7:0]         a_credit_left, a_inflight;

    ucie_d2d_top u_dut (
        .lclk            (lclk),
        .lrst_n          (lrst_n),
        .rdi_clk         (rdi_clk),
        .rrst_n          (rrst_n),
        .a_tx_valid      (a_tx_valid),
        .a_tx_ready      (a_tx_ready),
        .a_tx_data       (a_tx_data),
        .a_rx_valid      (a_rx_valid),
        .a_rx_ready      (a_rx_ready),
        .a_rx_data       (a_rx_data),
        .b_tx_valid      (b_tx_valid),
        .b_tx_ready      (b_tx_ready),
        .b_tx_data       (b_tx_data),
        .b_rx_valid      (b_rx_valid),
        .b_rx_ready      (b_rx_ready),
        .b_rx_data       (b_rx_data),
        .lane_good       (lane_good),
        .reversal_detect (reversal_detect),
        .train_enable    (train_enable),
        .link_err_inject (link_err_inject),
        .err_inject_a2b  (err_inject_a2b),
        .err_inject_b2a  (err_inject_b2a),
        .ltssm_state     (ltssm_state),
        .link_active     (link_active),
        .valid_lanes     (valid_lanes),
        .repair_used     (repair_used),
        .effective_mask  (effective_mask),
        .lane_map_out    (lane_map_out),
        .a_delivered     (a_delivered),
        .a_crc_err       (a_crc_err),
        .a_nak_sent      (a_nak_sent),
        .a_retry         (a_retry),
        .b_delivered     (b_delivered),
        .b_crc_err       (b_crc_err),
        .b_nak_sent      (b_nak_sent),
        .a_credit_left   (a_credit_left),
        .a_inflight      (a_inflight)
    );

    // ---------------- 计分板 ----------------
    int sent_cnt    = 0;
    int recv_cnt    = 0;
    int mismatch    = 0;
    int fail_cnt    = 0;
    int t_cycles    = 0;

    // 第 idx 笔事务的确定性载荷：逐字节铺开，方便定位错在哪一字节
    function automatic logic [511:0] gen_payload(input int idx);
        logic [511:0] v;
        v = '0;
        for (int b = 0; b < 64; b++) begin
            v[b*8 +: 8] = 8'((idx * 31 + b * 7 + 3) & 32'hff);
        end
        return v;
    endfunction

    function automatic string state_name(input ltssm_e s);
        case (s)
            LTS_RESET:      return "RESET";
            LTS_SBINIT:     return "SBINIT";
            LTS_MBINIT:     return "MBINIT";
            LTS_MBTRAIN:    return "MBTRAIN";
            LTS_LINKINIT:   return "LINKINIT";
            LTS_ACTIVE:     return "ACTIVE";
            LTS_PHYRETRAIN: return "PHYRETRAIN";
            LTS_TRAINERROR: return "TRAINERROR";
            LTS_L1:         return "L1";
            default:        return "UNKNOWN";
        endcase
    endfunction

    // 训练状态轨迹（去重打印，便于报告里贴）
    ltssm_e last_state = LTS_RESET;
    always @(posedge lclk) begin
        if (lrst_n && (ltssm_state !== last_state)) begin
            $display("      [LTSSM] %0t ns: %s -> %s", $time, state_name(last_state), state_name(ltssm_state));
            last_state <= ltssm_state;
        end
    end

    // ---------------- B 侧接收监测（逐字节比对）----------------
    always @(posedge lclk) begin
        if (lrst_n && b_rx_valid && b_rx_ready) begin
            logic [511:0] exp;
            exp = gen_payload(recv_cnt);
            if (b_rx_data !== exp) begin
                mismatch++;
                if (mismatch <= 4)
                    $display("      [MISMATCH] flit#%0d got=%h exp=%h", recv_cnt, b_rx_data, exp);
            end
            recv_cnt++;
        end
    end

    // ---------------- 驱动任务 ----------------
    task automatic send_one(input int idx);
        @(posedge lclk);
        a_tx_valid <= 1'b1;
        a_tx_data  <= gen_payload(idx);
        do @(posedge lclk); while (a_tx_ready !== 1'b1);
        a_tx_valid <= 1'b0;
        sent_cnt++;
    endtask

    task automatic send_burst(input int n);
        for (int i = 0; i < n; i++) send_one(sent_cnt);
    endtask

    task automatic wait_cycles(input int n);
        repeat (n) @(posedge lclk);
    endtask

    // 等 B 侧收齐 last 笔（带超时）
    task automatic wait_recv(input int target, input int timeout, output bit ok);
        int guard;
        guard = 0;
        ok = 1'b0;
        while ((recv_cnt < target) && (guard < timeout)) begin
            @(posedge lclk);
            guard++;
        end
        if (recv_cnt >= target) ok = 1'b1;
    endtask

    task automatic wait_active(input int timeout, output bit ok);
        int guard;
        guard = 0;
        ok = 1'b0;
        while (!link_active && (guard < timeout)) begin
            @(posedge lclk);
            guard++;
        end
        if (link_active) ok = 1'b1;
    endtask

    task automatic check(input string name, input bit cond);
        if (cond) begin
            $display("  [PASS] %s", name);
        end else begin
            $display("  [FAIL] %s", name);
            fail_cnt++;
        end
    endtask

    // ---------------- 主流程 ----------------
    bit ok;

    initial begin
        $dumpfile("waves/ucie_d2d_top.vcd");
        $dumpvars(0, tb_ucie_top);

        $display("");
        $display("================================================================");
        $display(" UCIe D2D demo 仿真开始  (lclk=100MHz, rdi_clk=133.3MHz)");
        $display("================================================================");

        // ---- T1: 训练 ----
        $display("[T1] 链路训练（LTSSM）");
        repeat (12) @(posedge lclk);
        lrst_n = 1'b1;
        rrst_n = 1'b1;
        repeat (4) @(posedge lclk);
        train_enable = 1'b1;
        wait_active(400, ok);
        check("T1 训练完成进入 ACTIVE", ok);
        check("T1 可用 lane 数 = 16", valid_lanes == 16);
        check("T1 未动用冗余 lane", repair_used == 1'b0);

        // ---- T2: 端到端数据通路 ----
        $display("[T2] 端到端数据通路（32 笔背靠背事务）");
        send_burst(32);
        wait_recv(32, 4000, ok);
        check("T2 32 笔全部到达 B 侧", ok && (recv_cnt == 32));
        check("T2 载荷逐字节一致", mismatch == 0);
        // 注意：a_delivered 是 A 侧**接收**计数（本 demo 数据是 A->B 单向，
        // B 只回 ACK/NAK 控制 flit），所以要检查 B 侧的交付计数。
        check("T2 B 侧交付计数 = 32", b_delivered == 16'd32);

        // ---- T3: 误码 -> NAK -> 重传 ----
        $display("[T3] 链路误码注入 -> NAK -> 重传");
        begin
            int nak_before, del_before, rc_before;
            nak_before = b_nak_sent;
            del_before = b_delivered;
            rc_before  = recv_cnt;
            for (int k = 0; k < 4; k++) begin
                @(posedge rdi_clk);
                err_inject_a2b <= 1'b1;
                @(posedge rdi_clk);
                err_inject_a2b <= 1'b0;
                repeat (6) @(posedge rdi_clk);
            end
            send_burst(16);
            wait_recv(rc_before + 16, 8000, ok);
            check("T3 误码后 16 笔仍全部正确到达", ok && (recv_cnt == rc_before + 16));
            check("T3 通道仍无字节错配", mismatch == 0);
            check("T3 接收侧确实发出了 NAK", b_nak_sent > nak_before);
            check("T3 接收侧未把坏 flit 交付出去（交付数=好 flit 数）",
                  (b_delivered - del_before) == 16);
        end

        // ---- T4: lane 修复 ----
        $display("[T4] 打坏 1 条物理 lane -> 冗余 lane 顶替");
        lane_good[3] = 1'b0;
        link_err_inject <= 1'b1;
        wait_cycles(6);
        link_err_inject <= 1'b0;
        wait_active(600, ok);
        check("T4 重训后回到 ACTIVE", ok);
        $display("      [T4] lane_good=%h valid_lanes=%0d repair_used=%b effective_mask=%h",
                 lane_good, valid_lanes, repair_used, effective_mask);
        $display("      [T4] lane_map[0]=%0d [13]=%0d [14]=%0d [15]=%0d   (逻辑 lane -> 物理 lane)",
                 lane_map_out[0], lane_map_out[13], lane_map_out[14], lane_map_out[15]);
        check("T4 可用 lane 仍为 16（冗余顶替）", valid_lanes == 16);
        check("T4 已动用冗余 lane", repair_used == 1'b1);
        begin
            int rc_before;
            rc_before = recv_cnt;
            send_burst(16);
            wait_recv(rc_before + 16, 8000, ok);
            check("T4 修复后 16 笔数据仍完整", ok && (mismatch == 0));
        end

        // ---- T4b: 再坏一条 -> 降级运行（15 lane）不丢数据 ----
        $display("[T4b] 再打坏 1 条 lane -> 降级到 15 lane 仍不丢数据");
        lane_good[5] = 1'b0;
        link_err_inject <= 1'b1;
        wait_cycles(6);
        link_err_inject <= 1'b0;
        wait_active(800, ok);
        check("T4b 降级后仍在 ACTIVE", ok);
        check("T4b 可用 lane 降为 15", valid_lanes == 15);
        begin
            int rc_before;
            rc_before = recv_cnt;
            send_burst(16);
            wait_recv(rc_before + 16, 12000, ok);
            check("T4b 降带宽后 16 笔数据仍完整", ok && (mismatch == 0));
        end

        // ---- T5: 链路错误 -> PHYRETRAIN ----
        $display("[T5] 链路层上报错误 -> PHYRETRAIN -> 恢复");
        fork
            begin : wait_retrain
                int guard;
                guard = 0;
                while ((ltssm_state !== LTS_PHYRETRAIN) && (guard < 2000)) begin
                    @(posedge lclk);
                    guard++;
                end
                check("T5 观察到 PHYRETRAIN", ltssm_state === LTS_PHYRETRAIN);
            end
            begin : pulse_err
                link_err_inject <= 1'b1;
                wait_cycles(4);
                link_err_inject <= 1'b0;
            end
        join
        wait_active(1000, ok);
        check("T5 重训后回到 ACTIVE", ok);

        // ---- 收尾统计 ----
        wait_cycles(200);
        $display("");
        $display("---------------- 统计 ----------------");
        $display("  发送事务数        : %0d", sent_cnt);
        $display("  接收事务数        : %0d", recv_cnt);
        $display("  载荷错配          : %0d", mismatch);
        $display("  A 侧交付 / CRC错 : %0d / %0d", a_delivered, a_crc_err);
        $display("  B 侧交付 / CRC错 : %0d / %0d", b_delivered, b_crc_err);
        $display("  B 侧发出 NAK 数   : %0d", b_nak_sent);
        $display("  A 侧重传次数      : %0d", a_retry);
        $display("  最终 lane 数      : %0d (有效掩码 %h)", valid_lanes, effective_mask);
        $display("  终态              : %s", state_name(ltssm_state));
        $display("--------------------------------------");

        check("汇总：收发计数一致", sent_cnt == recv_cnt);
        check("汇总：零字节错配", mismatch == 0);
        check("汇总：终态 ACTIVE", ltssm_state === LTS_ACTIVE);

        if (fail_cnt == 0) begin
            $display("");
            $display("=========== 全部测试通过 (ALL PASS) ===========");
            $display("");
            $finish;
        end else begin
            $display("");
            $display("=========== 有 %0d 项失败 (FAILED) ===========", fail_cnt);
            $display("");
            $fatal(1, "tb_ucie_top failed");
        end
    end

    // 全局看门狗：防止死锁时挂住
    initial begin
        repeat (400000) @(posedge lclk);
        $display("[WATCHDOG] 仿真超时，可能死锁");
        $fatal(1, "watchdog timeout");
    end

endmodule
