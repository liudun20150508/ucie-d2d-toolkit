// =============================================================================
// seq/ucie_seq.sv — sequence 层（UVM 对应：sequence，产生激励流）
// -----------------------------------------------------------------------------
// 目录规范参照 ref_project/tb/（该目录在参考实现中是预留的，
// run.sh 未列 seq 文件；本实现把它真正做出来，作为一处补充）
//
// 设计取舍：**不使用 class 继承**（virtual class / extends）—— Verilator 对
// class 继承的支持有限，用"单类 + mode 分支"更稳，可读性也够。
// =============================================================================
`ifndef UCIE_SEQ_SV
`define UCIE_SEQ_SV

import ucie_pkg::*;

class ucie_seq;
    // 序列类型
    localparam int SEQ_DIR      = 0;   // 定向：固定序号
    localparam int SEQ_RAND     = 1;   // 随机：$urandom_range
    localparam int SEQ_BOUNDARY = 2;   // 边界：idx 取符号/范围边界值

    function new();
    endfunction

    // 生成并驱动 n 笔；每笔驱动前登记期望（push），保证与 scoreboard 的 FIFO 对齐
    task automatic body(input int          mode,
                        input int          n,
                        input int unsigned base,
                        ucie_driver        drv,
                        ucie_scb           sb,
                        ucie_cov           cov);
        ucie_txn t;
        for (int i = 0; i < n; i++) begin
            t = new();
            case (mode)
                SEQ_DIR:      t.idx = base + i;
                SEQ_RAND:     t.idx = $urandom_range(0, 100000);
                SEQ_BOUNDARY: t.idx = (i % 4 == 0) ? 0 :
                                      (i % 4 == 1) ? 1 :
                                      (i % 4 == 2) ? 50000 : 99999;
                default:      t.idx = base + i;
            endcase
            t.compute();
            sb.push(t.idx);          // 先登记期望，再驱动（顺序不能反）
            drv.send(t);
            // 注意：**不要**在这里改 coverage 的场景标签。
            // 初版此处写了 `if (cov != null) cov.set_kind(0);`，把 test 侧设好的
            // kind（1=误码 / 2=lane 降级）覆盖回 0 —— 结果 cp_kind 只命中 1/3、
            // cross 只命中 3/9。场景标签是 test 的定位，seq 只管产生激励。
        end
    endtask
endclass

`endif  // UCIE_SEQ_SV
