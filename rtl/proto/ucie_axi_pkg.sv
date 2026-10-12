// =============================================================================
// ucie_axi_pkg : 协议层（AXI4 <-> UCIe flit）的公共定义
// -----------------------------------------------------------------------------
// 对应需求第 2 条「协议层优先支持 AXI、CHI 协议接口」。
// 详细的字段布局与设计取舍见 docs/PROTOCOL.md，这里只放类型与编解码函数。
//
// 核心概念（务必先读 docs/PROTOCOL.md §2）：
//   flit payload 被当作**协议层聚合容器**：63 字节字节流 + 1 字节有效计数。
//   AXI 事务序列化成字节流后跨 flit 无缝拼接，不要求与 512 位 beat 边界对齐。
// =============================================================================
`ifndef UCIE_AXI_PKG_SV
`define UCIE_AXI_PKG_SV

package ucie_axi_pkg;

    import ucie_pkg::*;

    // =========================================================================
    // 1. 几何参数
    // =========================================================================
    localparam int AXI_ID_W    = 4;      // AXI ID 位宽（demo 用 4 位）
    localparam int AXI_ADDR_W  = 64;
    localparam int AXI_DATA_W  = 512;    // 64 B/beat
    localparam int AXI_DATA_BYTES = AXI_DATA_W / 8;
    localparam int AXI_STRB_W  = AXI_DATA_BYTES;
    localparam int AXI_LEN_W   = 8;      // AxLEN，0..15 有效
    localparam int AXI_LEN_MAX = 15;

    localparam int TAG_W       = 16;
    localparam int OS_DEPTH    = 4;      // 读写各 4 笔 outstanding

    // 字节流容器：整个 payload 都是协议层字节流，不足处填 PAD_BYTE
    localparam int STREAM_BYTES    = FLIT_PAYLOAD_BYTES;      // 64 B
    localparam int STREAM_W_BYTES  = 16;                      // 字节流接口宽度：16 B/拍
    localparam int STREAM_W_BITS   = STREAM_W_BYTES * 8;      // 128 bit
    localparam int TXN_HDR_BYTES   = 16;
    localparam int BEAT_META_BYTES = 1;
    // 数据 beat = 1B 类型码 + 1B beat 头 + 64B 数据
    //
    // 为什么 beat 必须自带类型码（踩过的真坑）：
    //   第一版把 beat 定成 [beat_idx(1B)][64B data] = 65B，靠 beat 头区分。
    //   但 beat_idx 取值 0x00..0x0F，与事务类型码 0x01..0x05 **区间重叠** ——
    //   接收侧在事务边界看到 0x01 无法判断它是 TXN_WR_REQ 还是 beat_idx=1 的 beat，
    //   看到 0x00 又会被当成 padding 丢掉。结果写数据一个 beat 都解析不出来。
    //   加 1B 类型码后，边界处的首字节唯一确定事务种类，歧义消除。
    localparam int DATA_BEAT_BYTES = 1 + BEAT_META_BYTES + AXI_DATA_BYTES;   // 66 B

    localparam int HDR_BITS  = TXN_HDR_BYTES * 8;             // 128
    localparam int HDR_BYTES = TXN_HDR_BYTES;

    // =========================================================================
    // 2. 事务类型（docs/PROTOCOL.md §4）
    // =========================================================================
    typedef enum logic [7:0] {
        TXN_IDLE    = 8'h00,   // 填充字节（PAD_BYTE），接收侧在事务边界跳过
        TXN_WR_REQ  = 8'h01,   // Master -> Slave，16B 请求头
        TXN_RD_REQ  = 8'h02,   // Master -> Slave，16B 请求头
        TXN_DATA    = 8'h03,   // 数据 beat：[TXN_DATA][beat_idx(1B)][64B data] = 66B
        TXN_WR_RESP = 8'h04,   // Slave  -> Master，16B 响应头
        TXN_RD_DATA = 8'h05    // Slave  -> Master，16B 读数据头（后跟 N 个 TXN_DATA）
    } txn_type_e;

    typedef enum logic [1:0] {
        RESP_OKAY   = 2'b00,
        RESP_EXOKAY = 2'b01,
        RESP_SLVERR = 2'b10,
        RESP_DECERR = 2'b11
    } axi_resp_e;

    typedef enum logic [1:0] {
        BURST_FIXED = 2'b00,
        BURST_INCR  = 2'b01,
        BURST_WRAP  = 2'b10   // 声明不支持，接收侧会拒绝
    } axi_burst_e;

    // =========================================================================
    // 3. 字节流头部结构（packed struct 的**最后一个**成员对应 byte0）
    // =========================================================================

    // 3.1 请求头 16B
    typedef struct packed {
        logic [7:0]  rsvd15;    // byte15
        logic [5:0]  rsvd14;    // byte14[7:2]
        logic [1:0]  lock;      // byte14[1:0]
        logic [15:0] tag;       // byte13..12
        logic [2:0]  rsvd11;    // byte11[7:5]
        axi_burst_e  burst;     // byte11[4:3]
        logic [2:0]  size;      // byte11[2:0]
        logic [7:0]  len;       // byte10
        logic [63:0] addr;      // byte9..2
        logic [7:0]  id;        // byte1
        txn_type_e   txn_type;  // byte0
    } req_hdr_t;

    // 3.2 响应头 16B（复用同样 16B 位置，字段语义不同）
    typedef struct packed {
        logic [7:0]  rsvd15;    // byte15
        logic [5:0]  rsvd14;    // byte14[7:2]
        logic [1:0]  rresp;     // byte14[1:0]
        logic [15:0] tag;       // byte13..12
        logic [5:0]  rsvd11;    // byte11[7:2]
        logic [1:0]  bresp;     // byte11[1:0]
        logic [7:0]  len;       // byte10：读数据返回拍数-1，写响应恒 0
        logic [63:0] rsvd_addr; // byte9..2
        logic [7:0]  id;        // byte1
        txn_type_e   txn_type;  // byte0
    } rsp_hdr_t;

    // 3.3 数据 beat 头 1B
    typedef struct packed {
        logic [3:0]  rsvd;      // byte0[7:4]
        logic [3:0]  beat_idx;  // byte0[3:0]
    } beat_meta_t;

    // =========================================================================
    // 4. AXI4 通道载荷（供桥接模块的端口使用）
    // =========================================================================
    typedef struct packed {
        logic [AXI_ID_W-1:0]   id;
        logic [AXI_ADDR_W-1:0] addr;
        logic [AXI_LEN_W-1:0]  len;
        logic [2:0]            size;
        axi_burst_e            burst;
    } axi_ax_t;                 // AW 与 AR 同构

    // =========================================================================
    // 5. flit payload <-> 字节流
    // -------------------------------------------------------------------------
    // payload 的 64 B **全部**是协议层字节流；发送侧不足处填 PAD_BYTE(0x00)，
    // 接收侧解析事务时在**事务边界**遇到 0x00 即视为 padding 并跳过。
    //
    // 为什么不用“有效字节计数字段”：
    //   那要占掉 1 B，带宽效率掉到 92.6%（63/68）；靠事务自描述 + IDLE 标记
    //   可以全用 64 B，效率 94.1%（64/68）。
    // 敢用 0x00 当 padding 的前提：事务类型码里没有 0x00（TXN_IDLE 恰为空闲码），
    // 所以事务边界处的 0x00 只可能是 padding；数据区内部的 0x00 不受影响，
    // 因为解析器只在事务边界做这个判断。
    // =========================================================================
    localparam logic [7:0] PAD_BYTE = 8'h00;

    // 头部 <-> 位向量
    function automatic logic [HDR_BITS-1:0] req_hdr_bits(input req_hdr_t h);
        return h;
    endfunction

    function automatic req_hdr_t bits_req_hdr(input logic [HDR_BITS-1:0] b);
        return req_hdr_t'(b);
    endfunction

    function automatic logic [HDR_BITS-1:0] rsp_hdr_bits(input rsp_hdr_t h);
        return h;
    endfunction

    function automatic rsp_hdr_t bits_rsp_hdr(input logic [HDR_BITS-1:0] b);
        return rsp_hdr_t'(b);
    endfunction

    // 某个事务类型在字节流里占多少字节
    //   *_REQ / *_RESP / RD_DATA 头 : 16 B
    //   DATA beat                    : 66 B（1B 类型 + 1B beat 头 + 64B 数据）
    function automatic int txn_payload_bytes(input txn_type_e t);
        unique case (t)
            TXN_WR_REQ, TXN_RD_REQ, TXN_WR_RESP, TXN_RD_DATA: return TXN_HDR_BYTES;
            TXN_DATA:                                         return DATA_BEAT_BYTES;
            default:                                          return 0;
        endcase
    endfunction

endpackage

`endif  // UCIE_AXI_PKG_SV
