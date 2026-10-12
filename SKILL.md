---
name: ucie-d2d-toolkit
description: >-
  Chiplet D2D / UCIe 数字链路 demo 的完整可复现方法链（RTL 设计 + 验证 + 后端：
  DFT/ATPG/STA/SDF 时序后仿），全开源工具链。当用户要复现、扩展或讲解 UCIe D2D
  数字链路（flit/CRC/DLL/LTSSM/lane repair/CDC/AXI4-over-UCIe 协议层）、门级仿真、
  mux-D 扫描链插入、自研 ATPG、OpenSTA 时序签核或 SDF 反标后仿时使用。
---

# ucie-d2d-toolkit：UCIe D2D 数字链路 demo

一个**自包含、可复现**的 Chiplet D2D / UCIe 数字链路设计方法包。把它当 skill 加载后，
按下面顺序取用即可快速复现这条链路。

## 我该先读什么

1. **`README.md`**（本仓库根）——目录结构、快速开始、已跑通证据、诚实边界。
2. **`knowledge/INDEX.md`**——8 份领域知识文档的索引，按主题跳转。
3. 需要动手时再看对应代码/脚本（`rtl/`、`sim/`、`flow/`）。

## 领域知识地图（详见 knowledge/INDEX.md）

| 主题 | 文档 |
| --- | --- |
| 微架构 / 模块划分 | `docs/MICROARCH.md` |
| UCIe 协议层（flit/CRC/DLL/LTSSM） | `docs/PROTOCOL.md` |
| 验证方案与覆盖率 | `docs/VERIFICATION.md` |
| DFT / 扫描链 / 自研 ATPG | `docs/DFT.md` |
| 后端（综合/APR/STA/SDF 后仿） | `docs/BACKEND.md` |
| 低功耗设计 | `docs/LOWPOWER.md` |
| 性能分析 | `docs/PERF_ANALYSIS.md` |
| 规格（SPEC） | `docs/SPEC.md` |

## 常用命令（在仓库根目录）

```bash
make all          # lint + CRC 自检 + 主仿真
make test         # 主仿真（训练/通路/误码重传/lane 修复/重训练）
make test-axi     # AXI4-over-UCIe 协议层仿真
make uvm          # UVM 风格分层验证
make dft-flow     # 综合 -> 扫描链插入 -> ATPG -> 故障覆盖率
cd flow && make all   # sv2v -> yosys -> OpenSTA 时序签核
make sdf          # SKY130 APR -> write_sdf -> Icarus $sdf_annotate 时序后仿
```

## 复现 / 扩展时的注意点

- **工具链全开源**（macOS arm64 可跑），不依赖商业 EDA。依赖：`verilator yosys sv2v
  opensta openroad icarus-verilog`（均 `brew install`）。
- **诚实边界**：Verilator 无约束随机（用 covergroup + 手写统计）；Icarus 反标 SDF 的
  IOPATH/INTERCONNECT ✅ 但不支持动态 timing check（setup/hold 静态签核由 OpenSTA 做）。
- **工艺库**：`resources/` 已随包分发 SKY130 + Nangate45 liberty/lef，见 README 授权说明。

## 回答问题时

- 结论要有证据：命令 + 输出片段（见各 `docs/*.md` 的修正记录与 `results/` 产物）。
- 涉及"不支持"的表述，先区分是**开源工具的固有边界**还是**没找到用法**，别外推。

## 智能体接入（Claude Code / Reasonix / OpenClaw 等）

- **Claude Code**：把本仓库放进去，`SKILL.md` 的 YAML 头（`name` + `description`）
  会被当作 skill 识别；正文+`knowledge/` 就是可检索的知识库。
- **Reasonix / OpenClaw 等通用智能体**：不认 `SKILL.md` 的 YAML 头，但 `docs/`、
  `knowledge/INDEX.md`、`README.md` 都是**纯文本/markdown**，可直接喂进知识库或
  RAG，无需改造。`make` 目标与脚本是普通 shell，任何能执行 shell 的智能体都能跑。
- **要不要写 MCP？** 只有当需要一个**独立常驻服务**（例如把 "跑 DFT 流程" 包成
  远程/后台工具给多会话调用）时才值得。本项目是**仓库内一次性可复现方法**，
  skill + 知识库已经够用，**MCP 属过度设计**。若确实需要，最小做法是把
  `flow/*.sh` 的入口包成一个 MCP tool（stdio：接收 `tool=xx` 参数 → 调对应脚本 →
  返回日志），约 50 行；不建议为此加依赖。
