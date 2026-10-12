# =============================================================================
# power.tcl : 功耗估算（OpenSTA report_power + VCD 活动率反标）
# -----------------------------------------------------------------------------
# 结论（2026-10-11 实测订正，此前写过"做不了"是错的）：
#   本机**能做功耗估算**，而且**不需要 ptpx、不需要真实设备**：
#     * OpenSTA 3.1.0 内置 report_power / read_vcd / read_saif
#     * Verilator 5.050 支持 --trace-saif（SAIF 也能生成）
#     * 综合网表保留了模块端口名 → VCD 可以反标上
#
# 两个实测踩坑（都会静默给出错误结论，务必注意）：
#   1) `-scope` 填的是 **VCD 的顶层名**（tb_ucie_top），
#      **不是** DUT 实例路径（tb_ucie_top.u_dut）。
#      填错时输出 "Annotated 0 pin activities"，功耗数字退化为纯假设值。
#   2) **活动率设置必须在 read_vcd 之前**。
#      先设默认假设值（-global/-input_ports），再读 VCD 让其覆盖；
#      若反过来，-global 会把实测值覆盖掉 ——
#      现象是"Annotated 2320"但功耗数字与纯假设时一模一样。
#
# 精度边界（讲的时候不要说过头）：
#   * 没有 RC 提取 → 互连功耗用线负载模型估算（精度低于 ptpx 级别）；
#   * 反标率有限（本设计 2320 个引脚），未标注的内部节点仍用假设值；
#   * 这是**仿真活动率下的估算**，不是硅后实测功耗。
# =============================================================================

set lib   $::env(UCIE_LIB)
set net   $::env(UCIE_NET)
set top   $::env(UCIE_TOP)
set sdc   $::env(UCIE_SDC)
set out   $::env(UCIE_OUT)
set vcd   $::env(UCIE_VCD)
set scope $::env(UCIE_VCD_SCOPE)

# 假设值：用于 VCD 未覆盖到的节点（可被下面的 read_vcd 覆盖）
set DEF_ACT 0.2
set DEF_DUTY 0.5

puts "== 读入工艺库：$lib"
read_liberty $lib

puts "== 读入门级网表：$net"
read_verilog $net

puts "== 链接设计：$top"
link_design $top

puts "== 读入约束：$sdc"
read_sdc $sdc

puts ""
puts "== 第 1 步：设定默认活动率（假设值，供 VCD 未覆盖的节点用）=="
if {[catch {set_power_activity -input_ports [all_inputs] -activity $DEF_ACT -duty $DEF_DUTY} m]} {
    puts "   (!) -input_ports 失败：$m"
}
if {[catch {set_power_activity -global -activity $DEF_ACT -duty $DEF_DUTY} m]} {
    puts "   (!) -global 失败：$m"
}
puts "   输入端口 / 内部节点：activity = $DEF_ACT、duty = $DEF_DUTY（假设值）"
puts "   时钟活动率：由 SDC 的 create_clock 自动推导（lclk 100 MHz / rdi_clk 133.3 MHz）"

puts ""
puts "== 第 2 步：读入 VCD 实测活动率（覆盖上面的假设值）=="
puts "   文件：$vcd"
puts "   作用域：$scope（**必须是 VCD 的顶层名**；填 DUT 实例路径会得到 Annotated 0）"
if {[catch {read_vcd -scope $scope $vcd} msg]} {
    puts "   (!) read_vcd 失败：$msg"
    read_power_activities -scope $scope -vcd $vcd
}

puts ""
puts "==================== 功耗估算结果 ===================="
report_power -digits 4
puts "======================================================"

puts ""
puts "口径说明（不要说过头）："
puts "  * 活动率 = VCD 实测（已反标部分）+ 假设值 $DEF_ACT/$DEF_DUTY（未覆盖部分）"
puts "  * 没有 RC 提取，互连功耗用线负载模型估算"
puts "  * 这是仿真活动率下的**估算**，不是硅后实测功耗"
puts ""
puts "功耗报告：$out/power.log"
