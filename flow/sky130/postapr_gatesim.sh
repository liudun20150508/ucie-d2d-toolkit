#!/bin/bash
# =============================================================================
# postapr_gatesim.sh : ucie_ltssm 后 CTS 门级网表的 SDF 时序后仿（Icarus）
# -----------------------------------------------------------------------------
# 跑通「APR -> write_sdf -> $sdf_annotate 时序仿真」这条 需求第 4 条 的"时序仿真"链：
#   OpenROAD 已产出
#     build/sdf/ucie_ltssm_apr.v  —— 后 CTS 门级网表（含 8 个 CTS 时钟树单元）
#     build/sdf/ucie_ltssm.sdf    —— 单元延迟(liberty) + 互连延迟(RC 提取)
#   本脚本用 Icarus 13 编译网表 + 单元模型 + testbench，$sdf_annotate 反标 SDF 后仿真。
#
# 单元模型 flow/sky130/ltssm_sdf_models.v：skywater-pdk 把 .functional.v（只有功能）
#   与 .specify.v（只有 specify 片段）拆开，Icarus $sdf_annotate 需要两者合并，故自写
#   15 种单元的功能+specify 合并模型（见该文件头注释）。
#
# 判定：仿真日志里出现 "PASS: SDF 时序后仿跑通" 即通过；出现 "SDF Error" /
#   "unable to map" / "instance not found" 即反标失败。
#
# 边界（实测记录，勿虚报）：Icarus 13.0 反标的是 IOPATH(单元延迟) + INTERCONNECT
#   (互连延迟) ✅；但 $setup/$hold/$width 时序违例检查 Icarus **不支持** —— 实测
#   -g2005/-g2009/-g2012/-g2005-sv 编译均报 "Timing checks are not supported"
#   （ltssm_sdf_models.v 的 dfxtp 6 条 $setup/$hold/$width 被忽略）。故本脚本证明
#   "功能等价 + 延迟反标无误"，**不**证明"SDF 仿真里的动态 setup/hold 违例检查"。
#   ⚠ 修正记录（2026-10-12 复检）：早前写"setup/hold 违例检查需商业仿真器"是过度外推 ——
#   静态 setup/hold 违例检查本机 OpenSTA 已做（make sta，报 WNS/TNS/VIOLATED），
#   那是签核标准做法、不需要商业工具；本脚本缺的只是"动态 timing check"这一补充手段。
#
# 用法（从项目根目录）：
#   sh flow/sky130/postapr_gatesim.sh
#   make sdf   （推荐，等价）
# =============================================================================
set -euo pipefail

# 切到项目根（本脚本在 flow/sky130/ 下，上两级即根）
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

IV=iverilog
VVP=vvp
NET=build/sdf/ucie_ltssm_apr.v
SDF=build/sdf/ucie_ltssm.sdf
MODELS=flow/sky130/ltssm_sdf_models.v
TB=flow/sky130/tb_ltssm_sdf.v
OUT=build/sdf/tb_ltssm_sdf.vvp
LOG=build/sdf/sdf_gatesim.log

command -v "$IV" >/dev/null 2>&1 || { echo "[sdf] 找不到 iverilog（brew install icarus-verilog）"; exit 1; }
command -v "$VVP" >/dev/null 2>&1 || { echo "[sdf] 找不到 vvp"; exit 1; }

for f in "$NET" "$SDF" "$MODELS" "$TB"; do
  [ -f "$f" ] || { echo "[sdf] 前置缺失：$f（先跑 APR：openroad -exit flow/sky130/apr_ltssm_sdf.tcl）"; exit 1; }
done

echo "[sdf] 编译：$NET + $MODELS + $TB"
# 顺序：先 models（带 `timescale 1ns/1ps，让无 timescale 的网表继承）-> 网表 -> TB
# 关键：-gspecify —— Icarus 默认**丢弃** specify 块（$sdf_annotate 被省略），必须显式打开
$IV -gspecify -o "$OUT" "$MODELS" "$NET" "$TB" 2>"$LOG.compile" || {
  echo "[sdf] 编译失败："; cat "$LOG.compile"; exit 1;
}
[ -s "$LOG.compile" ] && { echo "[sdf] 编译告警："; cat "$LOG.compile"; }

echo "[sdf] 仿真 + SDF 反标（cwd=项目根，$SDF 相对路径在此解析）"
$VVP "$OUT" > "$LOG" 2>&1 || { echo "[sdf] 仿真异常退出，日志尾部："; tail -40 "$LOG"; exit 1; }

echo "[sdf] ------------------- 结果 -------------------"
grep -E 'PASS:|FAIL:|SDF Error|unable to map|instance not found|timing check' "$LOG" || true

if grep -q 'PASS: SDF 时序后仿跑通' "$LOG"; then
  # 反标失败会在日志里以 SDF Error 形式出现，即使功能 PASS 也要拦下来
  if grep -qE 'SDF Error|unable to map|instance not found' "$LOG"; then
    echo "[sdf] ⚠ 功能 PASS 但存在 SDF 反标错误（见上）——延迟未完整反标"
    exit 1
  fi
  echo "[sdf] ✅ 通过：完整日志见 $LOG"
else
  echo "[sdf] ❌ 失败：完整日志见 $LOG"
  exit 1
fi
