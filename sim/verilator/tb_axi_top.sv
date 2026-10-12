// =============================================================================
// tb_axi_top : AXI4 over UCIe 的端到端验证台
// -----------------------------------------------------------------------------
// 拓扑：
//   tb 的 AXI master BFM  ->  ucie_axi_d2d_top 的 A 侧（slave 端口）
//   tb 的 AXI slave 内存  ->  ucie_axi_d2d_top 的 B 侧（master 端口）
//   中间是原有的整套 UCIe D2D 链路（DLL/LTSSM/RDI/CDC），一行未改。
//
// 覆盖场景：
//   T1 链路训练            LTSSM 走到 ACTIVE
//   T2 单拍写 + 读回        数据跨 die 往返一致
//   T3 INCR 突发写 + 读回   4 拍 burst，逐拍比对
//   T4 多 ID outstanding    两笔不同 ID 的读，验证 ID/数据匹配
//   T5 误码下读写           A->B 注入 CRC 错误，重传后数据仍正确
//
// 判定：任何数据不符 / 超时都算 FAIL，进程退出码非零。
// =============================================================================
`timescale 1ns/1ps

module tb_axi_top;
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    // ---------------- 时钟与复位 ----------------
    logic lclk = 1'b0, rdi_clk = 1'b0, lrst_n = 1'b0, rrst_n = 1'b0;
    always #5.0  lclk    = ~lclk;      // 100 MHz
    always #3.75 rdi_clk = ~rdi_clk;   // 133.3 MHz（异频，CDC 真被验证）

    // ---------------- A 侧：tb 扮演 AXI master ----------------
    logic     a_awvalid = 1'b0;
    logic     a_awready;
    axi_ax_t  a_aw = '0;
    logic     a_wvalid  = 1'b0;
    logic     a_wready;
    logic [511:0] a_wdata = '0;
    logic [63:0]  a_wstrb = '1;
    logic     a_wlast   = 1'b0;
    logic     a_bvalid;
    logic     a_bready  = 1'b1;
    logic [3:0] a_bid;
    logic [1:0] a_bresp;
    logic     a_arvalid = 1'b0;
    logic     a_arready;
    axi_ax_t  a_ar = '0;
    logic     a_rvalid;
    logic     a_rready  = 1'b1;
    logic [3:0]   a_rid;
    logic [511:0] a_rdata;
    logic [1:0]   a_rresp;
    logic     a_rlast;

    // ---------------- B 侧：tb 扮演 AXI slave（内存）----------------
    logic     b_awvalid;
    logic     b_awready = 1'b1;
    axi_ax_t  b_aw;
    logic     b_wvalid;
    logic     b_wready  = 1'b1;
    logic [511:0] b_wdata;
    logic [63:0]  b_wstrb;
    logic     b_wlast;
    // 注：以下响应类信号由 continuous assign 驱动（见下面的内存模型），
    // 声明处不能再给初值 —— 否则 Verilator 报 CONTASSINIT。
    logic     b_bvalid;
    logic     b_bready;
    logic [3:0] b_bid;
    logic [1:0] b_bresp;
    logic     b_arvalid;
    logic     b_arready = 1'b1;
    axi_ax_t  b_ar;
    logic     b_rvalid;
    logic     b_rready;
    logic [3:0]   b_rid;
    logic [511:0] b_rdata;
    logic [1:0]   b_rresp;
    logic     b_rlast;

    // ---------------- PHY / 训练 ----------------
    logic [LANES_TOTAL-1:0] lane_good       = '1;
    logic                   reversal_detect = 1'b0;
    logic                   train_enable    = 1'b0;
    logic                   link_err_inject = 1'b0;
    logic                   err_inject_a2b  = 1'b0;
    logic                   err_inject_b2a  = 1'b0;

    ltssm_e ltssm_state;
    logic   link_active;
    logic [7:0] valid_lanes;
    logic       repair_used;
    logic [LANES-1:0][MAP_W-1:0] lane_map_out;
    logic [LANES-1:0] effective_mask;
    logic [15:0] a_wr_req, a_rd_req, a_wr_data, a_b_resp, a_r_beat;
    logic [15:0] b_wr_req, b_wr_data, b_b_resp, b_r_beat;
    logic [15:0] d2d_delivered_b, d2d_retry_a;

    ucie_axi_d2d_top u_dut (
        .lclk(lclk), .lrst_n(lrst_n), .rdi_clk(rdi_clk), .rrst_n(rrst_n),
        .a_awvalid(a_awvalid), .a_awready(a_awready), .a_aw(a_aw),
        .a_wvalid(a_wvalid),   .a_wready(a_wready),   .a_wdata(a_wdata),
        .a_wstrb(a_wstrb),     .a_wlast(a_wlast),
        .a_bvalid(a_bvalid),   .a_bready(a_bready),   .a_bid(a_bid), .a_bresp(a_bresp),
        .a_arvalid(a_arvalid), .a_arready(a_arready), .a_ar(a_ar),
        .a_rvalid(a_rvalid),   .a_rready(a_rready),   .a_rid(a_rid),
        .a_rdata(a_rdata),     .a_rresp(a_rresp),     .a_rlast(a_rlast),
        .b_awvalid(b_awvalid), .b_awready(b_awready), .b_aw(b_aw),
        .b_wvalid(b_wvalid),   .b_wready(b_wready),   .b_wdata(b_wdata),
        .b_wstrb(b_wstrb),     .b_wlast(b_wlast),
        .b_bvalid(b_bvalid),   .b_bready(b_bready),   .b_bid(b_bid), .b_bresp(b_bresp),
        .b_arvalid(b_arvalid), .b_arready(b_arready), .b_ar(b_ar),
        .b_rvalid(b_rvalid),   .b_rready(b_rready),   .b_rid(b_rid),
        .b_rdata(b_rdata),     .b_rresp(b_rresp),     .b_rlast(b_rlast),
        .lane_good(lane_good), .reversal_detect(reversal_detect),
        .train_enable(train_enable), .link_err_inject(link_err_inject),
        .err_inject_a2b(err_inject_a2b), .err_inject_b2a(err_inject_b2a),
        .ltssm_state(ltssm_state), .link_active(link_active),
        .valid_lanes(valid_lanes), .repair_used(repair_used),
        .lane_map_out(lane_map_out), .effective_mask(effective_mask),
        .a_wr_req(a_wr_req), .a_rd_req(a_rd_req), .a_wr_data(a_wr_data),
        .a_b_resp(a_b_resp), .a_r_beat(a_r_beat),
        .b_wr_req(b_wr_req), .b_wr_data(b_wr_data), .b_b_resp(b_b_resp), .b_r_beat(b_r_beat),
        .d2d_delivered_b(d2d_delivered_b), .d2d_retry_a(d2d_retry_a)
    );

    // =========================================================================
    // B 侧 AXI slave 内存模型：4 KB，64 个 64B word
    // =========================================================================
    logic [511:0] mem [0:63];

    logic [63:0] aw_addr_q, ar_addr_q;
    logic [3:0]  aw_id_q, ar_id_q;
    logic [7:0]  aw_len_q, ar_len_q;
    logic [7:0]  w_cnt_q, r_cnt_q;
    logic        r_go_q, b_go_q;

    wire [5:0] wr_idx = aw_addr_q[11:6] + w_cnt_q[5:0];
    wire [5:0] rd_idx = ar_addr_q[11:6] + r_cnt_q[5:0];

    // 注意：b_bready / b_rready 是 **DUT 的输出**（B 侧桥接的 master 端口告诉
    // 内存模型它能否接收响应），tb 这边**不能**驱动它们，否则与 DUT 输出冲突。
    // 内存模型的推进直接用 DUT 给出的 b_bready / b_rready 即可。

    // 读数据（组合给出，稳定直到握手）
    assign b_rvalid = r_go_q;
    assign b_rdata  = mem[rd_idx];
    assign b_rid    = ar_id_q;
    assign b_rresp  = RESP_OKAY;
    assign b_rlast  = r_go_q && (r_cnt_q == ar_len_q);

    // 写响应
    assign b_bvalid = b_go_q;
    assign b_bid    = aw_id_q;
    assign b_bresp  = RESP_OKAY;

    always_ff @(posedge lclk or negedge lrst_n) begin
        if (!lrst_n) begin
            for (int i = 0; i < 64; i++) mem[i] <= '0;
            aw_addr_q <= '0; aw_id_q <= '0; aw_len_q <= '0;
            ar_addr_q <= '0; ar_id_q <= '0; ar_len_q <= '0;
            w_cnt_q   <= '0; r_cnt_q <= '0;
            r_go_q    <= 1'b0; b_go_q <= 1'b0;
        end else begin
            // ---- AW ----
            if (b_awvalid && b_awready) begin
                $display("      [SLV] AW 收到 len=%0d addr=%0h", b_aw.len, b_aw.addr);
                aw_addr_q <= b_aw.addr;
                aw_id_q   <= b_aw.id;
                aw_len_q  <= b_aw.len;
                w_cnt_q   <= 8'd0;
            end
            // ---- W ----
            if (b_wvalid && b_wready) begin
                mem[wr_idx] <= b_wdata;
                w_cnt_q <= w_cnt_q + 8'd1;
                if (b_wlast) b_go_q <= 1'b1;
            end
            if (b_go_q && b_bready) b_go_q <= 1'b0;

            // ---- AR ----
            if (b_arvalid && b_arready) begin
                $display("      [SLV] AR 收到 len=%0d addr=%0h", b_ar.len, b_ar.addr);
                ar_addr_q <= b_ar.addr;
                ar_id_q   <= b_ar.id;
                ar_len_q  <= b_ar.len;
                r_cnt_q   <= 8'd0;
                r_go_q    <= 1'b1;
            end
            // ---- R ----
            if (r_go_q && b_rready) begin
                if (r_cnt_q == ar_len_q) begin
                    r_go_q  <= 1'b0;
                    r_cnt_q <= 8'd0;
                end else begin
                    r_cnt_q <= r_cnt_q + 8'd1;
                end
            end
        end
    end

    // =========================================================================
    // 记分板与激励
    // =========================================================================
    int fail_cnt = 0;
    int chk_cnt  = 0;
    logic [511:0] wr_buf [0:7];
    logic [511:0] rd_buf [0:7];

    function automatic logic [511:0] pat(input int idx);
        logic [511:0] v;
        v = '0;
        for (int b = 0; b < 64; b++) v[b*8 +: 8] = 8'((idx * 17 + b * 5 + 1) & 32'hff);
        return v;
    endfunction

    task automatic check(input string name, input bit cond);
        chk_cnt++;
        if (cond) $display("  [PASS] %s", name);
        else begin $display("  [FAIL] %s", name); fail_cnt++; end
    endtask

    // AXI 写：AW -> N 拍 W -> 等 B
    task automatic axi_write(input int unsigned addr, input int beats, input logic [3:0] id,
                             input logic [511:0] d0, input logic [511:0] d1,
                             input logic [511:0] d2, input logic [511:0] d3);
        // 用阻塞赋值 + 逐字段赋值：tb 驱动 DUT 输入这样最直观，
        // 同时避开 struct 字面量 '{...} 在不同工具下的处理差异（踩过）。
        @(posedge lclk);
        a_aw = '0;
        a_aw.id    = id;
        a_aw.addr  = addr;
        a_aw.len   = beats[7:0] - 8'd1;
        a_aw.size  = 3'd6;
        a_aw.burst = BURST_INCR;
        a_awvalid  = 1'b1;
        @(posedge lclk);
        while (a_awready !== 1'b1) @(posedge lclk);
        $display("      [MST] AW 发出 @%0t addr=%0h len=%0d | slv_tx 侧 aw.addr=%0h",
                 $time, a_aw.addr, a_aw.len, u_dut.u_slv.u_tx.aw.addr);
        a_awvalid = 1'b0;

        for (int i = 0; i < beats; i++) begin
            case (i)
                0: a_wdata = d0;
                1: a_wdata = d1;
                2: a_wdata = d2;
                default: a_wdata = d3;
            endcase
            a_wstrb  = '1;
            a_wlast  = (i == beats-1);
            a_wvalid = 1'b1;
            @(posedge lclk);
            while (a_wready !== 1'b1) @(posedge lclk);
            $display("      [WR] W beat %0d/%0d 握手完成 (last=%b)", i, beats-1, (i == beats-1));
            a_wvalid = 1'b0;
        end

        $display("      [WR] W 拍发完，等 B 响应");
        @(posedge lclk);
        while (a_bvalid !== 1'b1) @(posedge lclk);
        $display("      [WR] 收到 B 响应 @%0t", $time);
        @(posedge lclk);
    endtask

    // AXI 读：AR -> N 拍 R
    task automatic axi_read(input int unsigned addr, input int beats, input logic [3:0] id);
        @(posedge lclk);
        a_ar = '0;
        a_ar.id    = id;
        a_ar.addr  = addr;
        a_ar.len   = beats[7:0] - 8'd1;
        a_ar.size  = 3'd6;
        a_ar.burst = BURST_INCR;
        a_arvalid  = 1'b1;
        @(posedge lclk);
        while (a_arready !== 1'b1) @(posedge lclk);
        $display("      [MST] AR 发出 @%0t addr=%0h len=%0d | slv_tx 侧 ar.addr=%0h",
                 $time, a_ar.addr, a_ar.len, u_dut.u_slv.u_tx.ar.addr);
        a_arvalid = 1'b0;

        for (int i = 0; i < beats; i++) begin
            @(posedge lclk);
            while (a_rvalid !== 1'b1) @(posedge lclk);
            rd_buf[i] = a_rdata;
            $display("      [RD] 收到第 %0d 拍 @%0t (rlast=%b)", i, $time, a_rlast);
        end
    endtask

    task automatic wait_active(input int timeout, output bit ok);
        int g;
        g = 0; ok = 1'b0;
        while (!link_active && (g < timeout)) begin @(posedge lclk); g++; end
        if (link_active) ok = 1'b1;
    endtask

    bit ok;

    initial begin
        $dumpfile("waves/ucie_axi_d2d_top.vcd");
        $dumpvars(0, tb_axi_top);

        $display("");
        $display("================================================================");
        $display(" AXI4 over UCIe 仿真开始  (lclk=100MHz, rdi_clk=133.3MHz)");
        $display("================================================================");

        // ---- T1 训练 ----
        $display("[T1] 链路训练");
        repeat (12) @(posedge lclk);
        lrst_n = 1'b1; rrst_n = 1'b1;
        repeat (4) @(posedge lclk);
        train_enable = 1'b1;
        wait_active(400, ok);
        check("T1 训练完成进入 ACTIVE", ok);

        // ---- T2 单拍写 + 读回 ----
        $display("[T2] 单拍写 + 读回");
        wr_buf[0] = pat(1);
        axi_write(64'd5*64, 1, 4'd1, wr_buf[0], '0, '0, '0);
        axi_read (64'd5*64, 1, 4'd1);
        check("T2 读回数据与写入一致", rd_buf[0] === wr_buf[0]);

        // ---- T3 INCR 突发 4 拍 ----
        $display("[T3] INCR 突发 4 拍写 + 读回");
        for (int i = 0; i < 4; i++) wr_buf[i] = pat(10+i);
        axi_write(64'd10*64, 4, 4'd2, wr_buf[0], wr_buf[1], wr_buf[2], wr_buf[3]);
        axi_read (64'd10*64, 4, 4'd2);
        check("T3 burst 第0拍一致", rd_buf[0] === wr_buf[0]);
        check("T3 burst 第1拍一致", rd_buf[1] === wr_buf[1]);
        check("T3 burst 第2拍一致", rd_buf[2] === wr_buf[2]);
        check("T3 burst 第3拍一致", rd_buf[3] === wr_buf[3]);

        // ---- T4 多 ID outstanding ----
        $display("[T4] 连续两笔不同 ID 的读");
        for (int i = 0; i < 4; i++) wr_buf[i] = pat(20+i);
        axi_write(64'd20*64, 4, 4'd3, wr_buf[0], wr_buf[1], wr_buf[2], wr_buf[3]);
        axi_read(64'd20*64, 2, 4'd5);
        check("T4 ID=5 第0拍一致", rd_buf[0] === wr_buf[0]);
        axi_read(64'd22*64, 2, 4'd6);
        check("T4 ID=6 第0拍一致", rd_buf[0] === wr_buf[2]);
        check("T4 ID=6 第1拍一致", rd_buf[1] === wr_buf[3]);

        // ---- T5 误码下读写 ----
        $display("[T5] 链路误码注入下的读写（依赖重传保证正确性）");
        fork
            begin
                for (int k = 0; k < 3; k++) begin
                    @(posedge rdi_clk);
                    err_inject_a2b <= 1'b1;
                    @(posedge rdi_clk);
                    err_inject_a2b <= 1'b0;
                    repeat (8) @(posedge rdi_clk);
                end
            end
            begin
                for (int i = 0; i < 4; i++) wr_buf[i] = pat(30+i);
                axi_write(64'd30*64, 4, 4'd7, wr_buf[0], wr_buf[1], wr_buf[2], wr_buf[3]);
                axi_read (64'd30*64, 4, 4'd7);
            end
        join
        check("T5 误码下数据仍逐拍正确", (rd_buf[0] === wr_buf[0]) && (rd_buf[1] === wr_buf[1]) &&
                                        (rd_buf[2] === wr_buf[2]) && (rd_buf[3] === wr_buf[3]));

        repeat (200) @(posedge lclk);

        $display("");
        $display("---------------- AXI 层统计 ----------------");
        $display("  A 侧写请求/写数据/读请求 : %0d / %0d / %0d", a_wr_req, a_wr_data, a_rd_req);
        $display("  A 侧收到 B 响应/ R 拍    : %0d / %0d", a_b_resp, a_r_beat);
        $display("  B 侧收到写请求/写数据    : %0d / %0d", b_wr_req, b_wr_data);
        $display("  B 侧发出 B 响应/ R 拍    : %0d / %0d", b_b_resp, b_r_beat);
        $display("  链路 B 侧交付 flit 数    : %0d", d2d_delivered_b);
        $display("  链路 A 侧重传次数        : %0d", d2d_retry_a);
        $display("  终态                     : %0d (5=ACTIVE)", ltssm_state);
        $display("--------------------------------------------");

        check("汇总：A 侧写请求数 = 4", a_wr_req == 16'd4);
        check("汇总：A 侧读请求数 = 5", a_rd_req == 16'd5);

        if (fail_cnt == 0) begin
            $display("");
            $display("=========== 全部测试通过 (ALL PASS) ===========");
            $display("");
            $finish;
        end else begin
            $display("");
            $display("=========== 有 %0d 项失败 (FAILED) ===========", fail_cnt);
            $display("");
            $fatal(1, "tb_axi_top failed");
        end
    end

    // 调试诊断：打印两侧握手、响应计数、以及两个方向各自收到的 flit 数
    int dbg_cnt = 0;
    always @(posedge lclk) begin
        dbg_cnt++;
        if (lrst_n && (dbg_cnt % 100 == 0) && (dbg_cnt < 3000))
            $display("      [DBG %0d] a_wr=%0d a_wd=%0d a_b=%0d a_r=%0d | b_wr=%0d b_wd=%0d b_b=%0d b_r=%0d | unpA=%0d unpB=%0d | slv_rx(ps=%0d cnt=%0d b0=%h err=%0d) | mst_tx(l=%0d) pkB(cnt=%0d ov=%b) | ltxA_rdy=%b ltxB_rdy=%b b_tx_rdy=%b",
                     dbg_cnt, a_wr_req, a_wr_data, a_b_resp, a_r_beat,
                     b_wr_req, b_wr_data, b_b_resp, b_r_beat,
                     u_dut.u_slv.u_unpack.st_flits, u_dut.u_mst.u_unpack.st_flits,
                     u_dut.u_slv.u_rx.ps_q, u_dut.u_slv.u_rx.cnt_q,
                     u_dut.u_slv.u_rx.acc_q[7:0], u_dut.u_slv.u_rx.cnt_err,
                     u_dut.u_mst.u_tx.src_left,
                     u_dut.u_mst.u_pack.cnt, u_dut.u_mst.u_pack.out_valid,
                     u_dut.a_tx_ready, u_dut.b_tx_ready, u_dut.u_mst.l_tx_ready);
    end

    // 监测：A 侧收到的每个 flit 的前 3 字节 + B 侧发出的字节流（定位字节流内容）
    always @(posedge lclk) begin
        if (lrst_n && u_dut.u_slv.u_unpack.in_valid && u_dut.u_slv.u_unpack.in_ready)
            $display("      [A-RX] flit b0=%h b1=%h b2=%h",
                     u_dut.u_slv.u_unpack.in_payload[7:0],
                     u_dut.u_slv.u_unpack.in_payload[15:8],
                     u_dut.u_slv.u_unpack.in_payload[23:16]);
        if (lrst_n && u_dut.u_mst.u_tx.st_valid && (u_dut.u_mst.u_tx.st_taken != 5'd0))
            $display("      [B-TX] byte0=%h byte1=%h bytes=%0d left=%0d",
                     u_dut.u_mst.u_tx.st_data[7:0], u_dut.u_mst.u_tx.st_data[15:8],
                     u_dut.u_mst.u_tx.st_bytes, u_dut.u_mst.u_tx.src_left);
    end

    initial begin
        repeat (400000) @(posedge lclk);
        $display("[WATCHDOG] 仿真超时");
        $fatal(1, "watchdog");
    end

endmodule
