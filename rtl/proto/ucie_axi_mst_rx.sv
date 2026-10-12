// =============================================================================
// ucie_axi_mst_rx : 协议层字节流 -> AXI4 master 端口的请求（AW / AR / W）
// -----------------------------------------------------------------------------
// 位置：**远端**桥接里，把链路来的事务还原成对 AXI slave（内存模型）的访问。
//
// 解析规则（与 ucie_axi_slv_rx 共用同一套事务格式）：
//   事务边界读 0x00          -> padding，逐字节丢弃
//   TXN_WR_REQ (16B)         -> 驱动 AW 通道
//   TXN_RD_REQ (16B)         -> 驱动 AR 通道
//   TXN_WR_DATA(1B+64B=65B)  -> 驱动一个 W beat（wstrb 恒全 1，见 docs/PROTOCOL.md）
//
// 简化声明（不做隐性假设）：
//   * 不支持写数据交织：W beat 归属“最近一次 AW”，用 awlen_q 判断 wlast；
//   * 不支持字节选通：WSTRB 固定全 1（整拍写）；
//   * AW/AR/W 各自独立握手，但按链路顺序到达（链路本身有序可靠）。
// =============================================================================
`ifndef UCIE_AXI_MST_RX_SV
`define UCIE_AXI_MST_RX_SV

module ucie_axi_mst_rx (
    input  logic clk,
    input  logic rst_n,

    // ---- 来自 ucie_stream_unpack 的字节流 ----
    input  logic         st_valid,
    input  logic [127:0] st_data,
    input  logic [4:0]   st_bytes,
    output logic [4:0]   st_taken,

    // ---- AXI4 master 端口：AW（输出）----
    output logic         awvalid,
    input  logic         awready,
    output logic [3:0]   awid,
    output logic [63:0]  awaddr,
    output logic [7:0]   awlen,
    output logic [2:0]   awsize,
    output logic [1:0]   awburst,

    // ---- AXI4 master 端口：W（输出）----
    output logic         wvalid,
    input  logic         wready,
    output logic [511:0] wdata,
    output logic [63:0]  wstrb,
    output logic         wlast,

    // ---- AXI4 master 端口：AR（输出）----
    output logic         arvalid,
    input  logic         arready,
    output logic [3:0]   arid,
    output logic [63:0]  araddr,
    output logic [7:0]   arlen,
    output logic [2:0]   arsize,
    output logic [1:0]   arburst,

    // ---- 统计 ----
    output logic [15:0]  cnt_wr_req,
    output logic [15:0]  cnt_rd_req,
    output logic [15:0]  cnt_wr_data,
    output logic [15:0]  cnt_err
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    localparam int ACC_BYTES  = 96;
    localparam int ACC_W      = ACC_BYTES * 8;
    localparam int BEAT_BYTES = DATA_BEAT_BYTES;   // 66（1B 类型 + 1B beat 头 + 64B 数据）

    // =========================================================================
    // 累加器（与 ucie_axi_slv_rx 同构）
    // =========================================================================
    logic [ACC_W-1:0] acc_q, acc_c;
    logic [7:0]       cnt_q, cnt_c;
    logic [7:0]       type_q;          // 本拍识别到的事务类型（用于本拍决策）

    typedef enum logic [1:0] { P_HDR, P_AW, P_AR, P_W } ps_e;
    ps_e ps_q, ps_c;

    // 当前头解析结果
    logic [3:0]  awid_q, arid_q;
    logic [63:0] awaddr_q, araddr_q;
    logic [7:0]  awlen_q, arlen_q;
    logic [2:0]  awsize_q, arsize_q;
    logic [1:0]  awburst_q, arburst_q;

    // W beat 数据
    logic [511:0] wdata_q;
    logic [3:0]   wbeat_q;

    logic [15:0]  wrq_q, rdq_q, wdq_q, err_q;

    // =========================================================================
    // 事务边界识别
    // =========================================================================
    wire at_boundary = (ps_q == P_HDR);
    wire byte0_zero  = (acc_q[7:0] == PAD_BYTE);
    wire is_pad      = at_boundary && (cnt_q != 8'd0) && byte0_zero;
    wire has_hdr     = at_boundary && (cnt_q >= HDR_BYTES[7:0]) && !byte0_zero;
    wire is_data_t   = has_hdr && (acc_q[7:0] == TXN_DATA);
    wire is_beat     = at_boundary && is_data_t && (cnt_q >= BEAT_BYTES[7:0]);
    wire is_req      = has_hdr && !is_data_t;

    wire wr_req_t = is_req && (acc_q[7:0] == TXN_WR_REQ);
    wire rd_req_t = is_req && (acc_q[7:0] == TXN_RD_REQ);
    wire illegal_t= is_req && !wr_req_t && !rd_req_t;

    // =========================================================================
    // AXI 通道输出
    // =========================================================================
    assign awvalid = (ps_q == P_AW);
    assign awid    = awid_q;
    assign awaddr  = awaddr_q;
    assign awlen   = awlen_q;
    assign awsize  = awsize_q;
    assign awburst = awburst_q;

    assign arvalid = (ps_q == P_AR);
    assign arid    = arid_q;
    assign araddr  = araddr_q;
    assign arlen   = arlen_q;
    assign arsize  = arsize_q;
    assign arburst = arburst_q;

    assign wvalid  = (ps_q == P_W);
    assign wdata   = wdata_q;
    assign wstrb   = {AXI_STRB_W{1'b1}};      // 整拍写，不做字节选通
    assign wlast   = (ps_q == P_W) && (wbeat_q >= awlen_q[3:0]);

    wire aw_fire = awvalid && awready;
    wire ar_fire = arvalid && arready;
    wire w_fire  = wvalid && wready;

    // =========================================================================
    // 消费决策
    // =========================================================================
    logic [7:0] consume_b;
    always_comb begin
        consume_b = 8'd0;
        if (is_pad)                   consume_b = 8'd1;
        else if (is_beat)             consume_b = BEAT_BYTES[7:0];   // 65
        else if (is_req)              consume_b = HDR_BYTES[7:0];    // 16
    end

    wire [8:0] room9      = {1'b0, ACC_BYTES[7:0]} - {1'b0, cnt_q};
    wire       can_append = st_valid && ({1'b0, st_bytes} <= room9 + {1'b0, consume_b});
    assign st_taken = can_append ? st_bytes : 5'd0;

    // 头字段（组合取自累加器）
    wire [127:0] hdr_now = acc_q[HDR_BITS-1:0];

    always_comb begin
        acc_c = acc_q;
        cnt_c = cnt_q;
        ps_c  = ps_q;

        // 1) 追加
        if (can_append) begin
            for (int i = 0; i < 16; i++) begin
                if (i[4:0] < st_bytes) begin
                    acc_c[(cnt_q + i[7:0])*8 +: 8] = st_data[i*8 +: 8];
                end
            end
            cnt_c = cnt_q + st_bytes;
        end

        // 2) 消费
        if (consume_b != 8'd0) begin
            acc_c = acc_c >> (consume_b * 8);
            cnt_c = cnt_c - consume_b;
        end

        // 3) 状态推进
        if (ps_q == P_AW) begin
            if (awready) ps_c = P_HDR;
        end else if (ps_q == P_AR) begin
            if (arready) ps_c = P_HDR;
        end else if (ps_q == P_W) begin
            if (wready) ps_c = P_HDR;
        end else begin
            if (wr_req_t)      ps_c = P_AW;
            else if (rd_req_t) ps_c = P_AR;
            else if (is_beat)  ps_c = P_W;
        end
    end

    // =========================================================================
    // 时序
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_q    <= '0;
            cnt_q    <= 8'd0;
            ps_q     <= P_HDR;
            type_q   <= 8'd0;
            awid_q   <= 4'd0;
            awaddr_q <= 64'd0;
            awlen_q  <= 8'd0;
            awsize_q <= 3'd0;
            awburst_q<= 2'd0;
            arid_q   <= 4'd0;
            araddr_q <= 64'd0;
            arlen_q  <= 8'd0;
            arsize_q <= 3'd0;
            arburst_q<= 2'd0;
            wdata_q  <= '0;
            wbeat_q  <= 4'd0;
            wrq_q    <= 16'd0;
            rdq_q    <= 16'd0;
            wdq_q    <= 16'd0;
            err_q    <= 16'd0;
        end else begin
            acc_q <= acc_c;
            cnt_q <= cnt_c;
            ps_q  <= ps_c;

            // 请求头解析：byte1=id, byte2..9=addr, byte10=len, byte11={3'b0,burst,size}, byte12-13=tag
            if (wr_req_t) begin
                awid_q    <= hdr_now[8 +: 4];
                awaddr_q  <= hdr_now[16 +: 64];
                awlen_q   <= hdr_now[80 +: 8];
                awburst_q <= hdr_now[91 +: 2];
                awsize_q  <= hdr_now[88 +: 3];
                wrq_q     <= wrq_q + 16'd1;
                wbeat_q   <= 4'd0;            // 新写事务，beat 序号归零
            end
            if (rd_req_t) begin
                arid_q    <= hdr_now[8 +: 4];
                araddr_q  <= hdr_now[16 +: 64];
                arlen_q   <= hdr_now[80 +: 8];
                arburst_q <= hdr_now[91 +: 2];
                arsize_q  <= hdr_now[88 +: 3];
                rdq_q     <= rdq_q + 16'd1;
            end
            if (is_beat) begin
                // 65 B = 1 B beat 头 + 64 B 数据
                wdata_q <= acc_q[2*8 +: AXI_DATA_W];   // 跳过 1B 类型 + 1B beat 头
                wbeat_q <= acc_q[8 +: 4];             // 第二字节的低 4 位 = beat_idx
                wdq_q   <= wdq_q + 16'd1;
            end
            if (illegal_t) err_q <= err_q + 16'd1;
        end
    end

    assign cnt_wr_req  = wrq_q;
    assign cnt_rd_req  = rdq_q;
    assign cnt_wr_data = wdq_q;
    assign cnt_err     = err_q;

`ifndef SYNTHESIS
    // 同前：disable iff 的复位被判为同步使用，局部抑制 SYNCASYNCNET
    // verilator lint_off SYNCASYNCNET
    a_acc: assert property (@(posedge clk) disable iff (!rst_n)
        (cnt_q <= ACC_BYTES[7:0]));
    // AW/AR valid 必须保持到 ready（AXI 基本要求）
    a_aw_hold: assert property (@(posedge clk) disable iff (!rst_n)
        ((ps_q == P_AW) && !awready) |=> (ps_q == P_AW));
    a_ar_hold: assert property (@(posedge clk) disable iff (!rst_n)
        ((ps_q == P_AR) && !arready) |=> (ps_q == P_AR));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_AXI_MST_RX_SV
