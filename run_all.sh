#!/bin/bash
# =============================================================================
# run_all.sh : 一键跑通完整方法链（安装 → 功能验证 → 综合/STA → DFT → SDF 后仿）
# -----------------------------------------------------------------------------
# 用法：
#   sh run_all.sh               # 全流程（含后端：综合/STA/DFT/SDF）
#   sh run_all.sh --skip-backend  # 只跑功能验证（lint/仿真/UVM），跳过后端
#
# 等价于按序执行 README「快速开始」里的所有 make 目标，最后打印关键产物汇总。
# 后端目标依赖 sv2v / yosys / opensta / openroad / iverilog，缺了先 sh install.sh。
# =============================================================================
set -e
SKIP_BACKEND=0
[ "$1" = "--skip-backend" ] && SKIP_BACKEND=1

step() {
  echo
  echo "============================================================"
  echo "▶ $1"
  echo "============================================================"
}

step "0/6 依赖安装 + 环境自检（缺哪个自动 brew install）"
sh install.sh

step "1/6 静态检查 + CRC-16 自检 + 主仿真（训练/通路/误码重传/lane 修复/重训练）"
make all

step "2/6 AXI4-over-UCIe 协议层仿真（单拍/突发/多 ID 读/误码读写）"
make test-axi

step "3/6 UVM 风格分层验证（随机激励 + covergroup 覆盖率）"
make uvm

if [ "$SKIP_BACKEND" = "1" ]; then
  echo
  echo "已跳过后端流程（--skip-backend）。"
else
  step "4/6 综合 + 静态时序签核（sv2v → yosys → OpenSTA，报 WNS/TNS）"
  (cd flow && make all)

  step "5/6 DFT：综合 → mux-D 扫描链插入 → 自研 ATPG → 真实故障覆盖率"
  make dft-flow

  step "6/6 SDF 时序后仿（SKY130 APR → write_sdf → Icarus \$sdf_annotate）"
  make sdf
fi

echo
echo "============================================================"
echo "✅ 全流程完成。关键产物："
echo "  仿真波形       waves/ucie_d2d_top.vcd"
echo "  时序报告       results/sta/sta.log (stat.rpt)"
echo "  故障覆盖率     build/dft/03_atpg/atpg_results.json"
echo "  SDF 后仿日志   results/sdf/sdf_gatesim.log"
echo "============================================================"
