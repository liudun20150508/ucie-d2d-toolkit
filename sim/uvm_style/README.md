# UCIe D2D 分层验证环境（UVM 风格，Verilator）

> 对应 需求 **能力点 4**：「配合验证团队制定 UCIe D2D 接口的**模块级、系统级验证方案与测试用例**」
>
> **规范来源**：目录结构与写法参照既有项目的验证环境
> （`backend/ref_project/` —— 那套是按 UVM 方法学在 Verilator 上
> 自建并跑通的）。
>
> **不使用 UVM 库**：本机只有 Verilator（无 VCS / Xcelium / Questa）。UVM 库不可用，
> 但 UVM 的**方法学分层**完全可以自建 —— 这套环境要证明的是"能按 UVM 的思路搭验证方案"，
> 而不是"会用某个工具"。

## 组件映射（对照 UVM）

| UVM 组件 | 本环境 | 位置 |
| --- | --- | --- |
| virtual interface | `ucie_if` | `iface/ucie_if.sv` |
| transaction | `ucie_txn` | `ucie_txn.sv` |
| driver | `ucie_driver` | `agent/ucie_driver.sv` |
| monitor（被动采样） | `ucie_monitor` | `agent/ucie_monitor.sv` |
| sequence | `ucie_seq`（DIR / RAND / BOUNDARY 三类） | `seq/ucie_seq.sv` |
| scoreboard（期望 FIFO + 参考模型） | `ucie_scb` | `scoreboard/ucie_scb.sv` |
| **coverage（covergroup）** | `ucie_cov` | `cov/ucie_cov.sv` |
| env | `ucie_env` | `ucie_env.sv` |
| test（7 定向 + N 随机） | `ucie_test` | `test/ucie_test.sv` |
| top | `test_top` | `test_top.sv` |

组件间用 **mailbox 解耦**：`monitor → scoreboard`、`monitor → coverage`（与参考实现一致）。

## 实测结果（`sh sim/uvm_style/run.sh 20`）

```
D1 链路训练到 ACTIVE / D2 单笔 / D3 背靠背 8 笔 / D4 误码下 8 笔仍正确
D5 lane 修复 + 冗余顶替 / D6 降级到 15 lane / D7 载荷边界 / R1 随机 20 笔    全部 PASS

[SCB] 比对 49 笔，错配 0 笔
[COV] 功能覆盖采样 49 笔（covergroup: cp_kind / cp_b0 / cp_lane + cross）
[COV] cp_kind bins 3/3   cp_b0 bins 3/3   cp_lane bins 2/2
[COV] cross(cp_kind x cp_b0) bins 8/9
```

产物：`coverage/uvm_cov_latest.dat` + `coverage/annotate/`（Verilator 原生 line/toggle 覆盖率）；
回归日志 `logs/uvm_<时戳>_N<n>.log`（可作为提交证据）。

> `cross 8/9`：3 种场景 × 3 个载荷区间的 9 个组合中命中 8 个，差的那一组是随机激励未取到的组合
> （载荷首字节由 idx 派生），属**正常未饱和**而非缺陷 —— 要补满需再加定向激励。此处如实保留。

## 与参考规范的三处差异（都是有意为之）

| # | 参考实现 | 本环境 | 原因 |
| --- | --- | --- | --- |
| 1 | `sim/run.sh` 用 `--coverage`（全开） | `--coverage-line --coverage-toggle` | **Verilator 5.050 的工具 bug**：全开 `--coverage` 在 `rtl/phy/ucie_link_pipe.sv` 的 SVA `disable iff(!rrst_n)` 上抛内部错误 `V3Localize.cpp:203: AstVarRef not under function`。参考实现的 DUT 无这类 SVA，故未遇到 |
| 2 | `-DSYNTHESIS` 强制走真实硬件实现 | **不加** | 参考实现的 DUT 含 `ifndef SYNTHESIS` 的 `$countones` 仿真分支；本项目 RTL 是自研全可综合代码，**没有**仿真专用分支 |
| 3 | `seq/` 目录预留（run.sh 未列该文件） | **真实实现** | 作为一处补充：DIR / RAND / BOUNDARY 三类序列。不用 virtual class 继承（Verilator 对 class 继承支持有限），改"单类 + mode 分支" |

## 踩坑记录（都会复现，故写下来）

| # | 现象 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | `%Error: Reference to 'ucie_scb' before declaration`（IEEE 1800-2023 6.18） | 编译顺序：`seq` 引用了 `scb`/`cov` 的类型却排在它们之前 | 顺序改为 txn → iface → agent → **scoreboard → cov** → **seq** → env → test → top |
| 2 | covergroup 语法错误 | 我写了 `bins其他 = default;` —— **中文标识符非法** | 改英文；并采用"covergroup 声明 bins + 自己统计命中数"，**不调 `get_coverage()`**（Verilator 对该 API 支持不完整） |
| 3 | **`cp_kind` 只有 1/3、cross 只有 3/9**（测试明明跑了误码/降级场景） | `seq/ucie_seq.sv` 里写了 `cov.set_kind(0)`，把 test 设好的场景标签**覆盖回 0** | 删掉该行 —— 场景标签是 test 的定位。修复后 **3/3、8/9** |
| 4 | 全开 `--coverage` 触发 Verilator 内部错误 | 工具 bug（FSM/表达式覆盖转换路径 × SVA） | 改用 line + toggle 覆盖 |

> **坑 3 值得单独说**：它不是"少跑了用例"，而是**覆盖率数据失真** —— 测试覆盖了、数据说没覆盖。
> 只看"全部 PASS"会漏掉。这正是功能覆盖率存在的意义。

## 与定向测试台的关系

同一 DUT 有两套验证，**互补而非重复**：

| | `sim/verilator/tb_ucie_top.sv` | `sim/uvm_style/`（本目录） |
| --- | --- | --- |
| 风格 | 定向自检测试台 | **UVM 方法学分层** |
| 激励 | 固定序列 | 7 定向 + **随机** + **边界** |
| 比对 | 内联逐字节 | **scoreboard 独立组件 + 期望 FIFO** |
| 覆盖率 | 无 | **covergroup + Verilator line/toggle** |
| 用途 | 快速回归、CI | 证明**验证方案能力**（能力点 4）|

## 跑

```bash
sh sim/uvm_style/run.sh 100    # 参数 = 随机笔数
make uvm                       # 同上，默认 20
make uvm UVM_N=100             # 指定随机笔数
```
