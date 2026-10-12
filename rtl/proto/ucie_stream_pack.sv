// =============================================================================
// ucie_stream_pack : 协议层字节流 -> flit payload（聚合打包，16 B/拍）
// -----------------------------------------------------------------------------
// 这是 UCIe「协议层聚合」的实际载体：把上层协议的字节流连续填入 flit 载荷，
// 多个事务可共享同一个 flit，事务与 flit 边界不必对齐。
//
// 带宽对齐（重要，第一版写错过）：
//   链路 RDI 是 16 B/UI @133 MHz ≈ 2.1 GB/s。若字节流接口只做 1 B/拍，
//   协议层就成了 100 MB/s 的瓶颈，会把链路饿死 16 倍。
//   所以这里按 **16 B/拍** 设计，对齐链路宽度。
//
// 接口语义：in_bytes 指出本拍有多少有效字节（1..16），in_taken 回报本拍实际
// 被消费了多少（0..16）——**字节粒度的流控**。这样上游可以连续吐出 65 字节的
// 数据 beat（16+16+16+16+1），不必为了对齐而插入 padding。
//
// 打包策略：
//   * 攒满 64 B 立即发出
//   * 上游连续 IDLE_FLUSH 拍无数据且缓冲非空 -> 发出未满 flit，
//     未用到的字节保持 0（= TXN_IDLE），接收侧在事务边界会跳过
// =============================================================================
`ifndef UCIE_STREAM_PACK_SV
`define UCIE_STREAM_PACK_SV

module ucie_stream_pack #(
    parameter int IDLE_FLUSH = 4,
    parameter int IDLE_W     = 4
)(
    input  logic clk,
    input  logic rst_n,

    // 上游字节流（16 B/拍，字节粒度有效）
    input  logic       in_valid,
    input  logic [ucie_axi_pkg::STREAM_W_BITS-1:0] in_data,
    input  logic [4:0] in_bytes,      // 本拍有效字节数 1..16
    output logic [4:0] in_taken,      // 本拍被消费字节数 0..16

    // 下游：flit payload（64B）事务口，接 ucie_dll 的 l_tx_*
    output logic       out_valid,
    input  logic       out_ready,
    output logic [ucie_pkg::FLIT_PAYLOAD_BYTES*8-1:0] out_payload,

    // 观测
    output logic [15:0] st_flits,
    output logic [15:0] st_bytes
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    // 注：不能叫 buf —— Verilator 内置 gate primitive 关键字（本项目踩过两次）
    logic [STREAM_BYTES*8-1:0] byte_buf;
    logic [6:0]                cnt;        // 0..64
    logic [IDLE_W-1:0]         idle_cnt;
    logic [15:0]               flit_q, byte_q;

    logic [6:0] space7;
    logic [4:0] space, take;

    wire full  = (cnt >= STREAM_BYTES[6:0]);
    wire flush = (cnt != 7'd0) && (idle_cnt >= IDLE_FLUSH[IDLE_W-1:0]);

    assign space7 = 7'd64 - cnt;
    assign space  = (space7 > 7'd16) ? 5'd16 : space7[4:0];
    assign take   = (in_bytes < space) ? in_bytes : space;

    // 输出：满 or 空闲到点
    assign out_valid   = full || flush;
    assign out_payload = byte_buf;          // 未写入的位置本来就是 0（= PAD_BYTE）

    // 输出被占住时不再接收，避免同一拍既写缓冲又发出（否则数据会丢）
    wire in_accept = in_valid && !out_valid;
    assign in_taken = in_accept ? take : 5'd0;

    wire out_fire = out_valid && out_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_buf <= '0;
            cnt      <= 7'd0;
            idle_cnt <= '0;
            flit_q   <= 16'd0;
            byte_q   <= 16'd0;
        end else begin
            if (in_taken != 5'd0) begin
                for (int i = 0; i < 16; i++) begin
                    if (i < in_taken) begin
                        byte_buf[(cnt + i[6:0])*8 +: 8] <= in_data[i*8 +: 8];
                    end
                end
                cnt      <= cnt + {2'b0, in_taken};
                idle_cnt <= '0;
                byte_q   <= byte_q + {11'b0, in_taken};
            end else if (cnt != 7'd0) begin
                idle_cnt <= idle_cnt + 1'b1;
            end

            if (out_fire) begin
                cnt      <= 7'd0;
                idle_cnt <= '0;
                byte_buf <= '0;      // 必须清干净：否则下次填不满时旧字节会被当成数据发出去
                flit_q   <= flit_q + 16'd1;
            end
        end
    end

    assign st_flits = flit_q;
    assign st_bytes = byte_q;

`ifndef SYNTHESIS
    // 同前：disable iff 的复位被判为同步使用，局部抑制 SYNCASYNCNET
    // verilator lint_off SYNCASYNCNET
    a_nonempty: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid) |-> (cnt != 7'd0));
    a_cnt: assert property (@(posedge clk) disable iff (!rst_n)
        (cnt <= 7'd64));
    // 发出的 flit 里“已写字节之外”必须是 0（padding 约定不能被破坏）
    a_pad: assert property (@(posedge clk) disable iff (!rst_n)
        (out_valid && (cnt < 64)) |-> (out_payload[cnt*8 +: 8] == 8'h00));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_STREAM_PACK_SV
