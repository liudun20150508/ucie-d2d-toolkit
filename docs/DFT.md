# DFT 方案与可测性检查报告

> 对应 需求 **能力点 5**（"协同物理设计团队完成…**DFT 设计**与低功耗设计"）与
> **能力要求 6**（"了解 D2D 的可测性设计，能协同 DFT 及芯片测试相关同事协作开展 D2D 的测试工作"）——
> 这是 需求 里**唯一被写了两遍**的能力点。
>
> **本地能力边界（已修正）**：商业 DFT 工具（Tessent / DFT Compiler）本地没有，**但这不等于
> "做不了 ATPG"** —— 本项目已在 Nangate45 上跑通**完整链路**：综合 → mux-D 扫描链插入 →
> ATPG（PFS 随机 + PODEM 确定性）→ **真实 stuck-at 故障覆盖率**，见 **§8**
> （ucie_ltssm：2196 个故障、覆盖率 100%、运行 3.7 秒）。
>
> - **§1–§7**：轻量检查（scan-ready 静态检查 + 扫描链规划 + 翻转覆盖率）—— 全芯片层级
> - **§8**：完整流程实测（扫描插入 + ATPG + 故障覆盖率）—— 子模块层级
>
> 仍未覆盖：**MBIST、边界扫描（IEEE 1149.1）、transition delay / bridging 等故障模型**。
> 复现：`make dft`（§1–§7）/ `make dft-flow`（§8）

---

## 1. 扫描架构规划

| 项 | 值 | 依据 |
| --- | --- | --- |
| 可扫描 DFF 总数 | **20992** | 门级网表实测（Nangate45，顶层 `ucie_axi_d2d_top`）；OpenROAD 展平实例共 317723 |
| 规划扫描链数 | **8** | 权衡：链数↑ → 移位周期↓，但端口数与布线压力↑ |
| 每条链长度 | **2624** | `20992 / 8` |
| 移位周期数 | **2624** | @100 MHz ≈ **26.24 µs**（扫描模式通常降频，实际更长） |
| 扫描端口数 | **19** | `scan_in×8 + scan_out×8 + scan_en + scan_clk + test_mode` |
| DFF 类型 | `DFF_X1` × 20992 | 单一类型，利于 `dfflibmap` 后统一替换为扫描版本 |

> **数字来源（2026-10-11 复检订正）**：上表的 **20992** 是**带 AXI 协议层的顶层**
> （`ucie_axi_d2d_top`，OpenROAD 展平 317723 实例）综合出来的 DFF 数；本项目另一次
> **纯链路顶层**（`ucie_d2d_top`）早期综合得的是 14019，后来加入 `ucie_deskew` 的
> per-lane 弹性缓冲后为 **14920**。两者都是真值，但归属不同顶层。
> `make dft` 现在按**实际探测到的网表**报数（`build/syn/` 下存在的 `*_mapped.v`）：
> 只有纯链路网表时报 **14920**，跑过 `make synth TOP=ucie_axi_d2d_top` 之后报 **20992** ——
> 也就是**同一份脚本会因为 `build/syn/` 里躺着哪份网表而给出不同的 DFF 数**。
> 看 `make dft` 输出时先确认它读的是哪份网表（报告里 `[2]` 段会打印网表路径）。
> 要复现 20992 需先跑：`cd flow && make synth TOP=ucie_axi_d2d_top`。
> 换句话说：**20992 不是"这个设计的 DFF 数"，而是"AXI 版顶层的 DFF 数"**。

### 1.1 多时钟域是 D2D IP 的 DFT 难点

本设计有 **5 个时钟信号**：`clk` / `lclk` / `rdi_clk` / `wclk` / `rclk`
（后三个来自 `ucie_afifo` 的跨时钟域端口）。真实 DFT 必须按域分链：

| 时钟域 | 归属 | 扫描链处理 |
| --- | --- | --- |
| `lclk`（含 `clk`） | 协议层 / DLL / LTSSM / AXI 桥接 | 主链组 |
| `rdi_clk` | RDI TX/RX、链路管道 | **独立链组**（与 lclk 异步） |
| `wclk` / `rclk` | AFIFO 写/读侧 | 各自成组，或加 **lockup latch** 处理边界 |

**结论**：8 条链**不能**简单按长度均分，至少要分 **3 组时钟域**（lclk 组 / rdi_clk 组 / AFIFO 组），
跨域边界加 lockup latch。这是"链路类 IP 的 DFT 与纯同步 IP 不同"的典型体现。

---

## 2. scan-ready 静态检查结果

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| 无三态 / `inout` 端口 | ✅ PASS | 单驱动，可观测 |
| 无门控时钟 | ✅ PASS | 时钟不被组合逻辑驱动，tester 可直接控制 |
| 时序单元时钟均来自时钟端口 | ✅ PASS | 时钟集合 `{clk, lclk, rclk, rdi_clk, wclk}`，无派生时钟 |
| 时序单元全部带异步复位 | ✅ PASS | **25/25**（复检值；此前记为 22/22 是更早一轮的数） |
| 无 latch 推断 | ✅ **PASS** | **0 条**（2026-10-11 修复；此前 6 条，见 §2.1） |
| 门级网表存在（扫描链规划的输入） | ✅ PASS | 缺失时本项 FAIL —— 不能"按 0 个 DFF 静默规划"（见 §2.2） |
| 无组合环 | ✅ PASS | Verilator `-Wall` lint 通过 |

**判定：7 项检查全部通过（2026-10-11 起）。** 此前唯一失败项是 latch 推断，已修复 —— 见 §2.1。

> 顺带修掉的一处真问题：`ucie_crc16.sv` 原本用**同步复位**（其余 21 处都是异步），
> 复位风格不统一会给扫描插入与复位树加额外约束。已统一为异步低有效，
> 并用 `make crc`（标准向量 `0x29B1`）验证算法未受影响。

### 2.1 曾未通过项：sv2v 产生的 latch 推断（2026-10-11 已修复）

```
现象（修复前）：复检读 `build/syn/synth.log` 得 **6 条** `Latch inferred`：
      `\ucie_deskew.sv2v_autoblock_12.l`（3 条）+ `\ucie_rdi_rx.sv2v_autoblock_1.l`（3 条）。
      此前记为 9 条且全部指向 `\ucie_rdi_rx` —— 那是在加入 `ucie_deskew` **之前**的网表；
      deskew 用了同样的 `for` 循环写法，所以条数变了、涉及模块多了一个。
根因（已证实）：sv2v 把 always_comb 里 for (int l = ...) 的循环变量提升成**块内变量**，
      而该变量声明在 `if` 分支**内部**；if 为假时它没有赋值 →
      yosys 的 proc pass 据此推断出 latch（直读 SV 的仿真器没有这个问题）。
影响：latch 不可扫描 —— 若沿用该写法，扫描插入会失败或漏掉这部分逻辑。
```

**修法（实际采用第 4 种：循环外提）**：

| 方案 | 做法 | 结果 |
| --- | --- | --- |
| a) 显式展开 | 把 16 条 lane 的循环展开成直写 | 未采用：代码变长、可读性下降 |
| b) 具名块 + automatic | `always_comb begin : blk … end` 配 automatic 变量 | 未采用：需先验证工具链是否接受 |
| c) 换商业综合器 | DC / Genus 对 sv2v 输出处理更成熟 | 未采用：依赖服务器环境 |
| **d) 循环外提（采用）** | **把 `for` 提到 `always_comb` 最外层，条件挪进循环体** | ✅ **6 → 0 条，改 2 处、语义等价** |

**为什么 d 有效**：循环变量在最外层块里**无条件被赋值**（for 的初始化），不再存在"条件赋值"
路径，latch 语义消失。挪进循环体的条件是**循环不变量**（`ucie_rdi_rx` 的 `pl_valid`、
`ucie_deskew` 的 `measured_q && !train_mode`），因此功能等价。
`ucie_deskew` 的 else 直通分支改为逐 lane 展开，`dsk_valid` 的直通语义在循环后补一次。

**修复验证（实测）**：

```
`make synth` 后 `Latch inferred` : 6 条 → **0 条**
`make dft` 的 verdict            : NOT-SCAN-READY → **SCAN-READY**（7/7 项通过）
功能回归                          : make all / deskew / test-axi / uvm 全部通过
改动范围                          : rtl/phy/ucie_rdi.sv、rtl/phy/ucie_deskew.sv 各 1 处
```

**讲解口径**：这是**工具链转换副作用**而非设计缺陷 —— 证据是仿真功能完全正确、`-Wall` lint 无警告；
但它**确实是 DFT 风险**，所以修掉而不是绕开。**修法本身也值得讲**：不是去笨拙地展开 16 条 lane
的循环，而是**把循环提到最外层** —— 2 处改动、语义等价、latch 归零。

### 2.2 输入缺失时的行为（2026-10-11 修正）

`scripts/dft_check.py` 早期在**网表或综合日志不存在时静默跳过统计**，报告照常打印
"可扫描 DFF 总数 0 / 每条链长度 0 / DFF 类型 []"，看起来像"规划完成"。这个毛病实测触发过两次：

| 缺失的输入 | 后果 |
| --- | --- |
| `--netlist` 指向 `build/syn/ucie_axi_d2d_top_mapped.v`（当时并未综合出来） | `[2]` 扫描链规划全为 0，无任何提示 |
| `--synth-log` 指向 `build/syn/synth.log`（不存在） | latch 一项**假 PASS** → 同一份代码给出 `SCAN-READY`；日志存在时又给 `NOT-SCAN-READY` |

现在改为：

- **网表缺失** → 追加 FAIL 检查项「门级网表存在（扫描链规划输入）」，verdict 拉成
  `NOT-SCAN-READY`，`[2]` 段同时打印 ⚠ 声明"下面的 DFF 统计 / 链长 / 移位周期不是实测值"；
- **日志缺失** → latch 一项判 **FAIL** 并写明"未检查"（不再默认通过）；
- 默认网表改为**自动探测** `build/syn/` 下实际存在的 `*_mapped.v`；
- `note` 字段里原先硬编码的"本设计有 20992 个 DFF"改为按实际网表传入。

负向用例复现（应当 FAIL 而不是安静地给 0）：

```bash
python3 scripts/dft_check.py --netlist /tmp/not_exist.v --json /tmp/dft.json
```

---

## 3. 翻转覆盖率

```
信号总数      : 730
发生过翻转     : 730
翻转覆盖率     : 100.0%
```

### ⚠ 这个 100% 必须谨慎解读

VCD（`waves/ucie_axi_d2d_top.vcd`）只包含**仿真中被保留、未被优化掉**的信号
（**730** 个 —— 此前记为 600，是更早一轮的 VCD），而门级网表统计到 **14920 个 `DFF_X1`**
（AXI 版顶层为 20992，来源区别见 §1 的说明）——它们的内部状态大多不在 VCD 里。

**所以这是"可见信号翻转率"，不是故障覆盖率。** 要拿到有意义的覆盖率需要：

1. **门级/网表级仿真波形**（后仿 + SDF 反标），dump 层次更深
2. 或加大 `--trace-depth`
3. 真正签核靠 **ATPG 的 stuck-at / transition fault coverage** —— 本项目已用自研引擎在
   **子模块级**做到 stuck-at 覆盖率 100%（§8）；全芯片级与 transition delay 等模型仍需商业工具

**这条限制我写进了脚本的输出**（`build/dft_report.json` 的 `note` 字段），避免数字被误读。

---

## 4. 测试缺口与补测计划

| 缺口 | 现状 | 补法 | 本地可做？ |
| --- | --- | --- | --- |
| 扫描链插入 + shift/capture 测试 | **✅ 已做（§8）** | 见 §8.2 | ✅ ucie_ltssm：4 条链 / 53 FF，链移位经门级仿真验证 |
| ATPG 故障覆盖率 | **✅ 已做（子模块级，§8）** | 自研 PFS + PODEM 引擎 | ✅ 见 §8；全芯片级仍需商业工具 |
| **MBIST**（大数组） | 未做 | retry buffer 8×544、AFIFO 8×544×4 应映射双口 SRAM + 各自 MBIST | ❌ 需 SRAM 模型 |
| 边界扫描（IEEE 1149.1） | 未做 | D2D IP 通常需要 JTAG 或 UCIe 侧带作为测试访问口 | ⚠️ 可做骨架 |
| 测试模式下的时钟/复位控制 | 未做 | `test_mode` 门控 + `scan_clk` 切换 | ✅ 可做 |
| 跨域 lockup latch | 未做 | ATE 降频下简化，真实流程需要 | ❌ 需商业工具 |

---

## 5. D2D/Chiplet 特有的 DFT 关注点（讲解核心）

这一节才是**区别于普通数字 IP** 的地方：

| # | 关注点 | 说明 | 本 demo 的对应 |
| --- | --- | --- | --- |
| 1 | **链路本身的测试** | D2D 的 DFT 不只是内部扫描——还要测**链路**：误码率、眼图、lane 良率。做法是 **loopback 模式 + PRBS 图案 + 误码计数** | `err_inject_a2b/b2a` 已是这个思路的雏形（误码注入 → 重传 → 计数） |
| 2 | **冗余 lane 的测试** | 必须能**逐一禁用 lane** 验证修复逻辑与降级行为 | `lane_good[16:0]` 输入正是为此设计，测试台已验证"打坏 lane → 冗余顶替 → 不丢数据" |
| 3 | **侧带通道测试** | 侧带是低速通道，有独立测试模式 | 本 demo 侧带是 RTL 内回环（已声明的简化） |
| 4 | **跨 die 可观测性** | 芯片封装后内部节点不可探——必须靠扫描链 + 片上观测（本 demo 的 `st_*` 遥测计数就是这个思路） | `st_delivered/st_crc_err/st_retry` 等 |
| 5 | **ATE 量产测试** | 需要 `test_mode` 下的 PPA 与功能可测性，配合良率优化 | 见 `BACKEND.md` 的边界说明 |

**一句话**：D2D IP 的 DFT = **内部扫描（常规）+ 链路回环测试（特有）+ lane 冗余验证（特有）**。
只做内部扫描的 DFT 方案，交付时会缺掉后两块。

---

## 6. DFT 债清单

| # | 债 | 影响 | 优先级 |
| --- | --- | --- | --- |
| 1 | ~~`ucie_rdi_rx` / `ucie_deskew` 的 latch 推断~~ **已销**（§2.1，2026-10-11） | —— | ✅ 已完成（循环外提，2 处改动、语义等价） |
| 2 | ~~未做扫描链插入与移位验证~~ **已销**（§8） | —— | ✅ 已完成（子模块级） |
| 3 | 大数组未做 SRAM 映射 + MBIST | 面积大且不可测 | 中（与 `MICROARCH.md` §8 同一笔债） |
| 4 | 无 `test_mode` 端口与时钟/复位门控 | 测试模式不可控 | 中 |
| 5 | 无链路回环测试模式 | D2D 特有测试缺失 | 中 |

---

## 7. 复现

```bash
make dft                       # 跑本报告的全部检查（scan-ready + 扫描链 + 覆盖率）
python3 scripts/dft_check.py --chains 16   # 改链数试算
cat build/dft_report.json      # 结构化数据
```

**完整流程（§8）另有一键入口：**

```bash
make dft-flow                  # 综合 → 扫描插入 → ATPG 自检 → 覆盖率（默认 ucie_ltssm）
```

---

## 8. 完整 DFT 流程实测（扫描插入 + ATPG）

> 流程移植自既有项目 `backend/flow/dft/`（原为 SKY130 + tinyNPU），适配到本项目的
> UCIe 子模块 + **Nangate45**。**核心算法一字未改**（PODEM / PFS 并行故障模拟 / 故障 collapse /
> 拓扑序 / 捕获态求解 / 暴力穷举自检），改动全部是库格式与命名适配（§8.4）。

### 8.1 目标模块的选择（含一次试错）

| 模块 | 综合结果 | 能否做扫描 |
| --- | --- | --- |
| `ucie_lane_repair` | 693 cells / **0 个 DFF** | ❌ **纯组合模块** —— `lane_map`/`valid_lanes`/`repair_used` 全是组合输出，没有寄存器可扫描 |
| `ucie_link_retry` | `retry_mem` 为 8×544 位 | ❌ 约 4352 FF，规模过大 |
| **`ucie_ltssm`** | 291 cells / **41 个 `DFF_X1`** | ✅ **选定**（10 状态链路训练状态机）|

选择依据：`ucie_ltssm` 是**有状态的链路训练状态机**，规模适中，且是 D2D 链路的关键可测部件。

### 8.2 扫描链插入结果

| 项 | 值 |
| --- | --- |
| DFF 数 | 41 → **53**（+12 个 test-only 观测点）|
| 扫描链 | **4 条**，长度 `[14, 13, 13, 13]` |
| 新增单元 | **53 个 `MUX2_X1`**（mux-D：`D ← scan_en ? SI : D`）|
| 面积开销 | **+175.294 µm²（39.67%）**（`MUX2_X1`=1.862、`DFF_X1`=4.522）|
| 新增端口 | 9 个（`scan_en` + `scan_in[4]` + `scan_out[4]`）|
| **链完整性验证** | **PASS** —— yosys 以 liberty 行为模型跑 80 周期门级仿真，与 TB 内置的 4 条独立参考移位序列逐拍比对 |

**测试点插入**（覆盖率的关键手段）：从 87 个候选中挑出 **12 个**（阈值 fanout ≥ 4，最高扇出 18）——
给"既不是任何 FF 的 D、也不是顶层输出"的高扇出内部网各加一个观测 DFF 并串入扫描链，
使这批内部节点从**不可观测**变为**可观测**。

**Nangate45 带来的简化**：`DFF_X1` 是纯 D 触发器（`CK/D/Q/QN`，**无异步复位引脚**），
综合时已用 `async2sync` 把异步复位转成同步逻辑。因此移植时**整块去掉了**原流程的
复位门控（205 个 DFF 的 `RESET_B` 门控）与复位去耦 —— 那个问题在 Nangate45 上不存在。

### 8.3 故障覆盖率（实测）

```json
fault_universe: 2196          collapsed_checkpoint: 490     collapse_ratio: 0.777
n_random_patterns: 512        detected: 2196                redundant: 0   aborted: 0
fault_coverage_pct: 100.0     test_coverage_pct: 100.0
shift_cycles: 179             test_cycles: 184499           @50MHz 测试时长: 3690 µs
runtime_random_s: 3.7         cov_curve: 第 1 个模式即 100%
```

**这个 100% 的限定条件——必须与数字一起说**：

1. 故障模型是 **stuck-at-0/1**，**不含** transition delay / bridging / IDDQ
2. **扫描链自身的移位路径故障不在此集合内**（由 §8.2 的链完整性验证覆盖）
3. 覆盖极快（第 1 个模式即 100%）是因为 `ucie_ltssm` 规模小（53 FF）且为**全扫描**设计、
   PI 完全可控。真实 D2D IP 规模大、含不可控逻辑（模拟接口、亚稳态、跨域握手）时
   **不可能这么快** —— 这一点不能拿本项目的数据外推

### 8.4 移植过程：11 处改动，全是库格式差异

核心算法通过 `parse_liberty()` 抽象工艺差异，所以**一行未改**。踩到的**三个引号陷阱**：

| 位置 | SKY130 写法 | Nangate45 写法 | 后果 |
| --- | --- | --- | --- |
| cell | `cell ("name") {` | `cell (NAME) {` | cell 匹配失败 |
| pin | `pin ("A1") {` | `pin (A1) {` | `pins` 为空 |
| **direction** | `direction : "input";` | `direction : input;` | **`direction` 取不到 → `pins` 全空 → 每个 cell 被 `continue` → `liberty cells: 0`** |

**排查方式**：不靠猜，直接读 liberty 的 cell 块原文比对写法；并用 `--selftest`
（PODEM 判定 vs **暴力穷举**逐故障交叉验证）作为引擎正确性守门 —— 必须先看到
`PODEM vs 暴力: 36/36 一致`，才继续跑正式 ATPG。

**这条经验值得记住**：跨工艺移植的最大成本往往不是算法，而是**工具输入格式的方言差异**；
"先用一个能自证正确的自检挡住引擎问题，再去调格式"这个次序，能省掉大量盲猜。

### 8.5 复现

```bash
make dft-flow                                            # 一键跑完四步（默认 ucie_ltssm）
sh flow/dft/01_synth.sh ucie_ltssm                       # 1) 综合到 Nangate45
DFT_TOP=ucie_ltssm python3 flow/dft/02_scan_insert.py    # 2) 扫描插入 + 链验证
DFT_TOP=ucie_ltssm python3 flow/dft/03_atpg.py --selftest # 3) 引擎自检
DFT_TOP=ucie_ltssm python3 flow/dft/03_atpg.py --npat 512 # 4) ATPG + 覆盖率
```
