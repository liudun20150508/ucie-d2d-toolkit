// =============================================================================
// ucie_stream_unpack : flit payload -> 协议层字节流（解聚合，16 B/拍）
// -----------------------------------------------------------------------------
// 与 ucie_stream_pack 对称：把一个 64 B 的 flit payload 分 4 拍（每拍最多 16 B）
// 吐给上层协议解析器，并通过 out_taken 接受**字节粒度**的消费回执。
//
// 为什么需要 out_taken：
//   一个数据 beat 在字节流里是 65 B（1 B beat 头 + 64 B 数据），不是 16 的倍数，
//   所以解析器必然会“吃掉半个 UI”。若接口只能整拍消费，解析器就得自己再缓冲，
//   复杂度反而更高——直接用字节粒度流控最干净。
//
// 为什么不在这里剥 padding：
//   padding 是 0x00（TXN_IDLE），只会出现在**事务边界**；而数据 beat 内部完全
//   可能出现 0x00 字节。所以“见到 0x00 就丢弃”只有放在事务边界（解析器里）
//   才是正确的，本模块只负责把 64 B 原样吐出。
// =============================================================================
`ifndef UCIE_STREAM_UNPACK_SV
`define UCIE_STREAM_UNPACK_SV

module ucie_stream_unpack (
    input  logic clk,
    input  logic rst_n,

    // 上游：来自 ucie_dll 的 l_rx_* 事务口
    input  logic       in_valid,
    output logic       in_ready,
    input  logic [ucie_pkg::FLIT_PAYLOAD_BYTES*8-1:0] in_payload,

    // 下游：字节流给协议解析器（16 B/拍，字节粒度消费）
    output logic         out_valid,
    output logic [ucie_axi_pkg::STREAM_W_BITS-1:0] out_data,
    output logic [4:0]   out_bytes,      // 本拍可提供字节数（1..16）
    input  logic [4:0]   out_taken,      // 下游实际消费字节数（0..16）

    // 观测
    output logic         flit_taken,
    output logic [15:0]  st_flits,
    output logic [15:0]  st_bytes
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    logic [FLIT_PAYLOAD_BYTES*8-1:0] sh;
    logic [6:0]                      left;      // 剩余未消费字节数 0..64
    logic [15:0]                     flit_q, byte_q;

    assign in_ready   = (left == 7'd0);
    assign out_valid  = (left != 7'd0);
    assign out_data   = sh[STREAM_W_BITS-1:0];
    assign out_bytes  = (left > STREAM_W_BYTES[6:0]) ? STREAM_W_BYTES[4:0] : left[4:0];
    assign flit_taken = in_valid && in_ready;

    wire consume = out_valid && (out_taken != 5'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh     <= '0;
            left   <= 7'd0;
            flit_q <= 16'd0;
            byte_q <= 16'd0;
        end else if (in_ready && in_valid) begin
            sh     <= in_payload;
            left   <= FLIT_PAYLOAD_BYTES[6:0];
            flit_q <= flit_q + 16'd1;
        end else if (consume) begin
            sh     <= sh >> (out_taken * 8);
            left   <= left - {2'b0, out_taken};
            byte_q <= byte_q + {11'b0, out_taken};
        end
    end

    assign st_flits = flit_q;
    assign st_bytes = byte_q;

`ifndef SYNTHESIS
    // 同前：disable iff 的复位被判为同步使用，局部抑制 SYNCASYNCNET
    // verilator lint_off SYNCASYNCNET
    a_left: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid) |-> (left != 7'd0));
    a_taken: assert property (@(posedge clk) disable iff (!rst_n)
        (out_taken <= out_bytes));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_STREAM_UNPACK_SV
