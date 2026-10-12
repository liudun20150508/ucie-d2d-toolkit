#!/bin/bash
# =============================================================================
# install.sh : 一键安装依赖 + 环境自检（macOS / Homebrew）
# -----------------------------------------------------------------------------
# 用法：
#   sh install.sh          # 检查缺哪些，缺了自动 brew install，最后跑自检
#   sh install.sh --check  # 只检查，不安装
#
# 依赖（全部开源，无商业 EDA）：
#   verilator       仿真            brew: verilator
#   yosys           综合            brew: yosys
#   sv2v            SV->Verilog     brew: sv2v
#   opensta         静态时序签核     brew: opensta
#   openroad        APR/写SDF       brew: openroad
#   iverilog        门级/SDF后仿    brew: icarus-verilog
#   gtkwave         看波形(可选)    brew: gtkwave
# =============================================================================
set -e
CHECK_ONLY=0
[ "$1" = "--check" ] && CHECK_ONLY=1

# 二进制名 -> brew 包名
declare -A PKG=(
  [verilator]=verilator
  [yosys]=yosys
  [sv2v]=sv2v
  [opensta]=opensta
  [openroad]=openroad
  [iverilog]=icarus-verilog
  [gtkwave]=gtkwave
)

MISSING=()
for bin in verilator yosys sv2v opensta openroad iverilog gtkwave; do
  command -v "$bin" >/dev/null 2>&1 || MISSING+=("$bin")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "缺少依赖：${MISSING[*]}"
  if [ "$CHECK_ONLY" = "1" ]; then
    echo "（--check 模式，跳过安装）"
    exit 1
  fi
  echo "→ 逐个安装（按 brew 包名）"
  for bin in "${MISSING[@]}"; do
    brew install "${PKG[$bin]}"
  done
else
  echo "依赖齐全：verilator / yosys / sv2v / opensta / openroad / icarus-verilog / gtkwave"
fi

echo
echo "== 环境自检（跑工具链 smoke 自检）=="
make smoke 2>/dev/null || make crc 2>/dev/null || {
  echo "自检未跑通（可能缺工具或版本过旧），见 build/*.log"
  exit 1
}
echo "✅ 安装 + 自检通过，可直接 make all / make dft-flow / cd flow && make all / make sdf"
