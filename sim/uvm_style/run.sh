#!/bin/sh
# =============================================================================
# run.sh — 一键封装：编译 + 回归 + 覆盖率
# -----------------------------------------------------------------------------
# 规范参照 ref_project/sim/run.sh（编译+运行+覆盖率+日志落盘）。
#
# 用法：
#   sh sim/uvm_style/run.sh            # 默认 20 笔随机
#   sh sim/uvm_style/run.sh 100        # 指定随机笔数
#
# 与参考实现的差异说明：
#   - 参考实现用 `-DSYNTHESIS` 强制走真实硬件实现（其 DUT 里有 `ifndef SYNTHESIS`
#     的 $countones 仿真模型分支）。本项目的 RTL 是自研全可综合代码，**没有**
#     仿真专用分支，因此这里不需要该开关。
#   - 保留 --coverage + verilator_coverage --annotate（Verilator 原生覆盖率）。
# =============================================================================
set -e

N=${1:-20}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT"

TOP=test_top
OBJ=build/obj_uvm
LOGDIR=sim/uvm_style/logs
COVDIR=sim/uvm_style/coverage
mkdir -p "$OBJ" "$LOGDIR" "$COVDIR"

# 编译顺序有讲究（踩过：seq 里引用了 scb/cov 的类型，排在它们之前会报
# "Reference to 'ucie_scb' before declaration, IEEE 1800-2023 6.18"）：
#   txn -> iface -> agent -> scoreboard -> cov -> seq -> env -> test -> top
SRCS="sim/uvm_style/ucie_txn.sv \
      sim/uvm_style/iface/ucie_if.sv \
      sim/uvm_style/agent/ucie_driver.sv \
      sim/uvm_style/agent/ucie_monitor.sv \
      sim/uvm_style/scoreboard/ucie_scb.sv \
      sim/uvm_style/cov/ucie_cov.sv \
      sim/uvm_style/seq/ucie_seq.sv \
      sim/uvm_style/ucie_env.sv \
      sim/uvm_style/test/ucie_test.sv \
      sim/uvm_style/test_top.sv"

RTL="rtl/pkg/ucie_pkg.sv \
     rtl/link/ucie_flit_tx.sv rtl/link/ucie_flit_rx.sv \
     rtl/link/ucie_link_retry.sv rtl/link/ucie_dll.sv \
     rtl/phy/ucie_ltssm.sv rtl/phy/ucie_lane_repair.sv \
     rtl/phy/ucie_rdi.sv rtl/phy/ucie_link_pipe.sv rtl/phy/ucie_deskew.sv \
     rtl/phy/ucie_mgmt.sv \
     rtl/cdc/ucie_afifo.sv rtl/top/ucie_d2d_top.sv"

# 覆盖率选项：**刻意不用全开的 `--coverage`** —— Verilator 5.050 在它启用的
# FSM/表达式覆盖转换路径上，遇到 ucie_link_pipe.sv 的 SVA
#   assert property (@(posedge rdi_clk) disable iff (!rrst_n) ...)
# 会触发内部错误：V3Localize.cpp:203: AstVarRef not under function（工具 bug，非 RTL 问题）。
# 这里改用 line + toggle 两类，既能出 verilator_coverage 报告，又避开该崩溃路径。
VFLAGS="--binary --coverage-line --coverage-toggle --timing -Wno-fatal \
        -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
        -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
        -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -Wno-IMPORTSTAR \
        --Mdir $OBJ --top-module $TOP"

echo "[run.sh] 编译（--coverage）..."
verilator $VFLAGS $RTL $SRCS > "$OBJ/build.log" 2>&1 || {
  echo "[run.sh] 编译失败，尾部日志："; tail -25 "$OBJ/build.log"; exit 1; }

STAMP=$(date +%Y%m%d_%H%M%S)
echo "[run.sh] 运行（随机 $N 笔）..."
./$OBJ/V$TOP +N="$N" | tee "$LOGDIR/uvm_${STAMP}_N${N}.log"

if [ -f coverage.dat ]; then
  mv coverage.dat "$COVDIR/uvm_cov_latest.dat"
  echo "[run.sh] 覆盖率数据 -> $COVDIR/uvm_cov_latest.dat"
  verilator_coverage --annotate "$COVDIR/annotate" "$COVDIR/uvm_cov_latest.dat"
  echo "[run.sh] 覆盖率标注 -> $COVDIR/annotate/"
fi
echo "[run.sh] DONE"
