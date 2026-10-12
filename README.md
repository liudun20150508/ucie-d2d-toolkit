# ucie-d2d-toolkit

一个**自包含、可复现**的 **Chiplet D2D / UCIe 数字链路 demo**：从 RTL 设计、验证到
后端（综合 / DFT / ATPG / STA / SDF 时序后仿）的完整方法链，全部用**开源工具链**在
macOS(arm64) 上跑通，不依赖商业 EDA。

> 用途：把它当作一个 **skill + 知识库 + 代码/脚本包** 加载进 Claude Code / Reasonix 等
> 环境（见 `SKILL.md` 与 `knowledge/INDEX.md`），快速复现或扩展这条 UCIe D2D 数字链路
> 的设计方法。

---

## 链路架构（数据通路自上而下）

```
                    ┌─────────────────────────────────────────────┐
                    │  AXI4 主/从桥 (rtl/proto/ucie_axi_*_bridge)  │  ← 协议层入口
                    └───────────────────┬─────────────────────────┘
                                        │ AXI4 over UCIe
                    ┌───────────────────▼─────────────────────────┐
                    │  PROTO_STREAM 容器 (stream_pack / unpack)    │  ← 打包成 64B payload
                    └───────────────────┬─────────────────────────┘
                                        │ 64B payload + 4B 头
        ┌───────────────────────────────▼──────────────────────────────┐
        │  数据链路层 DLL (rtl/link/)                                    │
        │  ucie_dll ── credit 流控 / CRC-16 / 重传编排                  │
        │  ucie_flit_tx/rx ── 68B flit 组装 / 解析                      │
        │  ucie_link_retry ── 重传窗口（误码 → 重发）                    │
        │  ucie_crc16 ── CRC-16（标准向量 0x29B1）                      │
        └───────────────────────────────┬──────────────────────────────┘
                                        │
        ┌───────────────────────────────▼──────────────────────────────┐
        │  物理层 PHY (rtl/phy/)                                        │
        │  ucie_ltssm ── 链路训练状态机（10 态）                         │
        │  ucie_deskew ── lane 偏斜测量/对齐                            │
        │  ucie_lane_repair ── 坏 lane 修复                             │
        │  ucie_rdi_tx/rx ── 字节 ↔ 16 lane 扇出                       │
        │  ucie_mgmt ── 管理通道（自定版，非合规实现）                   │
        └───────────────────────────────┬──────────────────────────────┘
                                        │ 16 lane
                          ┌─────────────▼─────────────┐
                          │   CDC：ucie_afifo（异步 FIFO） │
                          └───────────────────────────┘
```

**时钟域**：`lclk`（链路侧，10.0ns）与 `rdi_clk`（PHY 侧，7.5ns）跨时钟，经 `ucie_afifo` CDC。
三个"速率"（flit 速率 / lane 速率 / AXI 吞吐）的推导见 `docs/MICROARCH.md` §1.2。

> **逻辑图（矢量）**：模块连接关系见 `docs/ucie_modules.svg`（源 `docs/ucie_modules.dot`，
> 依据 `rtl/top/ucie_d2d_top.sv` 实测例化关系生成，`dot -Tsvg` 可重渲染）。

## 逐模块职责

| 模块 | 层 | 职责 |
| --- | --- | --- |
| `ucie_crc16` | 链路 | CRC-16 计算/校验 |
| `ucie_flit_tx` / `ucie_flit_rx` | 链路 | 68B flit（4B 头 + 64B payload + CRC）组装/解析 |
| `ucie_link_retry` | 链路 | 误码检测后的重传窗口 |
| `ucie_dll` | 链路 | credit 流控 + CRC + 重传编排（适配层） |
| `ucie_ltssm` | 物理 | 链路训练状态机（10 态） |
| `ucie_deskew` | 物理 | lane 间偏斜测量 → 对齐 → 旁路 |
| `ucie_lane_repair` | 物理 | 坏 lane 修复 |
| `ucie_rdi_tx` / `ucie_rdi_rx` | 物理 | 字节 ↔ 16 lane 扇出 |
| `ucie_mgmt` | 物理 | 管理通道（discovery / status / error，自定版） |
| `ucie_afifo` | CDC | 跨时钟异步 FIFO |
| `ucie_stream_pack` / `unpack` | 协议 | PROTO_STREAM 容器（AXI 事务 ↔ flit payload） |
| `ucie_axi_*_bridge` | 协议 | AXI4 主/从桥（slv/mst） |

## 目录结构

```
rtl/         SystemVerilog：pkg/ link/ phy/ cdc/ proto/ top/
sim/         Verilator 仿真（SVA 断言 + UVM 风格分层验证环境）
flow/        后端脚本：yosys 综合 / mux-D 扫描链插入 / 自研 ATPG / OpenSTA / OpenROAD / SDF 后仿
scripts/     DFT 轻量检查脚本
docs/        领域知识：微架构 / 协议 / 验证 / DFT / 后端 / 低功耗 / 性能 / 规格（8 份）
resources/   工艺库：Nangate45 + SKY130 liberty/lef（随包分发，见授权说明）
results/     已跑通输出：DFT 报告 / STA 报告 / SDF 后仿日志 / VCD 波形
SKILL.md     Claude Code skill 定义
knowledge/   知识库索引（knowledge/INDEX.md）
run_all.sh   一键端到端脚本（安装→功能验证→综合/STA→DFT→SDF）
Dockerfile   Linux 容器化复现（功能验证 + 轻量 DFT）
```

## 快速开始

依赖（全部可 `brew install`，一键脚本见下）：

```bash
sh run_all.sh     # 一键跑通全流程：安装→功能验证→综合/STA→DFT→SDF（等同下面各步）
sh install.sh     # 只装依赖 + 环境自检（缺哪个自动 brew install）
make all          # lint + CRC 自检 + 主仿真
make test         # 主仿真：训练/通路/误码重传/lane 修复/重训练
make test-axi     # AXI4-over-UCIe 协议层仿真
make wave         # GTKWave 打开 waves/ucie_d2d_top.vcd
make uvm          # UVM 风格分层验证（随机激励 + covergroup 覆盖率）
make dft-flow     # 综合 -> mux-D 扫描链插入 -> 自研 ATPG -> 真实故障覆盖率
cd flow && make all   # sv2v -> yosys 综合 -> OpenSTA 时序签核（报 WNS/TNS）
make sdf          # SKY130 APR -> write_sdf -> Icarus $sdf_annotate 时序后仿
```

跨平台复现：`Dockerfile`（Linux 容器跑功能验证 + 轻量 DFT）。

各目标的判定标准（日志出现即通过）见对应脚本/文档；波形落在 `results/waves/`。

## 已跑通（实测数字，证据在 `results/`）

- **功能仿真**：Verilator 端到端通路 + 误码重传 + lane 修复 + 重训练，SVA 断言通过
  （波形 `results/waves/ucie_d2d_top.vcd`、`ucie_axi_d2d_top.vcd`）。
- **DFT / 自研 ATPG**（`results/dft/atpg_results.json`）：
  - 故障全集 **2196** 个（stuck-at-0/1，全引脚）
  - 故障 collapse → **490** 个 checkpoint 故障（collapse 比 **0.777**）
  - 512 条随机模式 + PODEM 确定性 ATPG → **覆盖率 100%**
- **STA 静态时序签核**（`results/sta/sta.log` / `stat.rpt`）：
  - 时钟：`lclk` 10.00ns、`rdi_clk` 7.50ns
  - **模块级时序收敛（MET）**：`ucie_ltssm` 在 `lclk` 10.00ns 下 slack **+5.493ns**，
    综合 → 布局 → OpenSTA 全链路可正常闭合时序
    （`make synth TOP=ucie_ltssm && make sta TOP=ucie_ltssm`）。
  - 顶层 `ucie_d2d_top` 的综合快照 WNS 约 -71ns：跨 CDC / 16-lane 扇出的长组合路径在
    floorplan+布局（未做 CTS/布线/优化）阶段的中间态，收敛路线见 `docs/MICROARCH.md` §7。
- **SDF 时序后仿**（`results/sdf/sdf_gatesim.log` + `ucie_ltssm.sdf`）：OpenROAD `write_sdf`
  → Icarus `$sdf_annotate` 反标 IOPATH + INTERCONNECT 延迟跑通。

> 各工具链边界与修正记录（Verilator 无约束随机 / Icarus 无动态 timing check / APR 阶段等）
> 见 `docs/BACKEND.md`、`docs/VERIFICATION.md`、`docs/MICROARCH.md` §7。

## 工艺库授权

`resources/` 下的 SKY130 与 Nangate45 liberty/lef 文件**为便于开箱即用而随包分发**，
各自保留其原始授权（SKY130：Apache-2.0；Nangate45：Si2 教学库许可）。如你的分发
渠道要求，可自行从官方源重新获取并替换。
