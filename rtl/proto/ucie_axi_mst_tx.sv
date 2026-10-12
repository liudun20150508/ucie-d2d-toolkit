// =============================================================================
// ucie_axi_mst_tx : AXI4 master 端口的响应（B/R）-> 协议层字节流
// -----------------------------------------------------------------------------
// 位置：**远端**桥接里，AXI 端口是 master 角色的那一侧。
//   （近端桥接的 AXI 端口是 slave 角色，对应 ucie_axi_slv_tx / ucie_axi_slv_rx）
//
// 也就是说：本模块代表远端 die 去访问本端的 AXI slave（内存模型），
// 把收到的写响应/读数据打包回链路：
//   * B 响应   -> TXN_WR_RESP，16 B 头
//   * R 一个 beat -> TXN_RD_DATA 头（仅 burst 首拍带）+ 1 B beat 头 + 64 B 数据
//                    => 首拍 81 B，后续每拍 65 B
//
// 与 ucie_axi_slv_tx 同构：源缓冲 + 字节流展开 + 字节粒度流控（st_taken）。
// B 与 R 之间用简单优先级仲裁（一拍最多装一个源），够用且不会死锁。
// =============================================================================
`ifndef UCIE_AXI_MST_TX_SV
`define UCIE_AXI_MST_TX_SV

module ucie_axi_mst_tx (
    input  logic clk,
    input  logic rst_n,

    // ---- AXI4 master 端口：B（写响应，输入）----
    input  logic       bvalid,
    output logic       bready,
    input  logic [3:0] bid,
    input  logic [1:0] bresp,

    // ---- AXI4 master 端口：R（读数据，输入）----
    input  logic         rvalid,
    output logic         rready,
    input  logic [3:0]   rid,
    input  logic [511:0] rdata,
    input  logic [1:0]   rresp,
    input  logic         rlast,

    // ---- 字节流输出（接 ucie_stream_pack 的 in_*）----
    output logic         st_valid,
    input  logic [4:0]   st_taken,
    output logic [127:0] st_data,
    output logic [4:0]   st_bytes,

    // ---- 统计 ----
    output logic [15:0]  cnt_b,
    output logic [15:0]  cnt_r
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    localparam int SRC_W = HDR_BITS + (BEAT_META_BYTES + 1)*8 + AXI_DATA_W;   // 656 bit = 82 B

    // =========================================================================
    // 源缓冲
    // =========================================================================
    logic [SRC_W-1:0] src_sh;
    logic [6:0]       src_left;
    logic             src_busy;
    logic [3:0]       beat_idx_q;
    logic             first_q;      // 当前 R burst 的首拍

    logic [15:0]      b_q, r_q;

    // 响应头
    rsp_hdr_t b_hdr, r_hdr;
    always_comb begin
        b_hdr = '0;
        b_hdr.txn_type = TXN_WR_RESP;
        b_hdr.id       = {4'b0, bid};
        b_hdr.bresp    = bresp;

        r_hdr = '0;
        r_hdr.txn_type = TXN_RD_DATA;
        r_hdr.id       = {4'b0, rid};
        r_hdr.rresp    = rresp;
        r_hdr.len      = 8'h00;      // 接收侧按 beat 头逐拍推进，不依赖 len
    end

    // beat 头：bit4 = RLAST（burst 末拍，AXI 的 R 通道靠它指示结束），bit[3:0] = beat_idx
    //          （即 8 位里 {3'b0, rlast, beat_idx[3:0]}，接收侧读 byte1 的 bit4）
    //
    // 为什么不把 burst 长度放进 RD_DATA 头：AXI 的 R 通道**不提供**长度信息
    // （只有 RLAST），所以接收侧只能靠 RLAST 判断 burst 结束 —— 让每个 beat
    // 自带 last 位是最直接的做法，也避免了 mst_tx 去猜总拍数。
    logic [7:0] beat_meta;
    assign beat_meta = {3'b0, rlast, beat_idx_q};

    // 装载数据
    wire [SRC_W-1:0] ld_b     = {{(SRC_W-HDR_BITS){1'b0}}, b_hdr};
    // 位序坑（踩过）：Verilog 拼接里**最右边的操作数在最低位、最先发出**。
    // 字节流必须是 [16B 头][类型][beat 头][64B 数据]，所以头要写在拼接的最右边。
    // 第一版写成 {r_hdr, rdata, beat_meta, TXN_DATA}，结果头被推到最高位最后才发，
    // 接收侧看到的首字节成了 0x03(TXN_DATA) 而不是 0x05(TXN_RD_DATA)。
    wire [SRC_W-1:0] ld_r_f  = {rdata, beat_meta, TXN_DATA, r_hdr};   // 82 B：16B 头 + 66B beat
    wire [SRC_W-1:0] ld_r_m  = {{(SRC_W-528){1'b0}}, rdata, beat_meta, TXN_DATA};  // 66 B

    // =========================================================================
    // 仲裁：源空闲时，B 优先于 R（B 是单拍、延迟敏感）
    // =========================================================================
    wire can_load = !src_busy;
    assign bready = can_load && bvalid;
    assign rready = can_load && !bvalid && rvalid;

    wire take_b = bready && bvalid;
    wire take_r = rready && rvalid;

    always_comb begin
        st_valid = src_busy;
        st_data  = src_sh[127:0];
        st_bytes = (src_left > 7'd16) ? 5'd16 : src_left[4:0];
    end

    wire consume = src_busy && (st_taken != 5'd0);
    wire [6:0] taken7 = {2'b0, st_taken};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_sh     <= '0;
            src_left   <= 7'd0;
            src_busy   <= 1'b0;
            beat_idx_q <= 4'd0;
            first_q    <= 1'b1;
            b_q        <= 16'd0;
            r_q        <= 16'd0;
        end else begin
            // ---- 源推进 ----
            if (src_busy) begin
                if (consume) begin
                    src_sh   <= src_sh >> (st_taken * 8);
                    src_left <= src_left - taken7;
                    if (taken7 >= src_left) src_busy <= 1'b0;
                end
            end else begin
                if (take_b) begin
                    src_sh   <= ld_b;
                    src_left <= 7'd16;
                    src_busy <= 1'b1;
                    b_q      <= b_q + 16'd1;
                end else if (take_r) begin
                    src_sh   <= first_q ? ld_r_f : ld_r_m;
                    src_left <= first_q ? 7'd82 : 7'd66;
                    src_busy <= 1'b1;
                    r_q      <= r_q + 16'd1;
                end
            end

            // ---- R burst 内部记账 ----
            if (take_r) begin
                if (rlast) begin
                    first_q    <= 1'b1;
                    beat_idx_q <= 4'd0;
                end else begin
                    first_q    <= 1'b0;
                    beat_idx_q <= beat_idx_q + 4'd1;
                end
            end
        end
    end

    assign cnt_b = b_q;
    assign cnt_r = r_q;

`ifndef SYNTHESIS
    // 同前：disable iff 的复位被判为同步使用，局部抑制 SYNCASYNCNET
    // verilator lint_off SYNCASYNCNET
    a_left: assert property (@(posedge clk) disable iff (!rst_n)
        (st_valid) |-> (src_left != 7'd0));
    // 首拍的载荷长度必须是 82 B（16B 头 + 66B beat）
    a_first: assert property (@(posedge clk) disable iff (!rst_n)
        (src_busy && first_q) |-> (src_left <= 7'd82));
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_AXI_MST_TX_SV
