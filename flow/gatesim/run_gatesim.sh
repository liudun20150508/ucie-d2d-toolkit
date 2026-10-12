#!/bin/sh
# =============================================================================
# run_gatesim.sh — 门级仿真 + RTL 对照（零延时，纯组合模块穷举）
# -----------------------------------------------------------------------------
# 做法：**同一份 TB（tb_gatesim.v）跑两遍** ——
#   1) 接门级网表（build/dft/01_synth/<TOP>_netlist.v）+ liberty 行为模型
#   2) 接 RTL 的 sv2v 转换版（build/dft/01_synth/<TOP>_sv2v.v）
# 再对两次运行的逐组打印做 diff。
#
# 意义：**证明综合（RTL -> 门级网表）没有改变功能**。只跑门级看它自己过没过，
#   并不能说明综合正确 —— 一定要有 RTL 侧对照。
#
# 为什么选 ucie_lane_repair 作 DUT：
#   它是**纯组合**模块且只有唯一输入 lane_good[16:0]，输入空间仅 2^17，
#   **可以穷举**；而 ucie_ltssm 含异步复位与侧带握手，在 yosys sim 下复位语义
#   难控（实测 trace 全 x）。换目标后得到的证据更强：**完备**等价，而非抽样。
#
# 边界（不说过头）：这是**零延时门级仿真**，没有 SDF 反标，因此**不验证时序**，
#   只验证"综合后的逻辑功能等价"（Nangate45 无 Verilog 单元行为模型，平台目录下
#   只有 cells_adders/clkgate/latch 三个补充模型，所以 Verilator 路线不可行，
#   只能用 yosys 的 liberty 行为模型）。
#   ⚠ 修正记录（2026-10-12）：早前"带延时的时序仿真本机没有 SDF"的说法是错的 ——
#   SKY130 单模块 SDF 后仿链本机已跑通（OpenROAD write_sdf + Icarus $sdf_annotate，
#   反标单元+互连延迟，见 make sdf / flow/sky130/postapr_gatesim.sh）。本脚本只管
#   "Nangate45 零延时门级等价"，时序后仿请走 make sdf。
#
# 用法：sh flow/gatesim/run_gatesim.sh
# =============================================================================
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
OUT="$ROOT/build/gatesim"
LIB="${UCIE_LIB:-$ROOT/resources/nangate45/NangateOpenCellLibrary_typical.lib}"
TOP="${UCIE_TOP:-ucie_lane_repair}"
TB="$ROOT/sim/verilator/tb_gatesim.v"
NSIM=132000     # 略多于 2^17 个周期，保证 131072 组输入全部走完

mkdir -p "$OUT"

NETLIST="$ROOT/build/dft/01_synth/${TOP}_netlist.v"
RTL_SV2V="$ROOT/build/dft/01_synth/${TOP}_sv2v.v"

if [ ! -f "$NETLIST" ] || [ ! -f "$RTL_SV2V" ]; then
  echo "缺 $NETLIST 或 $RTL_SV2V"
  echo "先跑: sh flow/dft/01_synth.sh $TOP"
  exit 1
fi

# **不用 `-l` 记录日志** —— `-l` 只收 yosys 自身脚本日志，仿真中 $display 走 stdout 会丢
# （踩过：log 里 GS 行数为 0）。也不要用 `-q`（完全静默，连 stdout 都空）。
echo "[gatesim] 1/2 门级网表（liberty 行为模型）"
yosys -Q -p "\
read_verilog $NETLIST; \
read_liberty -ignore_miss_func $LIB; \
read_verilog $TB; \
hierarchy -top tb_gatesim -check; proc; \
sim -clock clk -n $NSIM" > "$OUT/gate.log" 2>&1 || true

echo "[gatesim] 2/2 RTL 对照（sv2v 转换版）"
yosys -Q -p "\
read_verilog $RTL_SV2V; \
read_verilog $TB; \
hierarchy -top tb_gatesim -check; proc; \
sim -clock clk -n $NSIM" > "$OUT/rtl.log" 2>&1 || true

grep "\[GS\]" "$OUT/gate.log" > "$OUT/gate.trace" 2>/dev/null || true
grep "\[GS\]" "$OUT/rtl.log"  > "$OUT/rtl.trace"  2>/dev/null || true

N_GATE=$(wc -l < "$OUT/gate.trace" | tr -d ' ')
N_RTL=$(wc -l < "$OUT/rtl.trace" | tr -d ' ')
echo "[gatesim] 门级 trace $N_GATE 行 / RTL trace $N_RTL 行（含 x 检查见下）"

if [ "$N_GATE" -eq 0 ] || [ "$N_RTL" -eq 0 ]; then
  echo "[gatesim] FAIL: 未采到逐组打印，检查 $OUT/gate.log 与 $OUT/rtl.log"
  grep -m5 -E "ERROR|error" "$OUT/gate.log" 2>/dev/null || true
  exit 1
fi

# 门级输出里不应出现 x/z（组合模块在穷举激励下必须全部确定）
if grep -q "x" "$OUT/gate.trace"; then
  echo "[gatesim] FAIL: 门级输出含 x（组合模块不应有未定值）"
  grep -m3 "x" "$OUT/gate.trace" || true
  exit 1
fi

if diff -q "$OUT/rtl.trace" "$OUT/gate.trace" > /dev/null 2>&1; then
  echo "[gatesim] PASS: RTL 与门级网表逐组一致（$N_GATE 组输入穷举比对）"
  exit 0
else
  echo "[gatesim] FAIL: RTL 与门级网表输出不一致，前 20 处差异："
  diff "$OUT/rtl.trace" "$OUT/gate.trace" | head -20
  exit 1
fi
