#!/bin/bash
# =============================================================================
# postapr_lec.sh : Post-APR LEC（逻辑等价检查）——综合网表 vs 布线后网表
# -----------------------------------------------------------------------------
# 方法链：综合网表(1_synth) vs 布线后网表(6_final)
#   -> 剥离物理单元(tap/fill/decap/diode) -> 写 /tmp/gold.v + /tmp/gate.v
#   -> yosys lec.ys（techmap 到 reverse_map 单元模型 -> equiv_simple/equiv_induct）
#
# ⚠ 参考脚本，不是 UCIe demo 的可执行一环：
#   本脚本针对**来源示例设计（picorv32）**，演示"APR 前后做 Yosys LEC"的完整链。
#   UCIe 链路的功能等价由 `make gatesim`（RTL vs 门级 2^17 穷举比对）覆盖，
#   时序后仿等价由 `make sdf`（SDF 反标）覆盖，不需要本脚本。
#   要复现本脚本，需自备 OpenROAD-flow-scripts 环境与 picorv32 的 APR 结果，
#   通过下面三个环境变量指定（原脚本写死来源机器路径，已脱敏）：
#     export OFS_FLOW=/path/to/OpenROAD-flow-scripts/flow
#     export LEC_RESULTS=$OFS_FLOW/results/sky130hd/picorv32/base   # 可选
#     export YOSYS=/path/to/yosys                                     # 可选
# =============================================================================
set -e
FLOW=${OFS_FLOW:?需自备 OpenROAD-flow-scripts/flow（export OFS_FLOW=...）}
RES=${LEC_RESULTS:-$FLOW/results/sky130hd/picorv32/base}
YOSYS=${YOSYS:-yosys}
LEGY=$(cd "$(dirname "$0")" && pwd)

strip_phys() {
  # remove instances of physical-only cells
  sed -E '/sky130_fd_sc_hd__(tapvpwrvgnd_1|fill_[0-9]+|decap_[0-9]+|diode_[0-9]+)/d' "$1"
}
strip_phys "$RES/1_2_yosys.v" | sed 's/^module picorv32/module gold/' > /tmp/gold.v
strip_phys "$RES/6_final.v"   | sed 's/^module picorv32/module gate/' > /tmp/gate.v
grep -c "^module" /tmp/gold.v /tmp/gate.v
"$YOSYS" -s "$LEGY/lec.ys" 2>&1 | tee /tmp/lec_postapr.log | tail -6
