// =============================================================================
// ltssm_sdf_models.v : SKY130 门级单元「功能 + specify 时序弧」合并模型
// -----------------------------------------------------------------------------
// 用途：Icarus `$sdf_annotate` 需要一个**同时含功能与 specify 块**的单元模型。
//   skywater-pdk 把两者拆开：`.functional.v` 只有功能（无 specify）、
//   `.specify.v` 只有 specify 片段（无 module 壳）。所以要自己合并。
//
// 本文件覆盖 ucie_ltssm 后 CTS 门级网表（build/sdf/ucie_ltssm_apr.v）里出现的
// 全部 15 种单元（12 种组合/DFF + conb 常数 + 3 种 CTS 时钟树单元）：
//   and2_1 / and2b_1 / or2_1 / or2b_1 / xor2_1 / xnor2_1 / nand2_1 / nor2_1 /
//   inv_1 / mux2_1 / dfxtp_1 / conb_1 / clkbuf_1 / clkinv_1 / bufinv_16
//
// specify 弧与 OpenSTA 写出的 SDF IOPATH 一一对应（源/目标引脚名一致），这样
// `$sdf_annotate` 才能按名字回填延迟：
//   - 组合单元：一条 (src <edge> dst) 对应一条 (IOPATH src dst)。
//   - xor2/xnor2/mux2：SDF 里是同一条 IOPATH 因状态相关时序**重复出现两次**
//     （如 (IOPATH A X) x2）。这里写**无条件**弧（不写 pdk 的 if 条件），
//     Icarus 对同名 IOPATH 按"后写覆盖"处理 —— 对"跑通 SDF 后仿链"足够。
//   - dfxtp：IOPATH CLK Q + SETUP/HOLD/WIDTH。pdk 的 .specify.v 依赖
//     AWAKE/notifier/CLK_delayed/D_delayed（UDP 电源脚模型），此处简化为自写
//     的 $setup/$hold/$width（与 SDF 的 SETUP/HOLD/WIDTH 严格对应），notifier
//     用普通 reg 即可。
//     ⚠ 边界（实测）：Icarus 13.0 编译 $setup/$hold/$width 时报
//     "Timing checks are not supported" 并忽略它们（-g2005/-g2009/-g2012/
//     -g2005-sv 均如此）——IOPATH/INTERCONNECT 延迟仍正常反标，但 setup/hold
//     违例**不会**被**动态仿真**报告。注意别把两层混为一谈：setup/hold 违例检查
//     的**静态**签核本机 OpenSTA 已做（make sta，报 WNS/TNS/VIOLATED）；这里缺的
//     只是"SDF 反标仿真里的动态 timing check"这一条，属补充手段、非签核必需。
//   - conb_1：常数单元，SDF 里没有它的 CELL 块（无时序），只需功能。
//   - clkinv_1/bufinv_16：CTS 的 dummy load（clkload0/clkload1），输出悬空，
//     但 SDF 里有 (IOPATH A Y)，仍要 declare 对应弧。
//
// 延迟初值全填 0 —— 真实延迟由 SDF 反标覆盖；万一某条弧没匹配上 SDF，
// 也不会引入凭空延迟（0 延迟 = 功能等价门级仿真）。
// =============================================================================

`timescale 1ns / 1ps

// ---- 两输入与门 -----------------------------------------------------------------
module sky130_fd_sc_hd__and2_1 (X, A, B);
  output X;
  input  A, B;
  assign X = A & B;
  specify
    (A +=> X) = (0:0:0, 0:0:0);
    (B +=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 两输入与门（A 反相输入）-----------------------------------------------------
module sky130_fd_sc_hd__and2b_1 (X, A_N, B);
  output X;
  input  A_N, B;
  assign X = ~A_N & B;
  specify
    (A_N -=> X) = (0:0:0, 0:0:0);
    (B   +=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 两输入或门 -----------------------------------------------------------------
module sky130_fd_sc_hd__or2_1 (X, A, B);
  output X;
  input  A, B;
  assign X = A | B;
  specify
    (A +=> X) = (0:0:0, 0:0:0);
    (B +=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 两输入或门（B 反相输入）-----------------------------------------------------
module sky130_fd_sc_hd__or2b_1 (X, A, B_N);
  output X;
  input  A, B_N;
  assign X = A | ~B_N;
  specify
    (A   +=> X) = (0:0:0, 0:0:0);
    (B_N -=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 异或门 ---------------------------------------------------------------------
module sky130_fd_sc_hd__xor2_1 (X, A, B);
  output X;
  input  A, B;
  assign X = A ^ B;
  specify
    (A +=> X) = (0:0:0, 0:0:0);
    (B +=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 同或门 ---------------------------------------------------------------------
module sky130_fd_sc_hd__xnor2_1 (Y, A, B);
  output Y;
  input  A, B;
  assign Y = ~(A ^ B);
  specify
    (A +=> Y) = (0:0:0, 0:0:0);
    (B +=> Y) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 两输入与非门 ---------------------------------------------------------------
module sky130_fd_sc_hd__nand2_1 (Y, A, B);
  output Y;
  input  A, B;
  assign Y = ~(A & B);
  specify
    (A -=> Y) = (0:0:0, 0:0:0);
    (B -=> Y) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 两输入或非门 ---------------------------------------------------------------
module sky130_fd_sc_hd__nor2_1 (Y, A, B);
  output Y;
  input  A, B;
  assign Y = ~(A | B);
  specify
    (A -=> Y) = (0:0:0, 0:0:0);
    (B -=> Y) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 反相器 ---------------------------------------------------------------------
module sky130_fd_sc_hd__inv_1 (Y, A);
  output Y;
  input  A;
  assign Y = ~A;
  specify
    (A -=> Y) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 2:1 多路选择器 -------------------------------------------------------------
module sky130_fd_sc_hd__mux2_1 (X, A0, A1, S);
  output X;
  input  A0, A1, S;
  assign X = S ? A1 : A0;
  specify
    (A0 +=> X) = (0:0:0, 0:0:0);
    (A1 +=> X) = (0:0:0, 0:0:0);
    (S  +=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- D 触发器（正沿）------------------------------------------------------------
module sky130_fd_sc_hd__dfxtp_1 (Q, CLK, D);
  output Q;
  input  CLK, D;
  reg    Q;
  reg    notifier;

  always @(posedge CLK)
    Q <= D;

  initial notifier = 1'b0;

  specify
    (posedge CLK => (Q : CLK)) = (0:0:0, 0:0:0);
    $setup(posedge D,  posedge CLK, 0, notifier);
    $setup(negedge D,  posedge CLK, 0, notifier);
    $hold(posedge CLK, posedge D,  0, notifier);
    $hold(posedge CLK, negedge D,  0, notifier);
    $width(posedge CLK, 0, 0, notifier);
    $width(negedge CLK, 0, 0, notifier);
  endspecify
endmodule

// ---- 常数单元（HI=1, LO=0，无时序）----------------------------------------------
module sky130_fd_sc_hd__conb_1 (HI, LO);
  output HI, LO;
  assign HI = 1'b1;
  assign LO = 1'b0;
endmodule

// ---- 时钟缓冲（CTS 用）----------------------------------------------------------
module sky130_fd_sc_hd__clkbuf_1 (X, A);
  output X;
  input  A;
  assign X = A;
  specify
    (A +=> X) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- 时钟反相（CTS dummy load）--------------------------------------------------
module sky130_fd_sc_hd__clkinv_1 (Y, A);
  output Y;
  input  A;
  assign Y = ~A;
  specify
    (A -=> Y) = (0:0:0, 0:0:0);
  endspecify
endmodule

// ---- buffer+inverter（CTS dummy load，功能上等价反相器）--------------------------
module sky130_fd_sc_hd__bufinv_16 (Y, A);
  output Y;
  input  A;
  assign Y = ~A;
  specify
    (A -=> Y) = (0:0:0, 0:0:0);
  endspecify
endmodule
