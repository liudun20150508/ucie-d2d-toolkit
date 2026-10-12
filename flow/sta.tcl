# =============================================================================
# sta.tcl : OpenSTA 时序签核脚本（由 flow/Makefile 通过环境变量传参）
# -----------------------------------------------------------------------------
# 检查内容：
#   1. 建立/保持时序（max/min path）与 WNS / TNS
#   2. 关键路径明细（看组合 CRC 这条深逻辑链是不是真的成了瓶颈）
#   3. 时序违例汇总
#
# 这里刻意不“美化”结果：组合展开的 CRC 必然时序很差，正好用来演示
# 「RTL 能跑通 ≠ 时序收敛」以及后端的优化手段（打拍/流水化）。
# =============================================================================

set lib  $::env(UCIE_LIB)
set net  $::env(UCIE_NET)
set top  $::env(UCIE_TOP)
set sdc  $::env(UCIE_SDC)
set out  $::env(UCIE_OUT)

puts "== 读入工艺库：$lib"
read_liberty $lib

puts "== 读入门级网表：$net"
read_verilog $net

puts "== 链接设计：$top"
link_design $top

puts "== 读入约束：$sdc"
read_sdc $sdc

puts ""
puts "==================== 签核结果 ===================="
puts "-- 最差建立时序（WNS / TNS）"
report_worst_slack -max
report_tns

puts ""
puts "-- 最差保持时序"
report_worst_slack -min

puts ""
puts "-- 违例路径数（建立）"
report_checks -path_delay max -slack_max 0 -format end -digits 3

puts ""
puts "-- 最差 3 条建立路径明细"
report_checks -path_delay max -digits 3 -group_count 3

puts ""
puts "-- 时钟"
report_clock_properties

puts ""
puts "-- 面积：面积/单元统计在综合阶段直接从门级网表统计（见 flow/Makefile 输出与"
puts "   build/syn/ucie_d2d_top_mapped.v）；OpenSTA 3.1.0 没有 report_design_area 命令。"

puts "================================================="

# 说明：这里刻意不调用 sta::worst_slack / sta::total_negative_slack 之类的
# 内部 API（版本间名称会变），签核数字全部来自上面的 report_* 输出，
# 由 flow/Makefile 一并 tee 到 build/syn/sta.log。
puts ""
puts "签核报告：$out/sta.log"
