// ============================================================
// Techmap: yosys internal gates -> sky130_fd_sc_hd standard cells
// ============================================================
module $_AND_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__and2_1 _TECHMAP_REPLACE_ (.A(A), .B(B), .X(Y));
endmodule

module $_OR_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__or2_1 _TECHMAP_REPLACE_ (.A(A), .B(B), .X(Y));
endmodule

module $_XOR_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__xor2_1 _TECHMAP_REPLACE_ (.A(A), .B(B), .X(Y));
endmodule

module $_XNOR_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__xnor2_1 _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule

module $_NAND_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__nand2_1 _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule

module $_NOR_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__nor2_1 _TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule

module $_ANDNOT_ (A, B, Y);
  input A, B; output Y;
  // and2b_1: X = ~A_N & B  ->  implement Y = A & ~B with A_N=B, B=A
  sky130_fd_sc_hd__and2b_1 _TECHMAP_REPLACE_ (.A_N(B), .B(A), .X(Y));
endmodule

module $_ORNOT_ (A, B, Y);
  input A, B; output Y;
  sky130_fd_sc_hd__or2b_1 _TECHMAP_REPLACE_ (.A(A), .B_N(B), .X(Y));
endmodule

module $_NOT_ (A, Y);
  input A; output Y;
  sky130_fd_sc_hd__inv_1 _TECHMAP_REPLACE_ (.A(A), .Y(Y));
endmodule

module $_BUF_ (A, Y);
  input A; output Y;
  sky130_fd_sc_hd__buf_1 _TECHMAP_REPLACE_ (.A(A), .X(Y));
endmodule

module $_MUX_ (A, B, S, Y);
  input A, B, S; output Y;
  sky130_fd_sc_hd__mux2_1 _TECHMAP_REPLACE_ (.A0(A), .A1(B), .S(S), .X(Y));
endmodule
