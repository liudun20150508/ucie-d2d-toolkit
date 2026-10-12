# ucie-d2d-toolkit

一个**自包含、可复现**的 **Chiplet D2D / UCIe 数字链路 demo**：从 RTL 设计、验证到
后端（综合 / DFT / ATPG / STA / SDF 时序后仿）的完整方法链，全部用**开源工具链**在
macOS(arm64) 上跑通，不依赖商业 EDA。

> 用途：把它当作一个 **skill + 知识库 + 代码/脚本包** 加载进 Claude Code / Reasonix 等
> 环境（见 `SKILL.md` 与 `knowledge/INDEX.md`），快速复现或扩展这条 UCIe D2D 数字链路
> 的设计方法。

---

## 目录结构

```
rtl/         UCIe D2D 数字链路 SystemVerilog（flit / CRC / DLL / LTSSM / lane repair /
             CDC / AXI4-over-UCIe 协议层 / 顶层）
sim/         Verilator 仿真（含 SVA 断言 + UVM 风格分层验证环境）
flow/        后端脚本（yosys 综合 / mux-D 扫描链插入 / 自研 ATPG / OpenSTA / OpenROAD /
             SKY130 SDF 后仿）
scripts/     DFT 轻量检查脚本
docs/        领域知识（微架构 / 协议 / 验证 / DFT / 后端 / 低功耗 / 性能 / 规格）
resources/   工艺库（Nangate45 + SKY130 liberty/lef，已随包分发，见下方授权说明）
results/     已跑通的输出（DFT 报告 / STA 报告 / SDF 后仿日志 / VCD 波形）
SKILL.md     Claude Code skill 定义（如何加载使用）
knowledge/   知识库索引
```

## 快速开始

依赖（全部可 `brew install`）：

```
verilator  yosys  sv2v  opensta  openroad  icarus-verilog
```

```
make all          # lint + CRC 自检 + 主仿真（训练/通路/误码重传/lane 修复/重训练）
make test         # 只跑主仿真
make test-axi     # AXI4-over-UCIe 协议层仿真
make wave         # GTKWave 看 waves/ucie_d2d_top.vcd
make uvm          # UVM 风格分层验证（随机激励 + covergroup 覆盖率）
make dft-flow     # 综合 -> mux-D 扫描链插入 -> 自研 ATPG -> 真实故障覆盖率
cd flow && make all   # sv2v -> yosys 综合 -> OpenSTA 时序签核（报 WNS/TNS）
make sdf          # SKY130 APR -> write_sdf -> Icarus $sdf_annotate 时序后仿
```

## 已跑通（证据在 `results/`）

- **功能仿真**：Verilator 端到端通路 + 误码重传 + lane 修复 + 重训练，SVA 断言通过。
- **DFT/ATPG**：mux-D 扫描链插入 + 自研 ATPG（PODEM + 位并行故障模拟 + 故障 collapse），
  真实 stuck-at 故障覆盖率 **100%**（`results/dft/*.json`）。
- **STA**：OpenSTA 静态时序签核，报 WNS/TNS/违例路径（`results/sta/*`）。
- **SDF 时序后仿**：OpenROAD `write_sdf` → Icarus `$sdf_annotate` 反标 IOPATH + INTERCONNECT
  延迟跑通（`results/sdf/*`）。

## 诚实边界（重要）

- 工具链全开源，**不依赖商业 EDA**；但有几处是**开源工具的已知边界**，不要外推成"做不到"：
  - Verilator 不支持 `randomize()`（约束随机），覆盖率用手写统计 + covergroup。
  - Icarus 反标 SDF 的 IOPATH/INTERCONNECT ✅，但 `$setup/$hold/$width` **动态** timing check
    不支持；setup/hold 的**静态**签核由 OpenSTA 完成（那是签核标准做法）。
- APR 只做到 floorplan + 布局（未做 CTS/布线/DRC-LVS 的完整签核）。
- 真实 PHY 的**电气**行为（Vref 扫描、眼图、速率协商）为占位，未建模。
- 详细边界见各 `docs/*.md` 与脚本头部注释。

## 工艺库授权

`resources/` 下的 SKY130 与 Nangate45 liberty/lef 文件**为便于开箱即用而随包分发**，
各自保留其原始授权（SKY130：Apache-2.0；Nangate45：Si2 教学库许可）。如你的分发
渠道要求，可自行从官方源重新获取并替换。
