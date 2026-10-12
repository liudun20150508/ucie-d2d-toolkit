# =============================================================================
# ucie-d2d-demo / flow : 综合 + 时序签核（RTL2GDS 的前半段，全开源工具链）
# -----------------------------------------------------------------------------
# 复用了本机已有的开源后端环境（与两个既有后端项目同源）：
#   sv2v      : SystemVerilog -> Verilog-2001（yosys 的 SV 前端对 package/struct
#               支持有限，先降级更稳）
#   yosys     : 综合 + 工艺映射（Nangate45 或 sky130_fd_sc_hd）
#   OpenSTA   : 时序签核（读网表 + liberty + SDC，报 WNS/TNS/违例路径）
#
# 目标：
#   make synth   综合并输出门级网表 + 面积/单元统计
#   make sta     时序签核（依赖 synth 产物）
#   make all     两者都跑
#   make clean
#
# 说明：这是**本机 macOS(arm64) 可行性验证**，不是流片签核流程：
#   仿真/综合/STA 可本地闭环；商业 APR、DFT(Tessent)、Calibre PV、emulator、
#   真实 D2D PHY 数模混合仿真需要服务器/商业工具，见 ../docs/BACKEND.md。
# =============================================================================
SHELL   := /bin/bash
ROOT    := ..
RTLDIR  := $(ROOT)/rtl
BUILD   := $(ROOT)/build/syn
# TOP：默认纯链路顶层；带 AXI 协议层的顶层用 make TOP=ucie_axi_d2d_top
#
# ⚠ 踩坑记录（2026-10-11 复检发现并修复）：这行原来是
#     TOP     ?= ucie_d2d_top   # 可用 make TOP=ucie_axi_d2d_top 选带 AXI 协议层的顶层
#   行内注释**前面**的空格会进入变量值（make 只截掉 `#` 及其后内容，不截前面的空白），
#   于是 `$(BUILD)/$(TOP)_sv2v.v` 展开成 `../build/syn/ucie_d2d_top   _sv2v.v`，
#   被 shell 按空格拆成两个参数 —— sv2v 实际收到的是：
#     --write "../build/syn/ucie_d2d_top"
#   直接报错：invalid --write "...", expected stdout, adjacent, a path ending in .v,
#             or a path to an existing directory
#   现象：`cd flow && make synth`（以及 make all / make sta）**必失败**——
#   而这正是 README 与 docs/BACKEND.md 给出的复现命令。
#   注意：`make synth TOP=xxx` 从命令行传参时不带尾随空格，所以能跑通 ——
#   这个 bug 只在用**默认 TOP**时暴露。
#   教训：**赋值行里不要写行内注释**，注释另起一行。
TOP     ?= ucie_d2d_top

# yosys/abc 会在 $TMPDIR 下建工作目录做原子 rename。会话级临时目录
# （macOS 的 /var/folders/... 会话 TMPDIR）实测会失败，表现为
#   "ABC: failed to rename ... .tmp ..." + "Can't open ABC output file"。
# 统一指到 build 下，既绕开问题又方便清理。
export TMPDIR := $(abspath $(BUILD))/tmp

PDK_ROOT    ?= $(ROOT)/resources
SKY130_LIB  ?= $(PDK_ROOT)/sky130/sky130_fd_sc_hd__tt_025C_1v80.lib
NANGATE_LIB ?= $(PDK_ROOT)/nangate45/NangateOpenCellLibrary_typical.lib

# 默认优先 Nangate45（本机已验证能跑通 abc 工艺映射）。
# sky130_fd_sc_hd 在这条 yosys/abc 链路上会卡在 liberty->scl 转换
# （"ABC: Merged scl conversion failed" 之后 "Can't open ABC output file"），
# 需要时显式指定： make synth LIB=$(SKY130_LIB)
LIB ?= $(shell [ -f "$(NANGATE_LIB)" ] && echo $(NANGATE_LIB) || echo $(SKY130_LIB))

# PERIOD：lclk 周期（ns），10.0 ns = 100 MHz。
# 同样不留行内注释（见上面 TOP 的踩坑记录）：本行的尾随空格只会让
# `abc -D $(PERIOD)` 收到 "10.0    "（abc 按 token 解析，实测无故障），
# 但没必要留这个隐患。
PERIOD  := 10.0

SRCS := $(RTLDIR)/pkg/ucie_pkg.sv \
        $(RTLDIR)/link/ucie_flit_tx.sv $(RTLDIR)/link/ucie_flit_rx.sv \
        $(RTLDIR)/link/ucie_link_retry.sv $(RTLDIR)/link/ucie_dll.sv \
        $(RTLDIR)/phy/ucie_ltssm.sv $(RTLDIR)/phy/ucie_lane_repair.sv \
        $(RTLDIR)/phy/ucie_rdi.sv $(RTLDIR)/phy/ucie_link_pipe.sv $(RTLDIR)/phy/ucie_deskew.sv \
        $(RTLDIR)/phy/ucie_mgmt.sv \
        $(RTLDIR)/cdc/ucie_afifo.sv $(RTLDIR)/top/ucie_d2d_top.sv \
        $(RTLDIR)/proto/ucie_axi_pkg.sv $(RTLDIR)/proto/ucie_stream_pack.sv \
        $(RTLDIR)/proto/ucie_stream_unpack.sv \
        $(RTLDIR)/proto/ucie_axi_slv_tx.sv $(RTLDIR)/proto/ucie_axi_slv_rx.sv \
        $(RTLDIR)/proto/ucie_axi_mst_tx.sv $(RTLDIR)/proto/ucie_axi_mst_rx.sv \
        $(RTLDIR)/proto/ucie_axi_slv_bridge.sv $(RTLDIR)/proto/ucie_axi_mst_bridge.sv \
        $(RTLDIR)/top/ucie_axi_d2d_top.sv

.PHONY: all dirs check synth sta power apr clean

all: synth sta

dirs:
	@mkdir -p $(BUILD) $(BUILD)/tmp

check:
	@command -v sv2v >/dev/null || { echo "缺 sv2v（brew install sv2v）"; exit 1; }
	@command -v yosys >/dev/null || { echo "缺 yosys"; exit 1; }
	@test -f "$(LIB)" || { echo "找不到工艺库: $(LIB)"; exit 1; }
	@echo "综合库: $(LIB)"

# -----------------------------------------------------------------------------
# 综合：SV -> Verilog-2001 -> 工艺映射
# -----------------------------------------------------------------------------
synth: dirs check
	@echo "[sv2v] SystemVerilog -> Verilog-2001"
	@sv2v -w $(BUILD)/$(TOP)_sv2v.v $(SRCS) 2> $(BUILD)/sv2v.log \
	  || { echo "sv2v 失败，见 $(BUILD)/sv2v.log"; tail -20 $(BUILD)/sv2v.log; exit 1; }
	@echo "[yosys] 综合 + 映射（period=$(PERIOD) ns）"
	@# async2sync：把异步复位 FF 转成同步复位形式再映射。
	@# 原因：本 demo 的 RTL 全部用异步低有效复位（always_ff @(posedge clk or negedge rst_n)），
	@# 而通用映射链路里 dfflegalize 不接受 $_DFF_PN0_ 这类异步复位 FF。
	@# 真实项目里两种做法都常见：要么库里有带 async reset 的 DFF 直接映射，
	@# 要么在此处/前端做复位同步化——后者对 STA 与 DFT 更友好。
	@yosys -q -l $(BUILD)/synth.log -p "\
	  read_liberty -lib $(LIB); \
	  read_verilog $(BUILD)/$(TOP)_sv2v.v; \
	  hierarchy -check -top $(TOP); \
	  proc; async2sync; opt; fsm; opt; wreduce; share; opt; \
	  memory_dff; opt; memory_map; opt; techmap; opt; \
	  dfflibmap -liberty $(LIB); \
	  abc -D $(PERIOD) -liberty $(LIB); \
	  setundef -zero; opt_clean; \
	  write_verilog -noattr -noexpr $(BUILD)/$(TOP)_mapped.v; \
	  tee -o $(BUILD)/stat.rpt stat" 2>&1 | tail -5
	@echo ""
	@echo "=== 面积 / 单元统计（直接从门级网表统计）==="
	@echo -n "  单元实例总数 : "; grep -cE "^  [A-Z][A-Za-z0-9_]+ " $(BUILD)/$(TOP)_mapped.v
	@echo "  单元种类 TOP6 :"; grep -oE "^  [A-Z][A-Za-z0-9_]+" $(BUILD)/$(TOP)_mapped.v | tr -d ' ' | sort | uniq -c | sort -rn | head -6 | sed 's/^/    /'
	@echo "网表: $(BUILD)/$(TOP)_mapped.v  ($(shell wc -l < $(BUILD)/$(TOP)_mapped.v 2>/dev/null) 行)"

# -----------------------------------------------------------------------------
# 时序签核：OpenSTA
# -----------------------------------------------------------------------------
sta: dirs
	@test -f $(BUILD)/$(TOP)_mapped.v || { echo "先跑 make synth"; exit 1; }
	@# 网表清洗：OpenSTA 的 Verilog 前端不接受 net 声明里的 `signed`，
	@# 而 yosys 会为 sv2v 从 SystemVerilog 的 integer 变量（for 循环计数器）
	@# 生成 `wire signed [31:0] ...`。这些位不在时序路径上，去掉 signed 即可。
	@sed 's/wire signed/wire/g' $(BUILD)/$(TOP)_mapped.v > $(BUILD)/$(TOP)_sta.v
	@echo "[OpenSTA] 时序签核（读 $(TOP)_sta.v）"
	@UCIE_LIB=$(LIB) UCIE_NET=$(BUILD)/$(TOP)_sta.v UCIE_TOP=$(TOP) \
	  UCIE_SDC=ucie.sdc UCIE_OUT=$(BUILD) \
	  sta -no_init -exit sta.tcl 2>&1 | tee $(BUILD)/sta.log

# -----------------------------------------------------------------------------
# 功耗估算（OpenSTA report_power + 仿真 VCD 活动率）
#   不需要 ptpx、也不需要真实设备：单元功耗表(liberty) + 实测翻转率(VCD)
#   依赖：先 make synth（要 $(TOP)_sta.v）；VCD 由主仿真 make test 生成
#   用法：make power
#         cd flow && make power TOP=ucie_axi_d2d_top \
#             UCIE_VCD=../waves/ucie_axi_d2d_top.vcd POWER_SCOPE=tb_axi_top.u_dut
# -----------------------------------------------------------------------------
UCIE_VCD    ?= ../waves/ucie_d2d_top.vcd
# ⚠ POWER_SCOPE 必须填 **VCD 的顶层名**（不是 DUT 实例路径）：
#   填 tb_ucie_top.u_dut 会得到 "Annotated 0 pin activities"（实测踩过）。
POWER_SCOPE ?= tb_ucie_top

power: dirs
	@test -f $(BUILD)/$(TOP)_sta.v || { echo "先跑 make synth"; exit 1; }
	@test -f $(UCIE_VCD) || { echo "找不到 VCD: $(UCIE_VCD)（先跑 make test 生成波形）"; exit 1; }
	@echo "[OpenSTA] 功耗估算（$(TOP)_sta.v + VCD 活动率）"
	@UCIE_LIB=$(LIB) UCIE_NET=$(BUILD)/$(TOP)_sta.v UCIE_TOP=$(TOP) \
	  UCIE_SDC=ucie.sdc UCIE_OUT=$(BUILD) \
	  UCIE_VCD=$(abspath $(UCIE_VCD)) UCIE_VCD_SCOPE=$(POWER_SCOPE) \
	  sta -no_init -exit power.tcl 2>&1 | tee $(BUILD)/power.log

# -----------------------------------------------------------------------------
# APR 起点：OpenROAD（本机 arm64 原生）
#   apr.tcl 做到 floorplan + 全局/详细布局并写出 DEF。
#   实测：189348 个标准单元实例（其中 DFF_X1 14920），61 秒，
#         设计面积 371170 um^2 @35% 利用率，HPWL legalize 后 +6%。
#   CTS / 布线 / 签核 未包含——耗时长，见 docs/BACKEND.md。
# -----------------------------------------------------------------------------
apr: dirs
	@test -f $(BUILD)/$(TOP)_sta.v || { echo "先跑 make synth"; exit 1; }
	@echo "[OpenROAD] floorplan + 布局（顶层 $(TOP)）"
	@# 注意：这里 cd 进了 openroad/，日志路径必须用绝对路径，
	@# 否则相对路径会解析成 flow/openroad/../build/... 而目录不存在。
	@# UCIE_TOP 必须显式传下去：apr.tcl 原先写死顶层名，
	@# `make apr TOP=xxx` 会静默地对旧的 ucie_d2d_top 跑完（详见 apr.tcl 头部修正记录）。
	@cd openroad && UCIE_TOP=$(TOP) openroad -exit apr.tcl 2>&1 | tee $(abspath $(BUILD))/apr.log

clean:
	rm -rf $(BUILD)
