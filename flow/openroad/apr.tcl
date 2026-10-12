# =============================================================================
# apr.tcl : ucie-d2d-demo 的 APR 起点（OpenROAD，纯开源，本机 arm64 可跑）
# -----------------------------------------------------------------------------
# 目的：验证「布局布线这一段到底要不要服务器」。
# 这里的脚本只做到 **floorplan + 全局/详细布局 + 面积报告**，
# 把网表变成有物理位置的 DEF —— 这一步能跑通，就说明 APR 的前半段
# 在 M1 上是可行的；完整的 CTS/布线/签核需要更长时间与更多配置。
#
# 用法：
#   cd flow/openroad && openroad -exit apr.tcl
#
# 工艺：Nangate45（FreePDK45），库文件取自本机 OpenROAD 自带的 test 库，
#       保证与 flow/Makefile 综合时用的 NangateOpenCellLibrary_typical.lib 同源。
# =============================================================================

# ⚠ 修正记录（2026-10-11 复检发现）：下面三处原先把顶层名写死成 ucie_d2d_top
#   （NET 路径、link_design、write_def 的文件名），于是
#       cd flow && make apr TOP=ucie_axi_d2d_top
#   **不会报错、也不会换设计** —— 它照样对 ucie_d2d_top 跑完 APR 并 exit 0，
#   现场看起来"AXI 顶层的布局也跑通了"，其实跑的是别的网表。
#   同一类坑在本项目出现过两次（见 Makefile 的 gatesim 修正记录）：
#   **参数传了但没人用，失败是静默的。**
#   现在用 UCIE_TOP 环境变量（由 flow/Makefile 的 apr 目标从 TOP 传入）覆盖。
set TOP   [expr {[info exists env(UCIE_TOP)] ? $env(UCIE_TOP) : "ucie_d2d_top"}]
set ROOT  [file normalize [file dirname [info script]]/../..]

set PDK   $ROOT/resources/nangate45
set LIB   $ROOT/resources/nangate45/NangateOpenCellLibrary_typical.lib
set NET   ../../build/syn/${TOP}_sta.v
set OUT   ../../build/syn
puts "== APR 目标顶层：$TOP（网表 $NET）"

puts "== 读入 LEF（tech + stdcell）"
read_lef $PDK/Nangate45_tech.lef
read_lef $PDK/Nangate45_stdcell.lef

puts "== 读入 lib / 网表"
read_liberty $LIB
read_verilog $NET
link_design $TOP

puts "== 时序约束：直接复用 flow/ucie.sdc"
# 原先此处手写 create_clock，只建了两个时钟，缺 set_input_delay / set_max_delay /
# set_clock_groups —— 那样 repair 的判定口径与 `make sta` 的报告口径不一致，无法对比。
# 改为 source 同一份 SDC（apr.tcl 的 cwd 是 flow/openroad，故路径为 ../ucie.sdc）。
source ../ucie.sdc

# repair_timing 需要互连 RC 来估算线延迟，否则报
#   [ERROR RSZ-0089] Could not find a resistance value for any corner.
# 本项目未做 RC 提取，这里用 Nangate45 的默认层 RC
# （信号走 metal3、时钟走 metal5，与后端常规选择一致）。
set_wire_rc -signal -layer metal3
set_wire_rc -clock  -layer metal5

puts "== Floorplan"
# utilization 给得宽松一些：本设计寄存器阵列占比高，太挤会导致布局失败
initialize_floorplan -utilization 35 -aspect_ratio 1.0 -core_space 2.0 \
    -site FreePDK45_38x28_10R_NP_162NW_34O
make_tracks

puts "== 引脚摆放"
place_pins -hor_layers metal3 -ver_layers metal2

puts "== 全局布局"
global_placement -density 0.60

puts "== 详细布局"
detailed_placement
check_placement

puts ""
puts "==================== 时序：repair 前 ===================="
report_worst_slack -max
report_tns

# ---------------------------------------------------------------------------
# 为什么这里必须 repair_design：
#   综合（yosys + abc）**不做 buffer 插入与逻辑复制**，高扇出 net 会直接把负载
#   压在一个门上。本项目实测：网表内排除时钟/复位后仍有 **203 个 net 扇出 >100**
#   （最高 1100），其中一个 559 扇出的 net 使 NOR4 单级延迟达 11.362 ns、AOI21 达
#   9.036 ns（Nangate45 正常 0.1–0.2 ns）—— 这才是 `make sta` 报 WNS −71.25 ns 的
#   根因，与 CRC 组合链、RDI 地址链无关（那两处只是结构描述，不是延迟来源）。
#   高扇出/驱动能力是物理实现问题，改 RTL 解决不了；正确手段就是这里的
#   repair_design（插 buffer、复制扇出、修 max transition/capacitance）
#   + repair_timing（sizing 与重组，修 setup）。
# ---------------------------------------------------------------------------
puts "== repair_design（修 max transition / capacitance，插 buffer、复制高扇出）"
repair_design

# 只修 setup：本流程**未做 CTS**，时钟树还不存在，此时的 hold 违例没有意义。
# 实测（无参数调用）会连 hold 一起修：插了 38871 个 hold buffer 仍报
#   [WARNING RSZ-0066] Unable to repair all hold violations
# 最后撞上 [ERROR RSZ-0060] Max buffer count reached，把整个脚本带崩 ——
# 于是 repair 后的 slack 与 write_def 都跑不到。hold 应留到 CTS 之后修。
puts "== repair_timing -setup（只修 setup；hold 留到 CTS 之后）"
repair_timing -setup

puts ""
puts "==================== 时序：repair 后 ===================="
report_worst_slack -max
report_tns

puts ""
puts "==================== APR 阶段结果 ===================="
report_design_area
puts "======================================================"

write_def $OUT/${TOP}_placed.def
puts "已写出布局结果：$OUT/${TOP}_placed.def"
