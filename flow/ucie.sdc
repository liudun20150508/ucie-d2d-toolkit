# =============================================================================
# ucie.sdc : ucie_d2d_top 时序约束
# -----------------------------------------------------------------------------
# 两个时钟域：
#   lclk    100.0 MHz (10.0 ns) —— 协议层 / DLL 域
#   rdi_clk 133.3 MHz (7.5 ns)  —— RDI / 物理层数字域
#
# 关键约定：lclk 与 rdi_clk **异步**，两者之间的跨域路径由 AFIFO（Gray 指针 +
# 两级同步器）负责，不做普通时序分析——用 set_clock_groups -asynchronous 声明，
# 否则 STA 会报一堆假的跨域违例。真实项目里这些路径要交给 CDC 检查工具
# （Spyglass CDC / MeridianCDC）单独签核。
# =============================================================================

create_clock -name lclk    -period 10.0 [get_ports lclk]
create_clock -name rdi_clk -period 7.5  [get_ports rdi_clk]

set_clock_uncertainty 0.15 [all_clocks]
set_clock_transition  0.10 [all_clocks]

# 同一时钟域内是同步的；两域之间异步
set_clock_groups -asynchronous -group {lclk} -group {rdi_clk}

# 顶层 I/O 的粗略约束（真实项目里来自上游模块的 budget）。
# 注：Synopsys SDC 通常用 remove_from_collection 把时钟端口排除在外，
# 但 OpenSTA 3.1 未实现该命令（报 invalid command name），
# 因此直接对 all_inputs 施加约束——时钟端口由 create_clock 主导，不受影响。
set_input_delay  2.0 -clock lclk [all_inputs]
set_output_delay 2.0 -clock lclk [all_outputs]

# 复位不做时序检查
set_false_path -from [get_ports {lrst_n rrst_n}]

# 训练路径（LTSSM 侧带、lane_good 采样）允许慢：它们是慢速控制路径，
# 真实设计里同样会用 set_max_delay 放宽，避免为了控制路径牺牲数据路径。
set_max_delay 40.0 -from [get_ports {lane_good[*] reversal_detect train_enable link_err_inject}]
