// =============================================================================
// ucie_flit_tx : 上行事务组包 —— 协议层事务 -> 68B flit
// -----------------------------------------------------------------------------
// 定位（对应 UCIe 适配层 / D2D Adapter 的发送方向）：
//   1. 生成 flit header（fmt / protocol_id / seq）
//   2. 计算 CRC-16 保护字段
//   3. 与上层以 valid/ready 握手，一个 64B 事务出一个 flit（一拍）
//
// 接口约定：上层提交一笔事务需要两个条件同时成立——
//   tx_valid 由上层给出，flit_ready 由下游（retry 窗口）给出。
// 上层可接收信号 = flit_ready，因此本模块**不再单独输出 tx_ready**
// （两者同义，同时输出会在顶层形成组合环，见 ucie_dll 里的注释）。
// =============================================================================
`ifndef UCIE_FLIT_TX_SV
`define UCIE_FLIT_TX_SV

module ucie_flit_tx (
    input  logic        clk,
    input  logic        rst_n,

    // 上层事务接口：64B/拍
    input  logic        tx_valid,
    input  logic [ucie_pkg::FLIT_PAYLOAD_BYTES*8-1:0] tx_data,

    // 组包后的 flit 交给链路层
    output logic        flit_valid,
    output ucie_pkg::flit_t flit,
    input  logic        flit_ready,

    output logic [7:0]  seq_out,
    output ucie_pkg::flit_hdr_t hdr_out
);
    import ucie_pkg::*;

    logic [7:0] seq_q;
    flit_hdr_t  hdr_c;
    logic [15:0] crc_c;

    always_comb begin
        hdr_c = '{rsvd: 1'b0, fmt: FMT_DATA, proto: PROTO_STREAM, seq: seq_q};
        crc_c = crc16_flit(hdr_c, tx_data);
        flit  = flit_pack(hdr_c, tx_data, crc_c);
    end

    assign flit_valid = tx_valid;
    assign seq_out    = seq_q;
    assign hdr_out    = hdr_c;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                            seq_q <= 8'h00;
        else if (tx_valid && flit_ready)       seq_q <= seq_q + 8'd1;
    end

endmodule

`endif  // UCIE_FLIT_TX_SV
