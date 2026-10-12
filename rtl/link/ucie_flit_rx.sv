// =============================================================================
// ucie_flit_rx : 下行拆包 + CRC 校验 —— 68B flit -> 协议层事务
// -----------------------------------------------------------------------------
// 定位（对应 UCIe 适配层 / D2D Adapter 的接收方向）：
//   1. 解析 header（fmt / proto / seq）
//   2. 重算 CRC 并与 flit 尾巴的 CRC 字段比对
//   3. 单深度 skid buffer 承接，通过 valid/ready 与下游握手
//
// 注意：本模块**只做拆包与完整性判定**，不做 ACK/NAK 与重传决策——
//       那是链路层（ucie_dll）的事，保持关注点分离，便于单元验证。
// =============================================================================
`ifndef UCIE_FLIT_RX_SV
`define UCIE_FLIT_RX_SV

module ucie_flit_rx (
    input  logic        clk,
    input  logic        rst_n,

    // 来自物理层（RDI 重组后）的 flit
    input  logic        flit_valid,
    input  ucie_pkg::flit_t flit,
    output logic        flit_ready,

    // 拆包结果（已打一拍）
    output logic        out_valid,
    input  logic        out_ready,
    output logic [ucie_pkg::FLIT_PAYLOAD_BYTES*8-1:0] out_data,
    output ucie_pkg::flit_hdr_t out_hdr,
    output logic        out_crc_ok,

    // 诊断计数（供验证与遥测）
    output logic        crc_err_pulse
);
    import ucie_pkg::*;

    logic       out_valid_q;
    flit_hdr_t  hdr_d;
    logic       crc_ok_d;
    logic [FLIT_PAYLOAD_BYTES*8-1:0] data_d;
    logic       accept;

    assign accept     = !out_valid_q || out_ready;
    assign flit_ready = accept;

    assign out_hdr    = hdr_d;
    assign out_data   = data_d;
    assign out_crc_ok = crc_ok_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_q  <= 1'b0;
            hdr_d        <= '0;
            data_d       <= '0;
            crc_ok_d     <= 1'b0;
            crc_err_pulse<= 1'b0;
        end else begin
            crc_err_pulse <= 1'b0;
            if (flit_valid && accept) begin
                out_valid_q   <= 1'b1;
                hdr_d         <= flit_hdr_of(flit);
                data_d        <= flit_payload_of(flit);
                crc_ok_d      <= crc16_check(flit);
                crc_err_pulse <= ~crc16_check(flit);
            end else if (out_ready) begin
                out_valid_q   <= 1'b0;
            end
        end
    end

    assign out_valid = out_valid_q;

endmodule

`endif  // UCIE_FLIT_RX_SV
