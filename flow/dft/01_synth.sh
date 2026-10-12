#!/bin/bash
# =============================================================================
# DFT Stage 01 · 综合 UCIe 子模块到 Nangate45 门级网表
# -----------------------------------------------------------------------------
# 移植自 backend/flow/dft/01_synth.sh（原项目用 SKY130 + tinyNPU）。
# 差异：RTL 用本项目 rtl/（SystemVerilog），库换 Nangate45。
#
# 用法：
#   sh flow/dft/01_synth.sh                 # 默认 ucie_lane_repair
#   sh flow/dft/01_synth.sh ucie_link_retry
#   sh flow/dft/01_synth.sh ucie_ltssm
# 输出：build/dft/01_synth/<TOP>_netlist.v + synth.log
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TOP="${1:-ucie_ltssm}"
LIB="${UCIE_LIB:-$ROOT/resources/nangate45/NangateOpenCellLibrary_typical.lib}"
OUT="$ROOT/build/dft/01_synth"
mkdir -p "$OUT"

# 按模块列出依赖源文件
case "$TOP" in
  ucie_lane_repair)
    SRCS="$ROOT/rtl/pkg/ucie_pkg.sv $ROOT/rtl/phy/ucie_lane_repair.sv" ;;
  ucie_link_retry)
    SRCS="$ROOT/rtl/pkg/ucie_pkg.sv $ROOT/rtl/link/ucie_crc16.sv $ROOT/rtl/link/ucie_link_retry.sv" ;;
  ucie_ltssm)
    SRCS="$ROOT/rtl/pkg/ucie_pkg.sv $ROOT/rtl/phy/ucie_ltssm.sv" ;;
  ucie_rdi_rx)
    SRCS="$ROOT/rtl/pkg/ucie_pkg.sv $ROOT/rtl/phy/ucie_rdi.sv" ;;
  *)
    echo "未知模块: $TOP"; exit 1 ;;
esac

if [ ! -f "$LIB" ]; then
  echo "找不到 liberty: $LIB"; exit 1
fi

cd "$OUT"

# 1) sv2v：SystemVerilog -> Verilog-2001
#    yosys 的 read_verilog -sv 解析不了 ucie_pkg.sv 里的 struct/赋值模式，
#    实测报 `ucie_pkg.sv:68: ERROR: syntax error, unexpected '{'`。
#    本项目的顶层综合流程同样走 sv2v（见 flow/Makefile 的注释），保持一致。
command -v sv2v >/dev/null || { echo "缺 sv2v（brew install sv2v）"; exit 1; }
sv2v -w "${TOP}_sv2v.v" $SRCS 2> "${TOP}_sv2v.log" \
  || { echo "sv2v 失败，见 ${TOP}_sv2v.log"; tail -20 "${TOP}_sv2v.log"; exit 1; }

# 2) yosys 综合 + 工艺映射（选项与 flow/Makefile 的顶层流程一致）
cat > "${TOP}_synth.ys" <<YSEOF
read_verilog ${TOP}_sv2v.v
hierarchy -top $TOP -check
proc
async2sync
opt
fsm
opt
wreduce
share
opt
techmap
opt
dfflibmap -liberty $LIB
abc -liberty $LIB -D 10000
opt_clean
stat -liberty $LIB
write_verilog -noattr ${TOP}_netlist.v
YSEOF

yosys -l "${TOP}_synth.log" "${TOP}_synth.ys"

echo "=== 单元统计（${TOP}）==="
grep -E "cells$|wires$" "${TOP}_synth.log" | tail -3 || true

echo "=== 单元类型分布 TOP8 ==="
grep -oE "^  [A-Z][A-Za-z0-9_]+" "${TOP}_netlist.v" | tr -d ' ' | sort | uniq -c | sort -rn | head -8 || true

# 自检：没有时序单元就没法插扫描链（ucie_lane_repair 就是纯组合，踩过）
# 注意：grep 无匹配时返回 1，在 set -euo pipefail 下会让脚本**在这里就静默退出**
# （纯组合模块因此永远看不到下面那条警告，退出码还是 1，调用方以为综合失败）。
# 实测证据：sh -x 的 trace 停在 `+ NDFF=0` 之后再无任何命令 —— 必须 || true 兜住。
NDFF=$(grep -oE "^  (DFF|DFFR|SDFF)[A-Za-z0-9_]*" "${TOP}_netlist.v" | wc -l | tr -d ' ' || true)
echo "=== 时序单元（DFF/DFFR/SDFF）总数: $NDFF ==="
if [ "$NDFF" -eq 0 ]; then
  echo "警告：${TOP} 综合后无时序单元 —— 纯组合模块，没有可扫描的 FF，不适合做扫描链插入"
fi
