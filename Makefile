# =============================================================================
# ucie-d2d-toolkit : Chiplet D2D / UCIe 数字链路 demo —— 构建与验证流程
# -----------------------------------------------------------------------------
# 目标：
#   make lint   Verilator -Wall 静态检查（默认顶层 = ucie_d2d_top）
#   make crc    CRC-16 单模块自检（标准向量 0x29B1）
#   make smoke  工具链自检（纯 SV 测试台 + SVA 断言）
#   make test   主仿真：训练 / 端到端通路 / 误码重传 / lane 修复 / 重训练
#   make wave   打开 VCD 波形
#   make clean  清理构建产物
#
# 全部在本机 macOS(arm64) 跑通，不依赖商业 EDA：
#   verilator 5.x + 系统 C++ 编译器即可。综合/时序见 flow/（yosys + OpenSTA）。
# =============================================================================
SHELL   := /bin/bash
BUILD   := build
WAVES   := waves

PKG     := rtl/pkg/ucie_pkg.sv
LINK    := rtl/link/ucie_crc16.sv rtl/link/ucie_flit_tx.sv rtl/link/ucie_flit_rx.sv \
           rtl/link/ucie_link_retry.sv rtl/link/ucie_dll.sv
PHY     := rtl/phy/ucie_deskew.sv rtl/phy/ucie_ltssm.sv rtl/phy/ucie_lane_repair.sv rtl/phy/ucie_rdi.sv \
           rtl/phy/ucie_link_pipe.sv rtl/phy/ucie_mgmt.sv
CDC     := rtl/cdc/ucie_afifo.sv
TOP     := rtl/top/ucie_d2d_top.sv
TB      := sim/verilator/tb_ucie_top.sv
ALL_RTL := $(PKG) $(LINK) $(PHY) $(CDC) $(TOP)

# --- 协议层（AXI4 over UCIe）---
PROTO   := rtl/proto/ucie_axi_pkg.sv rtl/proto/ucie_stream_pack.sv rtl/proto/ucie_stream_unpack.sv \
           rtl/proto/ucie_axi_slv_tx.sv rtl/proto/ucie_axi_slv_rx.sv \
           rtl/proto/ucie_axi_mst_tx.sv rtl/proto/ucie_axi_mst_rx.sv \
           rtl/proto/ucie_axi_slv_bridge.sv rtl/proto/ucie_axi_mst_bridge.sv
AXI_TOP := rtl/top/ucie_axi_d2d_top.sv
AXI_TB  := sim/verilator/tb_axi_top.sv
ALL_AXI := $(PKG) $(PROTO) $(LINK) $(PHY) $(CDC) $(TOP) $(AXI_TOP)

# --- deskew 单元验证 ---
TB_DESKEW := sim/verilator/tb_deskew.sv

# --- 管理通道验证（自定版，非 UCIe 2.0 合规实现）---
TB_MGMT   := sim/verilator/tb_mgmt.sv

# --- 低功耗验证（数据门控双版本对比）---
TB_LOWPOWER := sim/verilator/tb_lowpower.sv

VFLAGS  := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
           -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
           -Wno-CASEINCOMPLETE
VLOG    := verilator $(VFLAGS)

.PHONY: all dirs lint crc smoke test test-axi uvm wave synth sta sdf dft dft-flow deskew lowpower gatesim mgmt clean

all: dirs lint crc test

dirs:
	@mkdir -p $(BUILD) $(WAVES)

# -----------------------------------------------------------------------------
# 静态检查
# -----------------------------------------------------------------------------
lint: dirs
	@$(VLOG) --lint-only --top-module ucie_d2d_top $(ALL_RTL) > $(BUILD)/lint.log 2>&1 \
	  && echo "lint  : OK  (ucie_d2d_top, $(words $(ALL_RTL)) 个源文件)"
	@for m in ucie_flit_tx ucie_flit_rx ucie_link_retry ucie_dll ucie_ltssm \
	          ucie_lane_repair ucie_rdi_tx ucie_rdi_rx ucie_afifo ucie_link_pipe \
	          ucie_deskew ucie_mgmt; do \
	  src="$(ALL_RTL)"; \
	  printf "  %-18s" $$m; \
	  $(VLOG) --lint-only --top-module $$m $$src > /dev/null 2>&1 && echo "OK" || echo "FAIL"; \
	done

# -----------------------------------------------------------------------------
# CRC-16 算法自检（标准向量）
# -----------------------------------------------------------------------------
crc: dirs
	@$(VLOG) --binary --timing -Wno-fatal -DUCIE_CRC16_SELFCHECK --top-module ucie_crc16 \
	  --Mdir $(BUILD)/obj_crc -o crc_selfcheck $(PKG) rtl/link/ucie_crc16.sv \
	  > $(BUILD)/crc_build.log 2>&1
	@./$(BUILD)/obj_crc/crc_selfcheck

# -----------------------------------------------------------------------------
# 工具链自检
# -----------------------------------------------------------------------------
smoke: dirs
	@$(VLOG) --binary --timing --assert -Wno-fatal --top-module tb_smoke \
	  --Mdir $(BUILD)/obj_smoke -o tb_smoke sim/verilator/smoke/tb_smoke.sv \
	  > $(BUILD)/smoke_build.log 2>&1
	@./$(BUILD)/obj_smoke/tb_smoke

# -----------------------------------------------------------------------------
# 主仿真（VCD 落在 waves/ucie_d2d_top.vcd）
# -----------------------------------------------------------------------------
test: dirs
	@$(VLOG) --binary --timing --assert --trace -Wno-fatal --top-module tb_ucie_top \
	  --Mdir $(BUILD)/obj_top -o tb_ucie_top $(ALL_RTL) $(TB) \
	  > $(BUILD)/verilator_build.log 2>&1
	@./$(BUILD)/obj_top/tb_ucie_top

# -----------------------------------------------------------------------------
# AXI4 over UCIe 仿真（协议层 demo：单拍/突发/多 ID 读/误码下读写）
# -----------------------------------------------------------------------------
test-axi: dirs
	@$(VLOG) --binary --timing --assert --trace -Wno-fatal --top-module tb_axi_top \
	  --Mdir $(BUILD)/obj_axi -o tb_axi_top $(ALL_AXI) $(AXI_TB) \
	  > $(BUILD)/axi_build.log 2>&1
	@./$(BUILD)/obj_axi/tb_axi_top

wave:
	@test -f $(WAVES)/ucie_d2d_top.vcd && gtkwave $(WAVES)/ucie_d2d_top.vcd || \
	  echo "还没有波形，先跑 make test"

# -----------------------------------------------------------------------------
# DFT 轻量检查（scan-ready + 扫描链规划 + 翻转覆盖率），详见 docs/DFT.md §1-§7
# -----------------------------------------------------------------------------
dft: dirs
	@python3 scripts/dft_check.py --json $(BUILD)/dft_report.json

# -----------------------------------------------------------------------------
# DFT 完整流程：综合 -> mux-D 扫描链插入 -> ATPG -> 真实故障覆盖率
#   移植自既有后端项目的 DFT 流程（原 SKY130 + tinyNPU），适配 UCIe 子模块 + Nangate45
#   详见 docs/DFT.md §8；产出 build/dft/{01_synth,02_scan,03_atpg}/
#   用法：make dft-flow                      （默认 ucie_ltssm）
# -----------------------------------------------------------------------------
DFT_TOP ?= ucie_ltssm

dft-flow: dirs
	@echo "[DFT 1/4] 综合 $(DFT_TOP) 到 Nangate45 门级网表"
	@sh flow/dft/01_synth.sh $(DFT_TOP)
	@echo "[DFT 2/4] mux-D 扫描链插入 + 链完整性验证（yosys 门级仿真）"
	@DFT_TOP=$(DFT_TOP) python3 flow/dft/02_scan_insert.py | grep -E "^\[02\]"
	@echo "[DFT 3/4] ATPG 引擎自检（PODEM vs 暴力穷举交叉验证）"
	@DFT_TOP=$(DFT_TOP) python3 flow/dft/03_atpg.py --selftest
	@echo "[DFT 4/4] ATPG + 故障覆盖率"
	@DFT_TOP=$(DFT_TOP) python3 flow/dft/03_atpg.py --npat 512 > $(BUILD)/dft/03_atpg/run.log 2>&1
	@echo "  完成，结果见 build/dft/03_atpg/atpg_results.json"

# -----------------------------------------------------------------------------
# deskew 单元验证（lane 间时序对齐：偏斜测量 → 对齐 → 旁路 → 重测）
#   对应能力点 3「时序对齐」，详见 docs/VERIFICATION.md §5e
# -----------------------------------------------------------------------------
deskew: dirs
	@$(VLOG) --binary --timing -Wno-fatal --top-module tb_deskew \
	  --Mdir $(BUILD)/obj_deskew -o tb_deskew \
	  $(PKG) rtl/phy/ucie_deskew.sv $(TB_DESKEW) \
	  > $(BUILD)/deskew_build.log 2>&1
	@./$(BUILD)/obj_deskew/tb_deskew

# -----------------------------------------------------------------------------
# 低功耗验证（数据门控：GATING=0 基线 vs GATING=1 门控，双 DUT 并列对比）
#   对应能力点 5「低功耗设计」；方法取自既有项目的 tb_tcu_gate.sv
# -----------------------------------------------------------------------------
lowpower: dirs
	@$(VLOG) --binary --timing -Wno-fatal --top-module tb_lowpower \
	  --Mdir $(BUILD)/obj_lp -o tb_lowpower \
	  $(PKG) rtl/phy/ucie_rdi.sv $(TB_LOWPOWER) \
	  > $(BUILD)/lowpower_build.log 2>&1
	@./$(BUILD)/obj_lp/tb_lowpower

# -----------------------------------------------------------------------------
# 门级仿真（零延时）：同一 TB 分别接 RTL(sv2v) 与门级网表，穷举 2^17 组比对
#   意义：证明综合（RTL -> 门级网表）**未改变功能** —— 只跑门级自己看不够，
#         必须有 RTL 侧对照。
#   边界：**零延时、无 SDF 反标**，因此只验证功能等价，**不验证时序**；
#         带 SDF 的时序后仿见 `make sdf`（SKY130 APR -> write_sdf -> $sdf_annotate）。
#   ⚠ 修正记录（2026-10-12 复检）：早前写"本机不具备 SDF 条件"是错的 ——
#         本机用 OpenROAD write_sdf + Icarus $sdf_annotate 已跑通时序后仿，
#         见 flow/sky130/postapr_gatesim.sh 与 make sdf。
#   前置：build/dft/01_synth/ 下的网表与 sv2v 源。注意 make dft-flow 的默认载体是
#         ucie_ltssm，**不生成** ucie_lane_repair 的网表，所以下面要自动补齐 ——
#         否则 make clean 之后直接跑本目标会缺文件失败
#         （实测：EXITCODE=2，提示先跑 01_synth.sh）。
#
#   ⚠ 修正记录（2026-10-11 复检发现）：早前版本写的是
#        gatesim: dirs build/dft/01_synth/ucie_lane_repair_netlist.v
#        build/dft/01_synth/ucie_lane_repair_netlist.v:
#            ... 生成前置 + 跑 run_gatesim.sh
#      把"跑仿真"挂在**前置文件**的规则体里 → 前置已存在时 make 判定目标已最新，
#      **整个目标静默变成空操作（exit 0、无输出、不跑任何仿真）**。
#      现场演示 `make gatesim` 会什么都不证明。改成 phony 目标 + shell 内判前置。
# -----------------------------------------------------------------------------
gatesim: dirs
	@if [ ! -f build/dft/01_synth/ucie_lane_repair_netlist.v ]; then \
	  echo "[gatesim] 前置缺失，先生成 ucie_lane_repair 网表"; \
	  sh flow/dft/01_synth.sh ucie_lane_repair > $(BUILD)/gatesim_prereq.log 2>&1 || { \
	    echo "  前置生成失败，见 $(BUILD)/gatesim_prereq.log"; exit 1; }; \
	fi
	@sh flow/gatesim/run_gatesim.sh

# -----------------------------------------------------------------------------
# UVM 风格分层验证环境（driver/monitor/scoreboard/coverage + 随机激励）
#   对应能力点 4「模块级、系统级验证方案」；详见 sim/uvm_style/README.md
#   用法： make uvm            （默认 20 笔随机）
#          make uvm UVM_N=100 （指定随机笔数）
# -----------------------------------------------------------------------------
UVM_N ?= 20

uvm: dirs
	@sh sim/uvm_style/run.sh $(UVM_N)

# -----------------------------------------------------------------------------
# 后端衔接（详见 flow/ 与 docs/BACKEND.md）
# -----------------------------------------------------------------------------
synth: dirs
	@echo "综合见 flow/synth.tcl（yosys + sky130/nangate45）"
	@cd flow && $(MAKE) synth

sta: dirs
	@cd flow && $(MAKE) sta

# -----------------------------------------------------------------------------
# SDF 时序后仿（SKY130 后 CTS 门级网表 + write_sdf 反标）
#   对应能力点 4 的「时序仿真」：APR -> write_sdf -> Icarus $sdf_annotate。
#   链：openroad apr_ltssm_sdf.tcl 产出 build/sdf/{ucie_ltssm_apr.v, ucie_ltssm.sdf}
#       -> postapr_gatesim.sh 用 -gspecify 编译并反标后仿真。
#   边界（实测记录）：Icarus 13.0 反标 IOPATH(单元延迟)+INTERCONNECT(互连延迟) ✅；
#       但不支持 $setup/$hold/$width **动态** timing check —— 实测 -g2005/-g2009/-g2012/
#       -g2005-sv 均报 "Timing checks are not supported"（开源仿真的已知边界）。
#       ⚠ 别外推成"setup/hold 违例检查必须商业"：**静态** setup/hold 违例检查本机
#       OpenSTA 已做（make sta，报 WNS/TNS/VIOLATED，签核标准）；这里缺的只是
#       SDF 反标仿真里的**动态** timing check，属补充手段、非签核必需。
#   前置：build/sdf/ 产物（未生成时脚本会提示先跑 openroad apr_ltssm_sdf.tcl）。
# -----------------------------------------------------------------------------
sdf: dirs
	@sh flow/sky130/postapr_gatesim.sh

# -----------------------------------------------------------------------------
# 管理通道骨架验证（自定版：据 UCIe 2.0 公开白皮书的机制清单自行实现，
#   **非规范合规实现**；覆盖 discovery / status query / error reporting）
#   详见 rtl/phy/ucie_mgmt.sv 头部声明、sim/verilator/tb_mgmt.sv
# -----------------------------------------------------------------------------
mgmt: dirs
	@$(VLOG) --binary --timing --assert -Wno-fatal --top-module tb_mgmt \
	  --Mdir $(BUILD)/obj_mgmt -o tb_mgmt $(ALL_RTL) $(TB_MGMT) \
	  > $(BUILD)/mgmt_build.log 2>&1
	@./$(BUILD)/obj_mgmt/tb_mgmt

clean:
	rm -rf $(BUILD) $(WAVES) obj_dir
