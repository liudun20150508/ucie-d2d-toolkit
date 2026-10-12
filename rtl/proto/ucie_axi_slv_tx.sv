// =============================================================================
// ucie_axi_slv_tx : AXI4 **slave 端口**收到的写/读请求 -> 协议层字节流（16 B/拍）
// -----------------------------------------------------------------------------
// 位置：AXI4 master 端口 与 字节流容器（ucie_stream_pack）之间。
//
// 做三件事：
//   1. AW / AR 请求进入各自的 FIFO（深度 = outstanding 数），分配自增 tag，
//      这样 AXI 的 AW/AR 通道不会被字节流发送速度拖住。
//   2. W 数据 beat 进 1 深度缓冲（skid），避免 W 通道被长期反压。
//   3. 一个**轮转仲裁**的源生成器，把三种源展开成字节流：
//        AW/AR 请求 : 16 B 头，一拍送完
//        W 数据 beat: 1 B beat 头 + 64 B 数据 = 65 B，跨 5 拍（16×4 + 1）
//
// 字节粒度流控：输出 st_bytes 是本拍可供字节数，st_taken 是下游实际吃掉多少；
// 源缓冲按 st_taken 前移。这样 65 B 的 beat 不必为对齐而插入 padding ——
// padding 只允许出现在事务之间（由 ucie_stream_pack 在 flit 末尾补 0x00）。
// =============================================================================
`ifndef UCIE_AXI_SLV_TX_SV
`define UCIE_AXI_SLV_TX_SV

module ucie_axi_slv_tx #(
    parameter int AW_FIFO_DEPTH = 4,
    parameter int AR_FIFO_DEPTH = 4
)(
    input  logic clk,
    input  logic rst_n,

    // ---- AXI4 AW ----
    input  logic                  awvalid,
    output logic                  awready,
    input  ucie_axi_pkg::axi_ax_t aw,

    // ---- AXI4 W ----
    input  logic                  wvalid,
    output logic                  wready,
    input  logic [511:0]          wdata,
    input  logic [63:0]           wstrb,
    input  logic                  wlast,

    // ---- AXI4 AR ----
    input  logic                  arvalid,
    output logic                  arready,
    input  ucie_axi_pkg::axi_ax_t ar,

    // ---- 字节流输出（接 ucie_stream_pack 的 in_*）----
    output logic         st_valid,
    input  logic [4:0]   st_taken,
    output logic [127:0] st_data,
    output logic [4:0]   st_bytes,

    // ---- 统计 ----
    output logic [15:0]  cnt_wr_req,
    output logic [15:0]  cnt_rd_req,
    output logic [15:0]  cnt_wr_data
);
    import ucie_pkg::*;
    import ucie_axi_pkg::*;

    localparam int AW_IDX_W = $clog2(AW_FIFO_DEPTH);
    localparam int AR_IDX_W = $clog2(AR_FIFO_DEPTH);
    localparam int SRC_W    = (BEAT_META_BYTES + 1)*8 + AXI_DATA_W;   // 528 bit = 66 B

    typedef struct packed {
        axi_ax_t         ax;
        logic [TAG_W-1:0] tag;
    } ax_ent_t;

    // =========================================================================
    // 1. AW / AR 请求 FIFO
    // =========================================================================
    ax_ent_t           aw_mem [0:AW_FIFO_DEPTH-1];
    ax_ent_t           ar_mem [0:AR_FIFO_DEPTH-1];
    logic [AW_IDX_W:0] aw_wr, aw_rd;
    logic [AR_IDX_W:0] ar_wr, ar_rd;

    wire aw_empty = (aw_wr == aw_rd);
    wire ar_empty = (ar_wr == ar_rd);
    wire aw_full  = ((aw_wr - aw_rd) == AW_FIFO_DEPTH[AW_IDX_W:0]);
    wire ar_full  = ((ar_wr - ar_rd) == AR_FIFO_DEPTH[AR_IDX_W:0]);

    assign awready = !aw_full;
    assign arready = !ar_full;

    wire aw_enq = awvalid && awready;
    wire ar_enq = arvalid && arready;

    wire [TAG_W-1:0] tag_next = tag_cnt + 1'b1;
    logic [TAG_W-1:0] tag_cnt;

    // FIFO 读写一律走「临时变量 + 整体赋值」。
    // 坑：数组元素的 struct 字段直接读写（mem[i].field <= v，或先 wire s = mem[i]
    // 再取 s.field）在 Verilator 下实测会丢内容 —— 读出来全 0。
    // 这与前面 slv_tx 的嵌套字面量问题是同一类：struct 与数组组合时不要按字段切。
    ax_ent_t aw_head, ar_head;
    ax_ent_t aw_e, ar_e;

    always_comb begin
        aw_head = aw_mem[aw_rd[AW_IDX_W-1:0]];
        ar_head = ar_mem[ar_rd[AR_IDX_W-1:0]];

        aw_e    = '0;
        aw_e.ax  = aw;
        aw_e.tag = tag_next;

        ar_e    = '0;
        ar_e.ax  = ar;
        ar_e.tag = tag_next;
    end

    // =========================================================================
    // 2. W 数据 1 深度缓冲（skid）
    // =========================================================================
    logic        w_hold_valid;
    logic [511:0] w_hold_data;
    logic [63:0]  w_hold_strb;
    logic         w_hold_last;
    logic [3:0]   beat_idx_q;

    assign wready = !w_hold_valid;
    wire w_enq = wvalid && wready;

    // =========================================================================
    // 3. 源生成器：轮转仲裁 + 字节流展开
    // =========================================================================
    typedef enum logic [1:0] { S_IDLE, S_HDR, S_WD } s_e;
    s_e           src_q;
    logic [SRC_W-1:0] src_sh;
    logic [6:0]   src_left;

    logic prio_q;      // 0: AW 优先，1: AR 优先（轮转，避免饥饿）

    wire aw_avail = !aw_empty;
    wire ar_avail = !ar_empty;
    wire pick_aw  = aw_avail && ((prio_q == 1'b0) || !ar_avail);
    wire pick_ar  = ar_avail && !pick_aw;

    // 请求头组装
    req_hdr_t aw_hdr, ar_hdr;
    always_comb begin
        aw_hdr = '0;
        aw_hdr.txn_type = TXN_WR_REQ;
        aw_hdr.id       = {4'b0, aw_head.ax.id};
        aw_hdr.addr     = aw_head.ax.addr;
        aw_hdr.len      = aw_head.ax.len;
        aw_hdr.size     = aw_head.ax.size;
        aw_hdr.burst    = aw_head.ax.burst;
        aw_hdr.tag      = aw_head.tag;

        ar_hdr = '0;
        ar_hdr.txn_type = TXN_RD_REQ;
        ar_hdr.id       = {4'b0, ar_head.ax.id};
        ar_hdr.addr     = ar_head.ax.addr;
        ar_hdr.len      = ar_head.ax.len;
        ar_hdr.size     = ar_head.ax.size;
        ar_hdr.burst    = ar_head.ax.burst;
        ar_hdr.tag      = ar_head.tag;
    end

    logic [7:0] w_meta;
    assign w_meta = {4'b0, beat_idx_q};

    wire [SRC_W-1:0] ld_hdr = {{(SRC_W-HDR_BITS){1'b0}}, (pick_aw ? aw_hdr : ar_hdr)};
    // 数据 beat 的字节流布局：[TXN_DATA(1B)][beat_idx(1B)][64B data]
    wire [SRC_W-1:0] ld_wd  = {w_hold_data, w_meta, TXN_DATA};

    wire src_busy = (src_q != S_IDLE);
    wire can_hdr  = (pick_aw || pick_ar);
    wire can_wd   = w_hold_valid;

    logic [6:0] taken7;
    assign taken7 = {2'b0, st_taken};

    always_comb begin
        st_valid = src_busy;
        st_data  = src_sh[127:0];
        st_bytes = (src_left > 7'd16) ? 5'd16 : src_left[4:0];
    end

    wire consume = src_busy && (st_taken != 5'd0);
    wire last_ui = consume && (taken7 >= src_left);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_wr        <= '0;
            aw_rd        <= '0;
            ar_wr        <= '0;
            ar_rd        <= '0;
            tag_cnt      <= '0;
            w_hold_valid <= 1'b0;
            w_hold_data  <= '0;
            w_hold_strb  <= '0;
            w_hold_last  <= 1'b0;
            beat_idx_q   <= 4'd0;
            src_q        <= S_IDLE;
            src_sh       <= '0;
            src_left     <= 7'd0;
            prio_q       <= 1'b0;
            cnt_wr_req   <= 16'd0;
            cnt_rd_req   <= 16'd0;
            cnt_wr_data  <= 16'd0;
        end else begin
            // ---- AW 入队 ----
            // 注意（踩过的坑）：不要用 '{ax: aw, tag: tag_next} 这种嵌套 struct 字面量。
            // 工具对「struct 数组 + assignment pattern」实测会把内层成员整个丢掉
            // （表现为从端收到的 addr/len 恒为 0，id/tag 却看似正常），
            // 进而 burst 被当成单拍 —— 单拍用例还能"假通过"，突发用例立刻暴露。
            // 逐字段赋值才可靠。
            if (aw_enq) begin
                aw_mem[aw_wr[AW_IDX_W-1:0]] <= aw_e;
                aw_wr      <= aw_wr + 1'b1;
                tag_cnt    <= tag_next;
                cnt_wr_req <= cnt_wr_req + 16'd1;
            end
            // ---- AR 入队 ----
            if (ar_enq) begin
                ar_mem[ar_wr[AR_IDX_W-1:0]] <= ar_e;
                ar_wr      <= ar_wr + 1'b1;
                tag_cnt    <= tag_next;
                cnt_rd_req <= cnt_rd_req + 16'd1;
            end
            // ---- W beat 入缓冲 ----
            if (w_enq) begin
                w_hold_valid <= 1'b1;
                w_hold_data  <= wdata;
                w_hold_strb  <= wstrb;
                w_hold_last  <= wlast;
                cnt_wr_data  <= cnt_wr_data + 16'd1;
                // beat 序号：一个 burst 内自增，wlast 结束
                beat_idx_q   <= wlast ? 4'd0 : (beat_idx_q + 4'd1);
            end

            // ---- 源生成器 ----
            if (src_busy) begin
                if (consume) begin
                    src_sh   <= src_sh >> (st_taken * 8);
                    src_left <= src_left - taken7;
                    if (last_ui) src_q <= S_IDLE;
                end
            end else begin
                if (can_hdr) begin
                    src_sh   <= ld_hdr;
                    src_left <= 7'd16;
                    src_q    <= S_HDR;
                    if (pick_aw) begin
                        aw_rd <= aw_rd + 1'b1;
                        prio_q <= 1'b1;          // 让 AR 下轮优先
                    end else begin
                        ar_rd <= ar_rd + 1'b1;
                        prio_q <= 1'b0;
                    end
                end else if (can_wd) begin
                    src_sh       <= ld_wd;
                    src_left     <= 7'd66;       // 1B 类型 + 1B beat 头 + 64B 数据
                    src_q        <= S_WD;
                    w_hold_valid <= 1'b0;        // beat 已被取走
                end
            end
        end
    end

`ifndef SYNTHESIS
    // 同前：disable iff 的复位被判为同步使用，局部抑制 SYNCASYNCNET
    // verilator lint_off SYNCASYNCNET
    // 字节流有效时必须有剩余字节
    a_left: assert property (@(posedge clk) disable iff (!rst_n)
        (st_valid) |-> (src_left != 7'd0));
    // 请求头必须在 16B 内送完（16 的倍数）
    a_hdr: assert property (@(posedge clk) disable iff (!rst_n)
        ((src_q == S_HDR) && (src_left > 7'd16)) |-> 1'b0);
    // verilator lint_on SYNCASYNCNET
`endif

endmodule

`endif  // UCIE_AXI_MASTER_TX_SV
