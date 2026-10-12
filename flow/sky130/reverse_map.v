// ============================================================
// Reverse techmap: sky130_fd_sc_hd cells -> yosys internal $_*_ cells
// Used for LEC so gate netlist and RTL reference share cell universe
// ============================================================
module sky130_fd_sc_hd__and2_1 (A, B, X);
  input A, B; output X;
  $_AND_ _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(X));
endmodule
module sky130_fd_sc_hd__or2_1 (A, B, X);
  input A, B; output X;
  $_OR_ _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(X));
endmodule
module sky130_fd_sc_hd__xor2_1 (A, B, X);
  input A, B; output X;
  $_XOR_ _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(X));
endmodule
module sky130_fd_sc_hd__xnor2_1 (A, B, Y);
  input A, B; output Y;
  $_XNOR_ _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule
module sky130_fd_sc_hd__nand2_1 (A, B, Y);
  input A, B; output Y;
  $_NAND_ _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule
module sky130_fd_sc_hd__nor2_1 (A, B, Y);
  input A, B; output Y;
  $_NOR_ _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule
// and2b_1: X = ~A_N & B  ==  $_ANDNOT_(A,B): Y = A & ~B  (swap inputs)
module sky130_fd_sc_hd__and2b_1 (A_N, B, X);
  input A_N, B; output X;
  $_ANDNOT_ _TECHMAP_REPLACE_ (.A(B), .B(A_N), .Y(X));
endmodule
// or2b_1: X = A | ~B_N  ==  $_ORNOT_(A,B): Y = A | ~B
module sky130_fd_sc_hd__or2b_1 (A, B_N, X);
  input A, B_N; output X;
  $_ORNOT_ _TECHMAP_REPLACE_ (.A(A), .B(B_N), .Y(X));
endmodule
module sky130_fd_sc_hd__inv_1 (A, Y);
  input A; output Y;
  $_NOT_ _TECHMAP_REPLACE_ (.A(A), .Y(Y));
endmodule
module sky130_fd_sc_hd__buf_1 (A, X);
  input A; output X;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__mux2_1 (A0, A1, S, X);
  input A0, A1, S; output X;
  $_MUX_ _TECHMAP_REPLACE_ (.A(A0), .B(A1), .S(S), .Y(X));
endmodule
module sky130_fd_sc_hd__dfxtp_1 (CLK, D, Q);
  input CLK, D; output Q;
  $_DFF_P_ _TECHMAP_REPLACE_ (.C(CLK), .D(D), .Q(Q));
endmodule
module sky130_fd_sc_hd__edfxtp_1 (CLK, D, DE, Q);
  input CLK, D, DE; output Q;
  $_DFFE_PP_ _TECHMAP_REPLACE_ (.C(CLK), .E(DE), .D(D), .Q(Q));
endmodule

// ============ post-APR additions (ORFS sky130hd flow) ============
// CTS clock buffers (KAPWR family): X = A
module sky130_fd_sc_hd__lpflow_clkbufkapwr_1 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; output X; inout KAPWR, VGND, VNB, VPWR;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_2 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; output X; inout KAPWR, VGND, VNB, VPWR;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_4 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; output X; inout KAPWR, VGND, VNB, VPWR;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_8 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; output X; inout KAPWR, VGND, VNB, VPWR;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__lpflow_clkbufkapwr_16 (A, KAPWR, VGND, VNB, VPWR, X);
  input A; output X; inout KAPWR, VGND, VNB, VPWR;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
// regular clock buffers
module sky130_fd_sc_hd__clkbuf_1 (A, X);
  input A; output X;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__clkbuf_2 (A, X);
  input A; output X;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__clkbuf_4 (A, X);
  input A; output X;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__clkbuf_8 (A, X);
  input A; output X;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__clkbuf_16 (A, X);
  input A; output X;
  $_BUF_ _TECHMAP_REPLACE_ (.A(A), .Y(X));
endmodule
module sky130_fd_sc_hd__dfxtp_2 (CLK, D, Q);
  input CLK, D; output Q;
  $_DFF_P_ _TECHMAP_REPLACE_ (.C(CLK), .D(D), .Q(Q));
endmodule
module sky130_fd_sc_hd__dfxtp_4 (CLK, D, Q);
  input CLK, D; output Q;
  $_DFF_P_ _TECHMAP_REPLACE_ (.C(CLK), .D(D), .Q(Q));
endmodule
