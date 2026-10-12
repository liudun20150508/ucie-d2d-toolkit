# 知识库索引

本目录是 ucie-d2d-toolkit 的**领域知识入口**。按主题跳转到对应文档，再按需取用代码。

## 核心知识（docs/）

| # | 主题 | 文档 | 一句话说明 |
| --- | --- | --- | --- |
| 1 | 微架构 | [`docs/MICROARCH.md`](../docs/MICROARCH.md) | 模块划分、数据通路、时钟/复位策略、接口信号 |
| 2 | 协议层 | [`docs/PROTOCOL.md`](../docs/PROTOCOL.md) | 68B flit、CRC-16、DLL 重传、credit 流控、LTSSM 十态机、lane repair/deskew、CDC(AFIFO)、RDI 16 lane 扇出 |
| 3 | 验证 | [`docs/VERIFICATION.md`](../docs/VERIFICATION.md) | 测试计划、SVA 断言、UVM 风格分层环境、覆盖率、门级/SDF 后仿、修正记录 |
| 4 | DFT/ATPG | [`docs/DFT.md`](../docs/DFT.md) | mux-D 扫描链插入、自研 ATPG（PODEM + 位并行故障模拟 + 故障 collapse）、真实覆盖率 |
| 5 | 后端 | [`docs/BACKEND.md`](../docs/BACKEND.md) | 综合、APR、OpenSTA 时序签核、SDF 反标时序后仿 |
| 6 | 低功耗 | [`docs/LOWPOWER.md`](../docs/LOWPOWER.md) | 数据门控、双版本对比验证 |
| 7 | 性能 | [`docs/PERF_ANALYSIS.md`](../docs/PERF_ANALYSIS.md) | 吞吐/时延分析 |
| 8 | 规格 | [`docs/SPEC.md`](../docs/SPEC.md) | 设计规格与目标 |

## 代码 / 脚本地图

| 目录 | 内容 |
| --- | --- |
| [`rtl/`](../rtl/) | SystemVerilog RTL：`pkg/`（常量）、`link/`（CRC/flit/DLL）、`phy/`（LTSSM/lane repair/deskew/RDI/mgmt）、`cdc/`（AFIFO）、`proto/`（AXI4-over-UCIe）、`top/`（顶层） |
| [`sim/`](../sim/) | Verilator 测试台（含 SVA 断言、smoke 自检）与 UVM 风格分层验证环境（`uvm_style/`） |
| [`flow/`](../flow/) | 后端脚本：yosys 综合、mux-D 扫描链插入、自研 ATPG、OpenSTA、OpenROAD、SKY130 SDF 后仿 |
| [`scripts/`](../scripts/) | DFT 轻量检查脚本 |
| [`results/`](../results/) | 已跑通的输出：DFT 报告 / STA 报告 / SDF 后仿日志 / VCD 波形 |

## 快速定位（按任务）

- **想复现仿真** → `make test` / `make test-axi` / `make uvm`，读 `docs/VERIFICATION.md`。
- **想复现 DFT/ATPG** → `make dft-flow`，读 `docs/DFT.md`。
- **想复现时序签核** → `cd flow && make all`（OpenSTA），读 `docs/BACKEND.md`。
- **想复现 SDF 后仿** → `make sdf`，读 `docs/BACKEND.md` + `docs/VERIFICATION.md` §7。
- **想扩展协议层** → 读 `docs/PROTOCOL.md`，改 `rtl/link/`、`rtl/phy/`。
