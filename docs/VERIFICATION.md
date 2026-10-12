# 验证报告：ucie-d2d-demo

- 被测设计：`ucie_d2d_top`（Chiplet D2D / UCIe 数字链路；顶层 + 12 个子模块，`rtl/` 下共 24 个 `.sv` 源文件）
- 验证环境：Verilator 5.050 `--binary --timing --assert --trace`，纯 SystemVerilog 自检测试台
- 测试台：`sim/verilator/tb_ucie_top.sv`（含看门狗，死锁时 400000 拍超时退出）
- 运行方式：`make test`（退出码 0 = 全通过）
- 日期：2026-10-11

## 1. 结论

**5 组场景全部通过（ALL PASS），零字节错配。**

```
=========== 全部测试通过 (ALL PASS) ===========
  发送事务数        : 80
  接收事务数        : 80
  载荷错配          : 0
  A 侧交付 / CRC错 : 0 / 0
  B 侧交付 / CRC错 : 80 / 9
  B 侧发出 NAK 数   : 9
  A 侧重传次数      : 17
  最终 lane 数      : 15 (有效掩码 7fff)
  终态              : ACTIVE
```

## 2. 测试矩阵与结果

| 编号 | 场景 | 激励 | 检查点 | 结果 |
| --- | --- | --- | --- | --- |
| T1 | 链路训练 | 复位释放 → `train_enable=1` | LTSSM 走完 RESET→SBINIT→MBINIT→MBTRAIN→LINKINIT→ACTIVE；`valid_lanes=16`；`repair_used=0` | PASS |
| T2 | 端到端数据通路 | A 侧背靠背发 32 笔 64B 事务（确定性逐字节载荷） | B 侧 32 笔全到、逐字节一致、`b_delivered=32` | PASS |
| T3 | 误码 → NAK → 重传 | A→B 方向注入 4 次单 bit 翻转，再发 16 笔 | 16 笔仍全到且零错配；`b_nak_sent` 增加；坏 flit **未交付**（交付增量 = 16 而非更多） | PASS |
| T4 | lane 修复 | `lane_good[3]=0` 打坏 1 条物理 lane，触发重训 | 回到 ACTIVE；`valid_lanes` 仍 16；`repair_used=1`；`lane_map[15]=16`（冗余 lane 顶替）；再发 16 笔数据完整 | PASS |
| T4b | 降级运行 | 再打坏 `lane_good[5]` | 回到 ACTIVE；`valid_lanes` 降为 15；**带宽下降但不丢数据**（16 笔完整） | PASS |
| T5 | 链路重训练 | `link_err_inject` 脉冲 | 观察到 ACTIVE→PHYRETRAIN→MBTRAIN→LINKINIT→ACTIVE；最终终态 ACTIVE | PASS |

## 3. 断言（SVA，仿真全程常开）

| 位置 | 断言 | 含义 |
| --- | --- | --- |
| `ucie_link_retry` | `a_window` | 重传窗口深度绝不超过缓冲深度（回绕指针算错会立即被抓） |
| `ucie_link_retry` | `a_backpressure` | 只有窗口满时才反压上游 |
| `ucie_dll` | `a_ctrl_no_drop` | 每个合法数据 flit 必须被交付或被 ACK/NAK 覆盖，不允许静默丢弃 |
| `ucie_dll` | `a_rxf_no_overflow` | 交付 FIFO 不得溢出 |
| `ucie_dll` | `a_credit_range` | 信用数不得越界 |
| `ucie_ltssm` | `a_err_path` / `a_l1_src` | 训练中途不得被错误直接拽进 ACTIVE；L1 只能由 TRAINERROR 进入 |
| `ucie_link_pipe` | `a_gate` | 非 ACTIVE 期间不得有新 flit 进入管道 |
| `tb_smoke` | `a_known` + `c_ready` | 断言与 cover 的编译/运行自检 |

## 4. 时序签核（OpenSTA 3.1.0 + Nangate45）

**综合网表**（`make sta`，未做物理实现）：

```
worst slack max  = -71.25 ns        （WNS，建立违例）
tns max          = -240878.42       （TNS）
worst slack min  = -0.04 ns         （保持，基本满足）
lclk   10.00 ns / rdi_clk 7.50 ns
```

**三个时序组各自都有违例**：

| 时序组 | 最差端点 | slack |
| --- | --- | --- |
| `rdi_clk` | `u_pipe_b2a/u_rdi_rx/_44419_/D` | −71.255 ns |
| `path delay`（deskew 的 `set_max_delay` 组） | `u_pipe_a2b/u_deskew/_09320_/A1` | −40.776 ns |
| `lclk`（重传路径） | `u_dll_a/u_retry/_27467_/D` | −14.314 ns |

**根因（2026-10-11 订正）**：**不是** CRC 组合展开的异或链，也不是 RDI 字节 mux 的逻辑深度 ——
而是**综合网表的高扇出未做缓冲**。实测网表内（排除时钟/复位）**203 个 net 扇出 >100**（最高 1100），
其中一个 559 扇出的 net 使 NOR4 单级延迟达 **11.362 ns**、AOI21 达 9.036 ns
（Nangate45 正常 0.1–0.2 ns）。逐级推导见 `BACKEND.md` §3.2。

**修复（APR 阶段）**：`flow/openroad/apr.tcl` 在 placement 后接入
`repair_design`（插 4997 个 buffer、覆盖 1115 个 net）+ `repair_timing -setup`（resize 136 实例）：

```
repair 前： worst slack max -71.25    tns max -240889.88
repair 后： worst slack max   0.00    tns max     0.00
面积：      371170 → 381066 um^2（+2.7%）
```

**结论表述（讲解可直接用）**：功能仿真全绿只证明功能正确，不代表可收敛。
该设计在综合网表上 WNS −71.25 ns，但根因是**高扇出未缓冲 —— 属物理实现问题，不是 RTL 结构问题**：
按旧结论设计的两版 RTL 改动（CRC 流水化、RDI 打拍）实测证伪、**均未实施**；
而 APR 阶段只插 buffer + resize，**不改一行 RTL**，71 ns 违例即收敛到 0。
这正是「前端设计与物理实现必须协同」的实证。

## 5. 综合结果（Yosys 0.68 + Nangate45）

```
网表行数        : 584178
顶层 DFF        : 14920 (DFF_X1)
主要单元 TOP6   : DFF_X1 14920 / MUX2_X1 12067 / NOR2_X1 6954 /
                  OAI21_X1 6405 / AOI22_X1 6078 / NAND2_X1 5429
综合耗时        : 约 49 秒（M 系列 Mac，单线程）
latch 残留      : 0（网表内无 DLATCH）
```

大面积来自 flit 位宽 544 bit 的寄存器阵列（retry buffer 8×544、AFIFO 8×544×4）——
真实设计应改为双口 SRAM 映射。

## 5b. APR 起点（OpenROAD，本机 arm64）

```
Number of instances       : 189348   （其中 DFF_X1 14920）
Core area                 : 1059468.690 um^2
Design area               : 371170 um^2 @ 35% utilization
HPWL                      : 3196746.6 u → legalized 3390591.7 u（+6%）
average / max displacement: 1.4 u / 9.2 u
运行时间                   : 61 秒（M1 Pro / 32GB）
输出                      : build/syn/ucie_d2d_top_placed.def
```

覆盖范围：floorplan（utilization 35%、aspect ratio 1.0）+ 引脚摆放 + 全局布局
（density 0.6）+ 详细布局 + `check_placement` 通过。

**未覆盖**：CTS（时钟树）、全局/详细布线、时序优化与 ECO、RC 提取、DRC/LVS、
GDS 输出。这些不是本机跑不动，而是耗时长且真实项目里需与商业签核工具配合
（见 `docs/BACKEND.md`）。

复现：`cd flow && make apr`

## 5c. AXI4 over UCIe 验证（协议层）

测试台 `sim/verilator/tb_axi_top.sv`：tb 同时充当 A 侧 AXI master BFM 与 B 侧带 burst 的
AXI slave 内存模型（4 KB / 64 × 64B），两侧经完整 D2D 链路相连。

| 编号 | 场景 | 结果 |
| --- | --- | --- |
| T1 | 链路训练到 ACTIVE | PASS |
| T2 | 单拍写 + 读回 | PASS（数据一致） |
| T3 | INCR 突发 4 拍写 + 读回 | PASS（4/4 拍逐字节一致） |
| T4 | 连续两笔不同 ID 的读 | PASS |
| T5 | A→B 注入 CRC 误码下的写读 | PASS（靠链路重传保证逐拍正确） |

汇总：A 侧写请求 4、读请求 5；`make test-axi` 退出码 0。
综合：317723 实例（原设计 189348，**协议层 +67.8%**），DFF 20992。
时序：WNS −71.32 ns（与纯 D2D 顶层的 −71.25 ns 同一量级），TNS −274041。
复现：`cd flow && make synth TOP=ucie_axi_d2d_top && make sta TOP=ucie_axi_d2d_top`
（APR 同理：`make apr TOP=ucie_axi_d2d_top`）。

**该轮调试暴露并修复了 6 个真实缺陷**（beat 类型码重叠、拼接位序、RLAST 位偏移、
struct/数组字段读写、tb 多驱动、过时断言），全部已写入代码注释。
特别注意：**T2 一度是假通过**（地址被丢成 0 后读写自洽），是 T3 的突发把它暴露的。

## 5d. UVM 风格分层验证（对应 需求第 4 条）

**规范来源**：参照既有项目的验证环境（`backend/ref_project/`，
按 UVM 方法学在 Verilator 上自建并跑通）。**不使用 UVM 库** —— 本机只有 Verilator
（无 VCS / Xcelium / Questa），但 UVM 的**方法学分层**完全可自建。

**组件（10 个文件，`sim/uvm_style/`）**：

| UVM 组件 | 实现 | 位置 |
| --- | --- | --- |
| virtual interface | `ucie_if` | `iface/ucie_if.sv` |
| transaction | `ucie_txn` | `ucie_txn.sv` |
| driver / monitor | `ucie_driver` / `ucie_monitor` | `agent/` |
| sequence | `ucie_seq`（DIR / RAND / BOUNDARY） | `seq/ucie_seq.sv` |
| scoreboard | `ucie_scb`（期望 FIFO + 参考模型） | `scoreboard/` |
| **coverage** | `ucie_cov`（**covergroup**） | `cov/ucie_cov.sv` |
| env / test / top | `ucie_env` / `ucie_test` / `test_top` | 根目录 |

**实测结果**（`make uvm`）：

```
D1~D7 定向 + R1 随机 20 笔           全部 PASS
[SCB] 比对 49 笔，错配 0 笔
[COV] cp_kind bins 3/3   cp_b0 3/3   cp_lane 2/2   cross 8/9
coverage/uvm_cov_latest.dat + annotate/（Verilator line/toggle 覆盖率）
```

**过程中修正的三处**（都写进了代码注释与 `sim/uvm_style/README.md`）：

1. **能力降级更正**：早前版本在 `ucie_pkg.sv` 里写过"Verilator 不支持 covergroup，
   因此手写采样统计" —— **这是错的**。Verilator 5.050 支持 covergroup / coverpoint /
   cross，已改用标准 covergroup 写法。
2. **覆盖率数据失真**：`seq/ucie_seq.sv` 里误写 `cov.set_kind(0)`，把 test 侧设置的
   "误码 / lane 降级"场景标签覆盖回 0 —— 结果 `cp_kind` 只有 1/3、`cross` 只有 3/9。
   修复后 **3/3、8/9**。**这不是"少跑了用例"，而是测试覆盖了、数据说没覆盖** ——
   只看"全部 PASS"会漏掉，正是功能覆盖率存在的意义。
3. **工具 bug 规避**：全开 `--coverage` 会在 `rtl/phy/ucie_link_pipe.sv` 的 SVA
   （`disable iff(!rrst_n)`）上抛 Verilator 内部错误
   （`V3Localize.cpp:203: AstVarRef not under function`），改用
   `--coverage-line --coverage-toggle`。

**仍未做**（如实声明）：约束随机（`randomize()`，Verilator 不支持）、覆盖率收敛到目标的
闭环流程、形式化验证、门级/时序仿真。

## 5e. deskew（lane 间时序对齐）实现与验证

对应 需求第 3 条 的「**时序对齐**」—— 主责区里此前唯一未实现的项。

**问题**：各 lane 走线长度不同 → 到达时刻相差若干 UI。而 `ucie_rdi_rx` 是"单拍 `pl_valid` +
逐 lane 取字节"打包的（`ucie_rdi.sv:112-120`），偏斜会让**不同 UI 的字节拼进同一个 flit**——
**CRC 仍然是对的，但数据已经错了**，这是比误码更隐蔽的一类问题。

**实现**（`rtl/phy/ucie_deskew.sv`，~190 行）：

| 阶段 | 做法 |
| --- | --- |
| **测量** | MBTRAIN 期间各 lane 收同一训练 pattern（`8'hA5`），记录首次命中时刻；取最早到达者为参考时基 → `skew[i] = arrive[i] - arrive_min`（超过 `SKEW_MAX_UI` 则饱和截断）|
| **补偿** | per-lane 弹性缓冲（深度 `SKEW_MAX_UI+1`），对每个 lane 施加 `max_skew - skew[i]` 拍延迟 —— **早到的多等、晚到的少等**，最终同拍对齐 |
| **旁路** | 未完成测量 / 训练期直通（`dsk_* = pl_*`），因此**对既有场景零影响** |

**接入方式**：插在误码注入之后、`ucie_rdi_rx` 之前；训练信号从
`ltssm_state == LTS_MBTRAIN` 派生，**外部激励接口一行未改**。两个方向（A→B / B→A）都接入。

**验证**（`sim/verilator/tb_deskew.sv`，**注入真实偏斜**——按 per-lane 到达时刻驱动）：

```
C1 未训练时旁路直通                          PASS
C2 16 个 lane 的 skew 全部测准（含边界值 4）   PASS
C3 对齐后 16 个 lane 数据同拍（0x10 ~ 0x1f）   PASS
C4 train_clr 后重测生效（图案改变，结果更新）   PASS
```

**粒度边界（不能说过头）**：本 demo 的 RDI 抽象是「每 lane 每 UI 传 1 字节」，
因此对齐粒度是 **UI（周期）级**。真实 UCIe 还要在 **bit/symbol 级**做 deskew，
那属于 PHY 的 SERDES 部分，不在本 demo 的数字范围内。

## 5f. 低功耗（数据门控）

对应 需求第 5 条 的「**低功耗设计**」。完整方案、排除理由、收益边界与讲解口径见
**`docs/LOWPOWER.md`**；这里只放结论数据。

**门控点**：`ucie_rdi_tx` 的 `lp_valid = busy`，空闲时输出本无意义，但组合逻辑仍无条件读
`flit` → 无谓翻转。以 `parameter int DATA_GATING`（0=原版 / 1=门控）实现，
经 `ucie_link_pipe` → `ucie_d2d_top` 三层透传，**同一份 RTL 综合出两个版本**。

**验证**（`make lowpower`，双 DUT 并列 + 参数化对比，方法取自既有项目的 `tb_tcu_gate.sv`）：

```
[S1] 空闲期 + 上游 flit 每拍变化：GATING=0 tog_idle=646  vs  GATING=1 tog_idle=0   PASS
[S3] 真实传输期两版本逐拍功能等价（无 MISMATCH）                                    PASS
汇总：GATING=0 tog_total=884   GATING=1 tog_total=0
```

**边界**：S1 的收益条件是"空闲期上游仍在变"；真实链路里 AFIFO 空闲时 `rdata` 保持，
该场景的收益本验证台未能可靠构造（相关不可信判据已撤除并注明原因）。
**本 demo 只量化了"翻转次数"这一代理指标，没有真实功耗数字（未做 SAIF/功耗分析）。**
时钟门控（ICG）、电源门控、UPF 流程均未实现。

## 5g. 门级仿真（零延时，带 RTL 对照）

对应 需求第 4 条 的"**时序仿真**"方向 —— 但**边界必须说清**（见本节末尾）。

**做法：同一份 TB 跑两遍，逐组比对**

| 运行 | DUT 源 | 行为模型 |
| --- | --- | --- |
| 1 | 门级网表 `build/dft/01_synth/ucie_lane_repair_netlist.v` | liberty（`read_liberty -ignore_miss_func`）|
| 2 | RTL 的 sv2v 转换版 `ucie_lane_repair_sv2v.v` | 原生 RTL |

**只跑门级看它自己过没过，说明不了综合正确** —— 必须有 RTL 侧对照。

**DUT 选择**：`ucie_lane_repair`（纯组合，唯一输入 `lane_good[16:0]`）→ 输入空间只有
**2^17 = 131072 种，可以穷举**。（原选 `ucie_ltssm`，它含异步复位与侧带握手，在
yosys sim 下复位语义难控，实测 trace 全 x；换组合模块后语义无歧义，同样投入证据更强。）

**结果**：

```
门级 trace 131999 行 / RTL trace 131999 行
[gatesim] PASS: RTL 与门级网表逐组一致（131999 组输入穷举比对）
```

这是**完备**的等价性证明 —— 穷举整个输入空间，而非抽样。

**过程中三个 TB 侧的坑（全都伪装成"DUT 不一致"）**：

| 现象 | 真因 |
| --- | --- |
| `ERROR: syntax error, unexpected '@'` | 在 `initial` 里用 `for + @(posedge clk)` 做事件等待 —— yosys 的 `read_verilog` 只读设计，时序控制归 `sim` 命令 |
| 两条 trace 全 `x` | **漏连输入 `reversal_detect`** → 未连输入为 x 并传播到全部输出；而门级侧因综合把未驱动输入优化成常量 0 反而有值，**看着像"门级与 RTL 不一致"** |
| `lm=000X0X0X...` | TB 把 `lane_map` 写成 85 位（实为 16×5=80 位），`read_verilog` resize 并补 x |

**共同教训：TB 的 bug 会伪装成 DUT 的 bug**，尤其在双版本对照里。`hierarchy -check`
只报了 resize 警告，**没能拦住漏连端口**。

**边界（不能说过头）**：

1. 这是**零延时**门级仿真，**没有 SDF 反标** → **只验证功能等价，不验证时序**；
2. 需求 所说的"**时序仿真**"指**带 SDF 反标**的门级仿真（验证 setup/hold）。本机
   **Nangate45 无 Verilog 单元行为模型**（平台目录下只有 `cells_adders` / `cells_clkgate` /
   `cells_latch` 三个补充模型）→ 这一条 Verilator 路线不可行，只能用 yosys 的 liberty
   行为模型做**零延时**等价。
   ⚠ 修正记录（2026-10-12 复检）：早前把"本机**无 SDF**"也写进了这条 —— 是错的。
   SKY130 单模块的 SDF 后仿链本机**已跑通**（OpenROAD `write_sdf` + Icarus
   `$sdf_annotate`，反标单元+互连延迟，见 `make sdf` / `flow/sky130/postapr_gatesim.sh`）。
   真正的剩余边界是 Icarus 13.0 **不支持 `$setup/$hold/$width` 违例检查**（实测
   `-g2005/-g2009/-g2012/-g2005-sv` 均报 "Timing checks are not supported"）。
3. 因此**严格讲，本节的"门级功能等价"（Nangate45 零延时）尚不等于 需求 原意的"时序仿真"**。
   "时序仿真"拆两层：**时序反标**已由 `make sdf`（SKY130，IOPATH+INTERCONNECT）覆盖；
   **静态 setup/hold 违例检查**已由 `make sta`（OpenSTA，报 WNS/TNS/VIOLATED）覆盖 —— 这是签核标准、不需商业工具。
   唯一没做的是 SDF 仿真里的**动态** $setup/$hold timing check（Icarus 不支持，属补充手段）——讲解时讲清即可，不能含糊。

**复现**：

```bash
make gatesim        # 或 sh flow/gatesim/run_gatesim.sh
```

前置：`sh flow/dft/01_synth.sh ucie_lane_repair` 生成网表与 sv2v 源。

## 6. 复现命令

```bash
# 功能验证（含断言）
make all                 # lint + CRC 自检 + 主仿真
make test                # 只跑主仿真
make wave                # GTKWave 看 waves/ucie_d2d_top.vcd

# 后端（综合 + 时序）
cd flow && make all      # sv2v → yosys → OpenSTA
cd flow && make synth    # 只综合
cd flow && make sta      # 只签核
```

## 7. 本报告未覆盖的内容（如实声明）

- **随机验证与功能覆盖率已做**（UVM 风格分层环境，见 §5d）：随机激励 + covergroup
  功能覆盖率（cp_kind 3/3、cp_b0 3/3、cp_lane 2/2、cross 8/9）。
  仍未做：**约束随机**（Verilator 不支持 `randomize()`）、**覆盖率收敛到目标的闭环**、**形式化验证**；
- ~~门级仿真与 SDF 反标未做~~ **已做**：SKY130 APR → `write_sdf` → Icarus `$sdf_annotate`
  时序后仿（`make sdf`），见 `flow/sky130/postapr_gatesim.sh` —— 这是能力点 4「时序仿真」对应的闭环。
  ⚠ 修正记录（2026-10-12 复检）：本小节早前写"门级仿真与 SDF 反标未做"是错的——本机已用
  OpenROAD `write_sdf` + Icarus `$sdf_annotate` 跑通（IOPATH 单元延迟 + INTERCONNECT 互连延迟均反标）；
  缺的只是 SDF 仿真里的**动态** setup/hold 违例检查（开源仿真的已知边界），而 setup/hold 的
  **静态**签核由 OpenSTA 完成（`make sta`，报 WNS/TNS/VIOLATED）。
- ~~未做 DFT（扫描链/ATPG）~~ **已做**：mux-D 扫描链插入 + 自研 ATPG（PODEM + PFS）+ 真实
  stuck-at 故障覆盖率，见 §8 / `docs/DFT.md`；**低功耗（数据门控）见 §5f / `docs/LOWPOWER.md`**；
- APR 只做到 **floorplan + 布局**（未做 CTS / 布线 / DRC-LVS），见 `docs/BACKEND.md` §1.1；
- **FPGA 原型验证：本项目不需要**；
- **实验室 / ATE / 硅后 bring-up：属硬件条件，不计入能力缺口** —— 无芯片、无实验室则
  无法开展，与设计能力无关（需要的是真实流片与实验室资源）；
- 另注：本项目的门级仿真走 **yosys + liberty 的 `function` 作行为模型**，
  **不需要单元 Verilog 模型**（SKY130 路线则依赖 `sky130_gatesim.v`）——
  因此连"缺 Nangate45 单元模型"这个障碍也绕过了；
- 未建模真实 PHY 的**电气**行为（Vref 扫描、眼图、速率协商为占位）；
  **deskew 已实现**（UI 级对齐，见 §5e）。
