// =============================================================================
// ucie_crc16 : flit 保护用 CRC-16-CCITT
// -----------------------------------------------------------------------------
// 用于 UCIe flit 的 CRC 字段（2 byte）：
//   poly = 0x1021（CRC-16-CCITT, 非反射）, init = 0xFFFF
//   覆盖 header(2B) + payload(64B) = 66 byte，逐字节喂入
//
// 实现方式：字节并行 + 逐字节时序累加。发送侧在组包时按字节推进，
// 接收侧在拆包时同步计算并比对；单 bit 错误、奇数个 bit 错误都能检出。
// =============================================================================
`ifndef UCIE_CRC16_SV
`define UCIE_CRC16_SV

module ucie_crc16 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        init,    // 1: 重新装载初值 0xFFFF（新 flit 起始）
    input  logic        en,      // 1: 吸收 data
    input  logic [7:0]  data,
    output logic [15:0] crc
);

    function automatic logic [15:0] crc16_byte(input logic [15:0] c_in, input logic [7:0] d);
        logic [15:0] c;
        c = c_in ^ {d, 8'h00};
        for (int i = 0; i < 8; i++) begin
            c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
        end
        return c;
    endfunction

    // 复位风格与全项目统一为**异步低有效**。
    // （原实现是同步复位；DFT 检查会把它标为"复位风格不一致"——
    //   复位风格不统一会给扫描插入与复位树带来额外约束，所以统一掉。）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)       crc <= 16'hFFFF;
        else if (init)    crc <= 16'hFFFF;
        else if (en)      crc <= crc16_byte(crc, data);
    end

`ifdef UCIE_CRC16_SELFCHECK
    // 单模块自检（make crc）：
    //   向量 "123456789" 的 CRC-16-CCITT(init=0xFFFF) = 0x29B1
    initial begin
        automatic logic [15:0] c = 16'hFFFF;
        automatic string s = "123456789";
        for (int i = 0; i < 9; i++) c = crc16_byte(c, s[i]);
        $display("[CRC16] \"123456789\" -> 0x%04h (expect 0x29B1) %s",
                 c, (c == 16'h29B1) ? "PASS" : "FAIL");
        if (c !== 16'h29B1) $fatal(1, "[CRC16] self-check failed");
    end
`endif

endmodule

`endif  // UCIE_CRC16_SV
