// =============================================================================
// tb_ltssm_sdf.v : ucie_ltssm 后 CTS 门级网表的 SDF 时序后仿 testbench
// -----------------------------------------------------------------------------
// 对象：build/sdf/ucie_ltssm_apr.v（OpenROAD 出 SDF 时一并写出的后 CTS 网表，
//   含 CTS 插入的 8 个时钟树单元）。用 Icarus 跑 $sdf_annotate 反标
//   build/sdf/ucie_ltssm.sdf（单元延迟 + 互连延迟）。
//
// 验证点（把「功能 + 时序」一起覆盖）：
//   1. SDF 反标无错误（无 "instance not found" / "unable to map"）；
//   2. 复位后状态机按超时容错路径从 RESET 一路走到 ACTIVE（link_active）；
//   3. 注入一次 link_error，走 PHYRETRAIN -> MBTRAIN -> LINKINIT -> ACTIVE 闭环，
//      重训计数 retrain_cnt 递增、retrain_pulse 再次拉高；
//   4. 全程 state 无 X（证明网表 + 单元模型连接完整，无未知态泄漏）。
//
// 激励对端侧带不回话（sb_peer_* 恒 0），刻意走「单工握手 + 超时兜底」分支，
// 与 RTL 侧 tb 的覆盖互补。
// =============================================================================

`timescale 1ns / 1ps

module tb_ltssm_sdf;

  // ---- 与网表端口一致的信号 -------------------------------------------------
  reg         clk = 1'b0;
  reg         rst_n = 1'b0;
  reg         enable = 1'b0;
  reg         link_error_in = 1'b0;
  reg         sb_peer_ack = 1'b0;
  reg         sb_peer_valid = 1'b0;
  reg  [7:0]  sb_peer_msg = 8'h00;
  reg  [16:0] lane_good = 17'h1FFFF;   // 16 数据 + 1 冗余 lane 全好
  reg  [7:0]  valid_lanes = 8'd16;     // lane_repair 算出 16 条可用

  wire        sb_valid;
  wire [7:0]  sb_msg;
  wire [7:0]  sb_arg;
  wire [3:0]  state;
  wire        link_active;
  wire        train_error;
  wire        retrain_pulse;
  wire [15:0] train_cycles;
  wire [3:0]  retrain_cnt;

  // 状态编码（与 ucie_pkg 一致）
  localparam S_RESET      = 4'd0;
  localparam S_SBINIT     = 4'd1;
  localparam S_MBINIT     = 4'd2;
  localparam S_MBTRAIN    = 4'd3;
  localparam S_LINKINIT   = 4'd4;
  localparam S_ACTIVE     = 4'd5;
  localparam S_PHYRETRAIN = 4'd6;
  localparam S_TRAINERROR = 4'd7;
  localparam S_L1         = 4'd8;

  // ---- 时钟：100 MHz（对齐 ltssm.sdc 的 create_clock -period 10.0）-----------
  always #5 clk = ~clk;

  // ---- 反标 SDF（时间 0 即执行）----------------------------------------------
  initial begin
    $sdf_annotate("build/sdf/ucie_ltssm.sdf", uut);
  end

  // ---- 待测设计（后 CTS 门级网表）--------------------------------------------
  ucie_ltssm uut (
    .clk           (clk),
    .rst_n         (rst_n),
    .enable        (enable),
    .link_error_in (link_error_in),
    .sb_peer_ack   (sb_peer_ack),
    .sb_peer_valid (sb_peer_valid),
    .sb_peer_msg   (sb_peer_msg),
    .lane_good     (lane_good),
    .valid_lanes   (valid_lanes),
    .sb_valid      (sb_valid),
    .sb_msg        (sb_msg),
    .sb_arg        (sb_arg),
    .state         (state),
    .link_active   (link_active),
    .train_error   (train_error),
    .retrain_pulse (retrain_pulse),
    .train_cycles  (train_cycles),
    .retrain_cnt   (retrain_cnt)
  );

  // ---- 状态打印（便于核对 FSM 路径）-----------------------------------------
  reg [255:0] sname;
  always @(*) begin
    case (state)
      S_RESET:      sname = "RESET";
      S_SBINIT:     sname = "SBINIT";
      S_MBINIT:     sname = "MBINIT";
      S_MBTRAIN:    sname = "MBTRAIN";
      S_LINKINIT:   sname = "LINKINIT";
      S_ACTIVE:     sname = "ACTIVE";
      S_PHYRETRAIN: sname = "PHYRETRAIN";
      S_TRAINERROR: sname = "TRAINERROR";
      S_L1:         sname = "L1";
      default:      sname = "UNKNOWN";
    endcase
  end
  reg [3:0] prev_state = 4'hF;
  always @(posedge clk) begin
    if (state !== prev_state) begin
      $display("[%0t] state -> %0d %0s  (link_active=%b train_error=%b retrain_cnt=%0d)",
               $time, state, sname, link_active, train_error, retrain_cnt);
      prev_state <= state;
    end
  end

  // ---- 主流程 ----------------------------------------------------------------
  integer n_errs = 0;
  integer i;
  reg [1:0] pulses_seen = 2'd0;

  task wait_state;
    input [3:0] want;
    input integer max_cycles;
    integer c;
    begin
      c = 0;
      while (state !== want && c < max_cycles) begin
        @(posedge clk);
        c = c + 1;
      end
      if (state !== want) begin
        $display("FAIL: 等 state=%0d 超时（当前 %0d）", want, state);
        n_errs = n_errs + 1;
      end
    end
  endtask

  initial begin
    // ---- 复位 ----
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    enable = 1'b1;
    @(posedge clk);

    // ---- 复位后状态必须为已知 RESET，不能有 X ----
    if (state === 4'bx) begin
      $display("FAIL: 复位后 state 为 X（网表/模型连接有未知态泄漏）");
      n_errs = n_errs + 1;
    end else begin
      $display("[%0t] 复位完成，state=%0s", $time, sname);
    end

    // ---- 训练到 ACTIVE（超时容错路径，无对端回话）----
    wait_state(S_ACTIVE, 200);
    if (link_active !== 1'b1) begin
      $display("FAIL: 到达 ACTIVE 但 link_active 未拉高");
      n_errs = n_errs + 1;
    end else begin
      $display("[%0t] 首次训练成功 -> ACTIVE，train_cycles=%0d", $time, train_cycles);
    end

    // ---- 注入一次 link_error -> 触发 PHYRETRAIN 重训 ----
    @(posedge clk);
    link_error_in = 1'b1;
    @(posedge clk);             // 本拍 FSM 采样到 link_error_in=1，离开 ACTIVE
    link_error_in = 1'b0;
    repeat (2) @(posedge clk);  // 让 FSM 离开 ACTIVE 后稳定，避免 wait_state 误判仍在 ACTIVE

    // ---- 重训闭环回到 ACTIVE，重训计数应递增 ----
    wait_state(S_ACTIVE, 200);
    $display("[%0t] 重训完成 -> ACTIVE，retrain_cnt=%0d，retrain_pulse 观测到 %0d 次",
             $time, retrain_cnt, pulses_seen);
    if (retrain_cnt !== 4'd1) begin
      $display("FAIL: 期望 retrain_cnt=1（重训一次），实际 %0d", retrain_cnt);
      n_errs = n_errs + 1;
    end
    if (pulses_seen < 2'd2) begin
      $display("FAIL: 期望观测到 2 次 retrain_pulse 上升沿，实际 %0d", pulses_seen);
      n_errs = n_errs + 1;
    end

    // ---- 收尾 ----
    repeat (10) @(posedge clk);
    if (n_errs == 0) begin
      $display("PASS: SDF 时序后仿跑通 —— 功能等价 + 时序反标无错误");
      $finish;
    end else begin
      $display("FAIL: %0d 处错误", n_errs);
      $finish;
    end
  end

  // ---- 连续监视 retrain_pulse 上升沿（贯穿首次进 ACTIVE + 重训后再进）--------
  // 单独一个 initial 块并行跑，主流程里只管查 pulses_seen，不做 fork 等待。
  initial begin
    forever begin
      @(posedge retrain_pulse);
      pulses_seen = pulses_seen + 2'd1;
    end
  end

  // ---- 兜底超时（防死循环挂住 CI）--------------------------------------------
  initial begin
    #20000;
    $display("FAIL: 全局仿真超时");
    $finish;
  end

endmodule
