// =============================================================================
// ucie-d2d-demo : Chiplet D2D / UCIe 数字链路 demo —— 全局协议包
// -----------------------------------------------------------------------------
// 设计目标：Chiplet D2D IP 数字链路
//   - UCIe 协议栈：协议层(AXI/CHI 侧接口) / 适配层(D2D Adapter, DLL) /
//     物理层数字部分(RDI、链路训练 LTSSM、lane repair)
// 说明：本包按 UCIe 1.1 的字段语义建模，属**教学级简化实现**，
//       不承诺与规范逐位/逐时序兼容；与规范的具体差异见 docs/SPEC.md。
// =============================================================================
`ifndef UCIE_PKG_SV
`define UCIE_PKG_SV

package ucie_pkg;

    // =========================================================================
    // 1. 链路几何参数
    // =========================================================================
    localparam int LANES      = 16;             // module 内 lane 数（x16）
    localparam int LANE_BYTES = 1;              // 每 lane 每 UI 传 1 byte
    localparam int RDI_BYTES  = LANES * LANE_BYTES;   // 16 B/UI
    localparam int RDI_BITS   = RDI_BYTES * 8;        // 128 bit

    // 标准封装 flit：64B payload + 2B header + 2B CRC = 68B
    localparam int FLIT_PAYLOAD_BYTES = 64;
    localparam int FLIT_HDR_BYTES     = 2;
    localparam int FLIT_CRC_BYTES     = 2;
    localparam int FLIT_BYTES = FLIT_PAYLOAD_BYTES + FLIT_HDR_BYTES + FLIT_CRC_BYTES;

    localparam int FLIT_BITS = FLIT_BYTES * 8;              // 544 bit
    localparam int FLIT_UI   = (FLIT_BYTES + RDI_BYTES - 1) / RDI_BYTES;   // 5 个 UI

    typedef logic [FLIT_BITS-1:0] flit_t;
    typedef logic [RDI_BITS-1:0]  rdi_data_t;
    typedef logic [RDI_BYTES-1:0] rdi_mask_t;               // 字节级 valid

    // =========================================================================
    // 2. Flit header（16 bit，UCIe 1.1 header 的简化子集）
    //    [15]    rsvd
    //    [14:12] flit format
    //    [11:8]  protocol id（本 demo 只用 STREAM）
    //    [7:0]   sequence number（链路层重传/去重）
    // =========================================================================
    typedef enum logic [2:0] {
        FMT_DATA  = 3'd0,   // 64B 数据 flit
        FMT_CTRL  = 3'd1,   // 链路控制 flit（ACK/NAK/credit/error）
        FMT_NULL  = 3'd2,   // 空闲填充
        FMT_TRAIN = 3'd3    // 训练序列（deskew pattern / 参数交换）
    } flit_fmt_e;

    typedef enum logic [3:0] {
        PROTO_PCIE    = 4'd0,
        PROTO_CXL_IO  = 4'd1,
        PROTO_CXL_MEM = 4'd2,
        PROTO_STREAM  = 4'd3,   // 本 demo 默认
        PROTO_MGMT    = 4'd4
    } protocol_id_e;

    typedef struct packed {
        logic         rsvd;     // [15]
        flit_fmt_e    fmt;      // [14:12]
        protocol_id_e proto;    // [11:8]
        logic  [7:0]  seq;      // [7:0]
    } flit_hdr_t;

    // 把 header 放到 flit 的最高 16 bit（先传 header，UCIe 语义）
    function automatic flit_t flit_pack(flit_hdr_t h, logic [FLIT_PAYLOAD_BYTES*8-1:0] payload,
                                        logic [15:0] crc);
        return {h, payload, crc};
    endfunction

    function automatic flit_hdr_t flit_hdr_of(flit_t f);
        return flit_hdr_t'(f[FLIT_BITS-1 -: 16]);
    endfunction

    function automatic logic [FLIT_PAYLOAD_BYTES*8-1:0] flit_payload_of(flit_t f);
        return f[16 +: FLIT_PAYLOAD_BYTES*8];
    endfunction

    function automatic logic [15:0] flit_crc_of(flit_t f);
        return f[15:0];
    endfunction

    // CRC 覆盖范围：header(2B) + payload(64B) = 66B
    localparam int FLIT_CRC_COVER_BYTES = FLIT_HDR_BYTES + FLIT_PAYLOAD_BYTES;

    // =========================================================================
    // 3. 链路层（DLL）控制消息：放在 FMT_CTRL flit 的 payload byte0
    //    byte1 携带参数（seq / credit 数）
    // =========================================================================
    typedef enum logic [7:0] {
        DLL_MSG_NOP     = 8'h00,
        DLL_MSG_ACK     = 8'h01,   // 参数 = 被确认的 seq
        DLL_MSG_NAK     = 8'h02,   // 参数 = 需重传的 seq
        DLL_MSG_CREDIT  = 8'h03,   // 参数 = 返还的信用数
        DLL_MSG_LINKERR = 8'h04    // 链路不可恢复错误（上报 LTSSM）
    } dll_msg_e;

    // =========================================================================
    // 4. RDI（Raw D2D Interface）—— 数字侧状态编码
    //    lp_state_req / pl_state_sts 与 LTSSM 对齐
    // =========================================================================
    typedef enum logic [3:0] {
        LTS_RESET      = 4'd0,
        LTS_SBINIT     = 4'd1,   // 侧带握手、参数交换
        LTS_MBINIT     = 4'd2,   // 主带初始化（lane 映射协商）
        LTS_MBTRAIN    = 4'd3,   // 主带训练（skew / 电气参数）
        LTS_LINKINIT   = 4'd4,   // 链路层参数（credit / retry）握手
        LTS_ACTIVE     = 4'd5,   // 正常传输
        LTS_PHYRETRAIN = 4'd6,   // 重训练
        LTS_TRAINERROR = 4'd7,   // 训练失败
        LTS_L1         = 4'd8     // 低功耗态
    } ltssm_e;

    // RDI 每 lane 的训练/健康状态
    typedef enum logic [1:0] {
        LANE_DOWN     = 2'd0,
        LANE_REPAIRED = 2'd1,   // 由冗余 lane 顶替
        LANE_UP       = 2'd2
    } lane_sts_e;

    // 本 demo 的冗余 lane 策略：x16 module 提供 1 条冗余 lane
    localparam int LANES_TOTAL    = LANES + 1;   // 16 数据 + 1 冗余
    localparam int MAX_LANE_REPAIR = 1;
    // 物理 lane 编号 0..LANES_TOTAL-1 的位宽（5 bit）。
    // 注意别用 LANES-1（4 bit）——那样冗余 lane 编号 16 会被截断成 0。
    localparam int MAP_W          = $clog2(LANES_TOTAL);

    // =========================================================================
    // 5. 链路层 / 训练参数
    // =========================================================================
    localparam int RETRY_BUF_DEPTH = 8;    // 重传缓冲条目数（窗口）
    localparam int CREDIT_INIT     = 8;    // 初始链路信用（credit-based 流控）
    localparam int CREDIT_WIDTH    = 5;

    localparam int SKEW_MAX_UI     = 4;    // lane 间允许的最大偏斜（UI）
    localparam int SKEW_CNT_WIDTH  = 3;

    // 侧带（sideband）消息：SBINIT 阶段用于交换能力与 lane 映射
    typedef enum logic [7:0] {
        SB_MSG_NOP        = 8'h00,
        SB_MSG_PARAM_REQ  = 8'h10,   // 本端能力：lane 数 / 速率
        SB_MSG_PARAM_ACK  = 8'h11,
        SB_MSG_LANE_MAP   = 8'h12,   // lane 映射/修复结果
        SB_MSG_TRAIN_DONE = 8'h13
    } sb_msg_e;

    // =========================================================================
    // 6. Flit 保护：CRC-16-CCITT（poly 0x1021, init 0xFFFF, 非反射）
    //    覆盖范围 header(2B) + payload(64B) = 66B，不覆盖 CRC 自身。
    //
    //    这里的 crc16_flit() 是**组合展开**实现：综合后是一棵 66*8 级异或树，
    //    面积小但逻辑级数深（后端 STA 会看到路径过长）——这正是 demo 里
    //    留给后端环节的优化点：改为逐字节流水 CRC（见 ucie_crc16.sv 与 docs）。
    // =========================================================================
    function automatic logic [15:0] crc16_byte(input logic [15:0] c_in, input logic [7:0] d);
        logic [15:0] c;
        c = c_in ^ {d, 8'h00};
        for (int i = 0; i < 8; i++) begin
            c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
        end
        return c;
    endfunction

    function automatic logic [15:0] crc16_flit(input flit_hdr_t h,
                                               input logic [FLIT_PAYLOAD_BYTES*8-1:0] p);
        logic [15:0] c;
        logic [15:0] hw;
        hw = h;
        c  = 16'hFFFF;
        c  = crc16_byte(c, hw[15:8]);
        c  = crc16_byte(c, hw[7:0]);
        for (int i = FLIT_PAYLOAD_BYTES-1; i >= 0; i--) begin
            c = crc16_byte(c, p[i*8 +: 8]);
        end
        return c;
    endfunction

    // 校验一个完整 flit（header+payload 重算 CRC 并与 CRC 字段比对）
    function automatic logic crc16_check(flit_t f);
        return crc16_flit(flit_hdr_of(f), flit_payload_of(f)) == flit_crc_of(f);
    endfunction

endpackage

`endif  // UCIE_PKG_SV
