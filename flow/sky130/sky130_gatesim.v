// ============================================================
// Minimal functional models for gate-level simulation
// (11 cell types used by picorv32 netlist, sky130_fd_sc_hd)
// ============================================================
`timescale 1ns/1ps
module sky130_fd_sc_hd__and2_1 (A, B, X); input A, B; output X; assign X = A & B; endmodule
module sky130_fd_sc_hd__or2_1  (A, B, X); input A, B; output X; assign X = A | B; endmodule
module sky130_fd_sc_hd__xor2_1 (A, B, X); input A, B; output X; assign X = A ^ B; endmodule
module sky130_fd_sc_hd__nand2_1(A, B, Y); input A, B; output Y; assign Y = ~(A & B); endmodule
module sky130_fd_sc_hd__nor2_1 (A, B, Y); input A, B; output Y; assign Y = ~(A | B); endmodule
module sky130_fd_sc_hd__and2b_1(A_N, B, X); input A_N, B; output X; assign X = ~A_N & B; endmodule
module sky130_fd_sc_hd__or2b_1 (A, B_N, X); input A, B_N; output X; assign X = A | ~B_N; endmodule
module sky130_fd_sc_hd__inv_1  (A, Y); input A; output Y; assign Y = ~A; endmodule
module sky130_fd_sc_hd__buf_1  (A, X); input A; output X; assign X = A; endmodule
module sky130_fd_sc_hd__mux2_1 (A0, A1, S, X); input A0, A1, S; output X; assign X = S ? A1 : A0; endmodule
module sky130_fd_sc_hd__dfxtp_1(CLK, D, Q); input CLK, D; output reg Q;
  initial Q = 0;
  always @(posedge CLK) Q <= D; endmodule
module sky130_fd_sc_hd__edfxtp_1(CLK, D, DE, Q); input CLK, D, DE; output reg Q;
  initial Q = 0;
  always @(posedge CLK) if (DE) Q <= D; endmodule

// xnor2_1: X = ~(A ^ B)
module sky130_fd_sc_hd__xnor2_1 (A, B, Y);
  input A, B; output Y;
  assign Y = ~(A ^ B);
endmodule

// ============ post-APR cells (ORFS sky130hd) ============
module sky130_fd_sc_hd__lpflow_clkbufkapwr_1 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; inout KAPWR, VGND, VNB, VPWR; output X;
  assign X = A;
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_2 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; inout KAPWR, VGND, VNB, VPWR; output X;
  assign X = A;
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_4 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; inout KAPWR, VGND, VNB, VPWR; output X;
  assign X = A;
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_8 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; inout KAPWR, VGND, VNB, VPWR; output X;
  assign X = A;
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_16 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; inout KAPWR, VGND, VNB, VPWR; output X;
  assign X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_1 (A, X);
  input A; output X; assign X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_2 (A, X);
  input A; output X; assign X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_4 (A, X);
  input A; output X; assign X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_8 (A, X);
  input A; output X; assign X = A;
endmodule
module sky130_fd_sc_hd__clkbuf_16 (A, X);
  input A; output X; assign X = A;
endmodule
// physical-only cells: no logic function
module sky130_fd_sc_hd__tapvpwrvgnd_1 (VGND, VPWR);
  inout VGND, VPWR;
endmodule
module sky130_fd_sc_hd__fill_1 ();
endmodule
module sky130_fd_sc_hd__fill_2 ();
endmodule
module sky130_fd_sc_hd__fill_4 ();
endmodule
module sky130_fd_sc_hd__fill_8 ();
endmodule
module sky130_fd_sc_hd__decap_3 (VGND, VND, VPWR);
  inout VGND, VND, VPWR;
endmodule
module sky130_fd_sc_hd__decap_4 (VGND, VND, VPWR);
  inout VGND, VND, VPWR;
endmodule
module sky130_fd_sc_hd__decap_6 (VGND, VND, VPWR);
  inout VGND, VND, VPWR;
endmodule
module sky130_fd_sc_hd__decap_8 (VGND, VND, VPWR);
  inout VGND, VND, VPWR;
endmodule
module sky130_fd_sc_hd__decap_12 (VGND, VND, VPWR);
  inout VGND, VND, VPWR;
endmodule

// flop drive variants (post-APR)
module sky130_fd_sc_hd__dfxtp_2(CLK, D, Q);
  input CLK, D; output reg Q;
  initial Q = 0;
  always @(posedge CLK) Q <= D;
endmodule
module sky130_fd_sc_hd__dfxtp_4(CLK, D, Q);
  input CLK, D; output reg Q;
  initial Q = 0;
  always @(posedge CLK) Q <= D;
endmodule
