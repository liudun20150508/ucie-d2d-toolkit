# 本地 Mac ↔ 服务器：这个 demo 到底需要哪边？

> 结论先给：**这个 demo 的 90% 都能在你这台 Mac 上跑完，而且已经跑完了。**
> 需要服务器的只有商业 EDA 那一段（商业 APR / DFT / PV / emulator / 真实 PHY 混合仿真）。

---

## 1. 已在本机实测跑通的部分（不需要服务器）

| 环节 | 工具（本机实测版本） | 本 demo 的实际结果 |
| --- | --- | --- |
| RTL lint | Verilator 5.050 `--lint-only -Wall` | 顶层 + 12 个子模块 零警告 |
| 功能仿真 | Verilator 5.050 `--binary --timing --assert --trace` | 5 组场景 ALL PASS，产出 5.7 MB VCD |
| 断言 / 覆盖 | SVA（`assert property` / `cover property`） | LTSSM、retry 窗口、credit、FIFO 溢出断言常开 |
| 波形 | GTKWave | `make wave` 直接看 `waves/ucie_d2d_top.vcd` |
| 逻辑综合 | Yosys 0.68 + sv2v | Nangate45 映射，49 秒，14920 个 DFF |
| 时序签核 | OpenSTA 3.1.0 | WNS = **−71.25 ns**（违例，见下节） |
| 版图 / DRC / LVS | KLayout、OpenROAD（`~/bin`，ARM64 原生） | 本次未跑，环境已就绪 |
| **APR（布局布线）** | OpenROAD（ARM64 原生） | **已实测**：floorplan + 全局/详细布局 **61 秒**跑通；并已接入 `repair_design` + `repair_timing`，把 WNS 从 **−71.25 ns 收敛到 0.00**（见 §3.3） |
| 行为级/事务级建模 | SystemC 3.0 + cmake | 本次未跑，环境已就绪 |

也就是说：**RTL 设计 + 验证 + 综合 + 时序**这条线，在你的 Mac 上闭环，
不需要任何服务器、任何商业 license。

### 1.1 APR 实测（连布局布线的前半段也不需要服务器）

`flow/openroad/apr.tcl` 用 OpenROAD 对本项目的门级网表做了 floorplan + 布局：

```
[INFO IFP-0105] Number of instances:     189348      （其中 DFF_X1 14920）
[INFO IFP-0102] Core area:               1059468.690 um^2
[INFO IFP-0104] Effective utilization:   0.350
Design area 371170 um^2  35% utilization
original HPWL 3196746.6 u  →  legalized HPWL 3390591.7 u  (delta +6%)
real 1m1.040s             （M1 Pro / 32GB，单次跑完）
输出：build/syn/ucie_d2d_top_placed.def
```

结论：**18.9 万实例规模的设计，floorplan + 布局在 M1 Pro 上不到 1 分钟**。
CTS 与 detailed routing 未包含在本脚本里——不是跑不动，而是耗时长，
且真实项目里这一段要跟商业签核（PT/Calibre）配合，那才是必须上服务器的部分。

> **2026-10-11 更新**：脚本在 placement 之后已接入 `repair_design`（插 buffer、复制高扇出、
> 修 slew/capacitance）+ `repair_timing -setup`（sizing），把 setup 时序从 **WNS −71.25 ns
> 收敛到 0.00**、面积仅 +2.7% —— 这是本项目第一次把「前端综合出的违例，靠物理实现修掉」
> 这条真实分工走通。细节与边界见 **§3.3**。

## 2. 必须上服务器的部分

| 环节 | 为什么本地不行 | 典型工具 |
| --- | --- | --- |
| 商业 APR（布局布线） | OpenROAD 能在本地跑小设计，但真实 D2D IP（含 PHY 硬核、多电源域、几百万实例）需要商业工具的容量与签核精度 | ICC2 / Innovus / Fusion Compiler |
| DFT | 扫描链插入、ATPG、压缩、MBIST 需要商业工具与测试模型 | Tessent / DFT Compiler / TetraMAX |
| 物理验证签核 | Calibre/ICV 规则集与 runset 只在服务器环境；KLayout 只能做轻量检查 | Calibre / ICV |
| 门级/时序仿真回归 | 大规模 gate-level + SDF 反标回归的算力 | VCS / Xcelium + 队列 |
| Emulator / FPGA 原型 | 需要专用硬件 | Palladium / Zebu / HAPS |
| **真实 D2D PHY 数模混合仿真** | 需要 PHY 厂商的晶体管级模型 + Spectre/AMS + 长仿真 | Spectre AMS / VCS-AMS |
| 流片后 bring-up / ATE | 需要实验室与测试机台 | ATE + 实验室 |

**对讲解的含义**：Chiplet D2D 链路里的「PHY 联调 / bring-up / 硅后调试」这一段，
本 demo 只能建模到数字侧接口（RDI）和训练状态机，真正的电气训练、眼图、
时序对齐必须在服务器/实验室做——这条边界要在回答时说清楚，不要含糊过去。

## 3. 时序违例：根因（已订正）与修复结果

### 3.1 综合网表的违例（未做物理实现时）

```
lclk   100.0 MHz (10.00 ns)
rdi_clk 133.3 MHz ( 7.50 ns)
最差路径： u_pipe_b2a/u_rdi_tx  →  u_pipe_b2a/u_deskew  →  u_pipe_b2a/u_rdi_rx  →  DFF
data arrival time  =  78.568 ns
data required time =   7.313 ns
slack              = -71.255 ns   ← 严重违例（约 9.5 倍 rdi_clk 周期）
```

另外两个时序组也有违例 —— `path delay`（deskew 的 `set_max_delay` 组）−40.776 ns、
`lclk`（重传路径）−14.314 ns。**不是单点问题，而是三条路径各自都超标。**

### 3.2 ⚠ 根因订正（2026-10-11）：不是 CRC，是高扇出

**本节原先写的根因是「① `crc16_flit()` 组合展开成 66×8 = 528 级异或链；② RDI 字节 mux 全组合」——
经逐级路径分析，这个结论是错的**（旧结论保留在此，便于看出改的是什么）。

三条违例路径**都不经过 CRC**，也不是"逻辑级数太深"：

```
lclk 组最差路径（a_tx_valid → u_dll_a/u_retry/_27467_/D）的逐级延迟：
   2.090   v u_retry/_14324_/ZN (NAND4_X1)
  13.452   ^ u_retry/_14327_/ZN (NOR4_X1)     ← 单门 +11.362 ns ！
  23.336   ^ u_retry/_14419_/ZN (AOI21_X1)    ← 单门 +9.036 ns ！
```

Nangate45 下 NOR4 / AOI21 的正常延迟是 **0.1–0.2 ns**，出现 9~11 ns 只能是
**驱动能力被压垮**。实测网表（排除时钟/复位）：**203 个 net 扇出 >100**，最高 1100；
上面那个 11.362 ns 的 NOR4，输出 net 扇出 **559**。`rdi_clk` 组路径上每级 4–6 ns 的
XNOR2 属同一现象。

**为什么这不是 RTL 问题**：高扇出来自设计风格（一个控制信号驱动整条 544 位数据通路），
**插寄存器打拍、重构地址计算都不会减少扇出** —— 那是物理实现的定位。
（按旧结论设计过两版 RTL 方案：CRC 逐字节流水化、RDI 字节 mux 打拍；实测证伪后
**均未实施**，RTL 一行未改。）

### 3.3 修复：APR 阶段的 repair_design + repair_timing

`flow/openroad/apr.tcl` 在 placement 之后接入了标准 repair 流程：

```
== 时序：repair 前 ==      worst slack max -71.25    tns max -240889.88

== repair_design ==        修 760 slew + 965 capacitance 违例
                           Resized 760 instances / Inserted 4997 buffers in 1115 nets

== repair_timing -setup == Resized 136 instances

== 时序：repair 后 ==      worst slack max  0.00     tns max  0.00
Design area 381066 um^2 36% utilization      （371170 → 381066，+2.7%）
```

**结果：WNS −71.25 ns → 0.00 ns，TNS −240878 → 0.00，面积代价仅 +2.7%。**

这也**正面验证了 3.2 的根因判断**：只插 buffer + resize，**不改一行 RTL**，
71 ns 的违例就清零了。

口径与边界（不要说过头）：
- repair 后的数字来自 **OpenROAD 内置 STA**（与 OpenSTA 同源），且运行在**有布局 + wire RC**
  的条件下，比 `make sta`（读无 RC 的综合网表）更接近真实签核；
- `make sta` 仍报 −71.25 ns —— 它读的是**综合网表**，物理实现阶段才修得掉，属正常分工；
- **未覆盖**：CTS 后的 hold 修复（本次刻意只修 setup —— 无时钟树时 hold 违例不成立；
  实测无参数调用会插 38871 个 hold buffer 仍修不完，并以 `RSZ-0060 Max buffer count
  reached` 中断整个脚本）、布线后的 RC 提取与再次签核。

## 4. 迁移到服务器的路径（真要细跑时）

```bash
# 1) RTL + 仿真：本地与服务器一致，直接把 ucie-d2d-demo/ 同步过去
#    服务器上装 verilator 即可（或用商业仿真器：vcs/xrun 跑同一套 SV testbench）

# 2) 综合：把 flow/Makefile 的 LIB 换成服务器工艺库
make synth LIB=/path/to/your_tech.lib

# 3) STA：OpenSTA 换 PrimeTime，SDC 可直接复用（flow/ucie.sdc）
#    注意 clock_groups -asynchronous 的写法两边一致

# 4) APR：flow/openroad 那套脚本（参照 backend/flow/openroad）接到
#    本项目网表上即可；DFT 需要额外写 scan 配置（tessent/dftc）
```

## 5. 一句话版本

> **本机 Mac 能覆盖「RTL → 验证 → 综合 → 时序」全流程（已实测）；
> 只有商业 APR / DFT / PV / emulator / 真实 PHY 混合仿真必须上服务器。**
> 讲解演示时，本地跑 `make all` 就能出通证；被问到流片与 bring-up 时，
> 明确说清哪些是本 demo 建模的、哪些是必须在服务器/实验室完成的。
