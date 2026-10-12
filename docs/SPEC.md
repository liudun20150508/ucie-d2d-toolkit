# ucie-d2d-demo 实现规格（及与真实 UCIe 规范的差异声明）

> **重要声明**：本 demo 按 UCIe 1.1 的**语义**建模（flit 保护、字节级 lane valid、
> 分层训练、冗余 lane、credit/retry），但属于**教学级简化实现**，
> **不承诺与 UCIe 规范逐位/逐时序兼容**。做规范兼容验证（CTS/互操作）之前，
> 必须逐条对照规范修订。下面把差异全部列明——含混过去比写错更糟。
>
> **UCIe 1.0 → 3.0 的版本演进、以及每个版本的特性在本 demo 的覆盖情况，见 §0。**

---

## 0. UCIe 版本演进与本 demo 的覆盖（2026-10-11 补）

> **为什么补这一节**：需求第 3 条「深入理解 UCIe 协议规范（**1.0/1.1/2.0 及以上版本**）」、
> 能力点 7 要求「**跟踪 UCIe 协议标准演进**」。而本项目文档原先只写到 2.0 ——
> 实际 **UCIe 3.0 已于 2025-08-05 发布**。下面按版本列演进，并逐条标注本 demo 的覆盖。
>
> **信息来源**：UCIe Consortium 官网（uciexpress.org）的新闻稿与**公开白皮书 PDF**
> （3.0 / 2.0 白皮书可公开下载；**规范全文是会员制**，本机没有，故本文档不引用具体条款号、
> 也不宣称逐位兼容）。抓取日期 2026-10-11。

### 0.1 版本时间线（据官网新闻稿标题）

| 版本 | 发布 | 该版本主题（新闻稿原文） |
| --- | --- | --- |
| 1.0 | 2022-03 | 联盟成立并发布首个规范 |
| 1.1 | 2023-08-08 | "Backward compatible evolution … with **new usage models**" |
| 2.0 | 2024-08-06 | "Supporting **Manageability System Architecture** and **3D Packaging**" |
| **3.0** | **2025-08-05** | "With **64 GT/s Performance** and **Enhanced Manageability**" |

### 0.2 规范特性 → 本 demo 覆盖（逐条）

| 规范特性 | 出自 | 本 demo | 落点 / 缺口 |
| --- | --- | --- | --- |
| 三层架构 Protocol / Die-to-Die Adapter / Physical | 1.0 | ✅ 有对应分层 | `rtl/proto`、`rtl/link`、`rtl/phy` |
| 68 B flit（标准封装） | 1.0 | ✅ 68 B | `rtl/pkg/ucie_pkg.sv` |
| 256 B flit（延迟优化模式） | 1.0 | ❌ 未实现 | §1 已列差异 |
| RDI 字节级 per-lane valid | 1.0 | ✅ | `rtl/phy/ucie_rdi.sv` 的 `lp_mask` / `pl_mask` |
| CRC + replay（重传） | 1.0 | ✅ CRC-16 + 累积 ACK/NAK + 超时重传 | `ucie_dll.sv`、`ucie_link_retry.sv` |
| 链路训练状态机 | 1.0 | ✅ 10 态，且**沿用规范状态名**（SBINIT/MBINIT/MBTRAIN/LINKINIT/ACTIVE + PHYRETRAIN/L1） | `rtl/phy/ucie_ltssm.sv` |
| 冗余 lane / lane repair | 1.0 | ✅ 坏 lane 剔除 + 冗余顶替 + 降级 | `rtl/phy/ucie_lane_repair.sv` |
| **DFx 基础机制**：lane margining、compliance testing、fault reporting、sideband access | 1.0 / 1.1 | ❌ 未做（fault reporting 有雏形：`crc_err_pulse` + LTSSM 错误上报） | 缺口 |
| **UCIe-3D**（hybrid bonding，pitch 9 µm → ~1 µm） | 2.0 | ❌ 未涉及（本 demo 只到 2D/2.5D） | 缺口 |
| **SiP 级 manageability / debug / test**（覆盖 silicon life cycle） | 2.0 | ❌ 未做 | 缺口 |
| 数据率 **32 → 64 GT/s**（+48 GT/s） | 3.0 | ❌ 未建模（速率是抽象参数） | 电气层不在 demo 范围 |
| **shoreline bandwidth density** 提升 | 3.0 | ⚠️ **概念命中、未量化** | 见 `docs/PERF_ANALYSIS.md`（"高带宽密度"待补推导） |
| 电气：NRZ 单向、quarter-rate clocking@48/64G、BER 10⁻¹⁵/10⁻¹²、3-tap TX FFE + RX CTLE（可选 1-tap DFE） | 3.0 | ❌ 未建模 | 属 PHY 电气，见 §4 缺口 |
| **LTSSM 增强**：I/O correction + EQ preset 选择 | 3.0 | ⚠️ 语义部分对应：MBTRAIN 有 per-lane deskew 测量与补偿，但**无 EQ preset** | `rtl/phy/ucie_deskew.sv` |
| **运行功耗节省**：TX 侧 clock-to-data skew 运行时重校准 | 3.0 | ❌ 未做 | 缺口 |
| **空闲功耗节省**：L2 关掉 sideband 的电源与时钟 | 3.0 | ⚠️ **思路同源、层次不同** | 见下条说明 |
| **Manageability 新特性**：固件下载、sideband 优先包、star 拓扑 sideband 延伸、open drain pin | 3.0 | ❌ 未做；本 demo 的 sideband 是**同 RTL 内回环**，非真实跨 die 通道 | §4 已知缺口 3 |

**关于"低功耗"那条要特别分清层次**（别说过头）：

- 规范 3.0 的 L2 节省是**关掉 sideband 基础设施的电源与时钟**；
- 本 demo 做的是**数据路径门控**（`DATA_GATING`，空闲期翻转 **646 → 0**，见 `LOWPOWER.md`）；
- 两者**目标相同（降空闲功耗）、层次不同**。讲的时候要说"这是同一目标在数据路径上的映射"，
  **不能说成"我实现了规范的 L2"**。

### 0.3 这一节能怎么用（讲解口径）

- **被问"UCIe 演进"**：1.1 加 usage models → 2.0 把**可测/可管理性从接口级升到 SiP 级** + **3D 封装** →
  3.0 加 **64 GT/s**、**空闲功耗**、**可管理性**。**知道 3.0 存在且说得出主题**是关键。
- **被问"高带宽密度"**：3.0 白皮书正是在讲这件事 —— 原话是
  "insatiable demand for bandwidth **within the tight shoreline constraints**,
  necessitating improvements in **shoreline bandwidth density**"。
  这恰好是本 demo 还缺量化推导的那一项（需求第 4 条 用「**精通**」写的）。
- **被问"规范原文读过吗"**：**如实说** —— 读过**公开白皮书与新闻稿**（本节即据其整理），
  **全文是会员制、本机没有**，所以不宣称逐位兼容，也不引用条款号。

---

## 1. 链路几何

| 参数 | 本 demo | 真实 UCIe（标准封装） | 差异说明 |
| --- | --- | --- | --- |
| flit 大小 | 68 B（64B payload + 2B header + 2B CRC） | 标准封装 68 B / 延迟优化 256 B | 与本 demo 同为 68B 量级；未实现 256B 模式 |
| lane 数 | 16 数据 + 1 冗余（`LANES_TOTAL=17`） | x8/x16/x32 module，冗余 lane 可选 | 语义一致，数量为本 demo 选取 |
| RDI 数据宽度 | 16 B/UI（每 lane 1 B/UI） | 每 lane 1 B/UI，UI 数随 lane 数变化 | 一致 |
| flit 传输拍数 | `ceil(68/16)=5` UI（末 UI 仅 4 B 有效） | 非整数 UI，靠 per-lane valid 描述 | **这是本 demo 有意保留的真实特性**：`lp_valid/pl_mask` 按字节而非按拍 |
| 降级模式 | 有效 lane 变少 → 每 UI 字节数减少 → flit 拍数自动增加 | 同 | 语义一致 |

定义位置：`rtl/pkg/ucie_pkg.sv`（`LANES` / `RDI_BYTES` / `FLIT_*` / `LANES_TOTAL` / `MAP_W`）。

## 2. Flit header（16 bit）

```
[15]    rsvd
[14:12] flit format : 0=DATA 1=CTRL 2=NULL 3=TRAIN
[11:8]  protocol id : 0=PCIe 1=CXL.io 2=CXL.cache 3=Streaming(默认) 4=Mgmt
[7:0]   sequence number（8 bit 回绕，链路层重传/去重用）
```

覆盖范围：CRC-16-CCITT（poly `0x1021`、init `0xFFFF`、非反射）覆盖
**header(2B) + payload(64B) = 66 B**，不覆盖 CRC 自身。算法自检向量：
`"123456789" → 0x29B1`（`make crc`）。

**与规范的差异**：字段位置/宽度为自定义子集，未逐位对齐 UCIe header 定义；
CRC 多项式选取与规范可能不同。

## 3. 链路层控制消息（放在 FMT_CTRL flit 的 payload）

| byte | 含义 |
| --- | --- |
| byte0 | 消息码：`0x00 NOP` / `0x01 ACK` / `0x02 NAK` / `0x03 CREDIT` / `0x04 LINKERR` |
| byte1 | 参数：ACK/NAK 携带 seq；CREDIT 携带返还信用数 |
| byte2 | 辅助：ACK 顺带携带的返还信用数（合并以省带宽） |

语义约定：

- **ACK 是累积确认**：`ACK(seq)` 表示 seq 及之前全部正确收到。
- **NAK 是回退请求**：`NAK(seq)` 表示请从 seq 起重发。
- **超时兜底**：发出后 `RETRY_TIMEOUT`（默认 48 lclk 周期）未见反馈，自发从
  `ack_ptr` 整段重传——真实链路上 ACK 可能丢，超时是必需的。
- 序号 8 bit 回绕，**窗口比较一律走模 256 区间判断**（`in_window()`），
  禁止用大小比较——这是回绕序号最经典的坑。

**与规范的差异**：真实 UCIe 的 retry/credit 有独立的寄存器和更细的流控规则
（含 credit 类型区分），本 demo 做了合并简化。

## 4. LTSSM 状态与训练流程

```
RESET → SBINIT → MBINIT → MBTRAIN → LINKINIT → ACTIVE
                                  │                │ link_error
                                  ↓                ↓
                            TRAINERROR ←──── PHYRETRAIN
                                  │                │
                                  ↓                │
                                 L1 ←──────────────┘（重训次数超限则降级）
```

| 状态 | 本 demo 行为 | 真实 UCIe |
| --- | --- | --- |
| SBINIT | 侧带交换 lane 数参数，等对端 ACK 或计数超时 | 侧带握手 + 能力协商，多轮子状态 |
| MBINIT | 协商 lane 映射（含修复结果） | 含 lane 修复协商、参数交换多子状态 |
| MBTRAIN | 固定时窗 + **真实 deskew 测量**（各 lane 收同一训练 pattern，测 per-lane 偏斜并补偿） | 真实的 Vref/速率/width 子状态与**电气**训练 |
| LINKINIT | credit/重传参数握手 | 链路层参数交换 |
| ACTIVE | 数据路径放行 | 一致 |
| PHYRETRAIN | 清错误后重走 MBTRAIN，次数受限 | 一致（触发条件更丰富） |
| TRAINERROR/L1 | 重训超限 → 降级低功耗 | 一致（子状态更多） |

**已知缺口（明确列出）**：
1. ~~**deskew 未实现**~~ **已实现**（`rtl/phy/ucie_deskew.sv`）：MBTRAIN 期间测 per-lane skew，
   RX 侧用 per-lane 弹性缓冲按值对齐。
   **粒度边界**：本 demo 的 RDI 抽象是"每 lane 每 UI 传 1 字节"，因此对齐是 **UI（周期）级**；
   真实 UCIe 还要在 bit/symbol 级对齐，那属于 PHY 的 SERDES 部分。
2. **无电气训练**：Vref 扫描、眼图、速率协商均为占位。
3. **侧带为同 RTL 内回环**：`ucie_d2d_top` 把本端侧带消息直接回连到本端接收端，
   不是真实的跨 die sideband 通道（真实实现是独立低速串行通道）。
4. 训练各阶段的**计数阈值是可综合的参数**（`SBINIT_CYCLES` 等），
   仿真里取小值以便快速收敛。

## 5. 时钟与复位

| 时钟域 | 频率（demo） | 覆盖范围 |
| --- | --- | --- |
| `lclk` | 100.0 MHz（10 ns） | 协议层接口、D2D Adapter、LTSSM、lane 修复 |
| `rdi_clk` | 133.3 MHz（7.5 ns） | RDI TX/RX、链路管道的数据搬运 |

- 两域**异步**：跨域只经 `ucie_afifo`（Gray 码指针 + 两级同步器）。
  STA 里用 `set_clock_groups -asynchronous` 声明（`flow/ucie.sdc`）。
- **复位统一为异步低有效**（`always_ff @(posedge clk or negedge rst_n)`）。
  真实设计里跨域复位应加复位同步器——本 demo 未实现，属已知简化。
- 测试台故意让两域异频（100 / 133.3 MHz），使 CDC 真的被验证到，而不是同频假过。

## 6. 数据路径的寄存器化取向（对 DFT 友好）

- 数据路径全寄存器化，无内部三态、无 latch（综合检查：网表内 `DLATCH` 计数为 0）。
- 所有大数组（retry buffer / FIFO）当前综合为 FF 阵列（顶层 14920 个 DFF），
  真实设计应映射为双口 SRAM 并单独做 MBIST。
- 复位可控、无异步置位，便于扫描链插入（DFT 接入点见 `docs/BACKEND.md`）。

## 7. 验证使用的错误模型

| 注入点 | 机制 | 期望行为 |
| --- | --- | --- |
| `err_inject_a2b` / `err_inject_b2a` | 在链路域对传输中的 flit 翻转 1 bit | 接收端 CRC 失败 → NAK(exp_seq) → 发送端整段重传 → 最终正确交付，坏 flit **不交付上层** |
| `lane_good[i]=0` | 打坏某条物理 lane | 重训后冗余 lane 顶替（`repair_used=1`），数据仍完整；再坏则降级到 15 lane |
| `link_err_inject` | 上报不可恢复链路错误 | LTSSM 从 ACTIVE → PHYRETRAIN → 重训 → ACTIVE |

**未做的验证**：随机化约束验证（UVM/cocotb）、形式化（SVA + 形式化引擎）、
覆盖率驱动的收敛、门级/SDF 反标仿真。

## 8. 协议层扩展：AXI4 over UCIe

本 demo 在 UCIe 语义之上**叠加**了协议层（AXI4），完整规格见 **[PROTOCOL.md](PROTOCOL.md)**：

- **字节流聚合容器**：64B flit payload ↔ 16B/拍字节流，字节粒度流控（`in_taken`/`out_taken`），
  不足处用 `PAD_BYTE(0x00)` 填充；带宽效率 `64/68 = 94.1%`。
- **事务格式**：16B 请求头（WR_REQ/RD_REQ）、16B 响应头（WR_RESP/RD_DATA）、
  **66B 数据 beat**（`[类型码][beat_idx][64B 数据]` —— 类型码必须有，否则与 beat 头区间重叠）。
- **AXI4 支持子集**：512 位数据宽、INCR/FIXED、4 位 ID、读写各 4 笔 outstanding；
  **不支持**：WRAP、LOCK/独占、cache 属性/QoS/region、写交织、乱序返回、字节选通（WSTRB 恒 1）。
- **CHI 边界**：只提供通道映射骨架（REQ/RSP/DAT/SNP 可映射到同一容器），
  **不实现** cache 状态机 / snoop filter / 目录。

本节与 §1–§7 同样适用「按规范语义建模、但不承诺逐位/逐时序兼容」的声明。

> 微架构层面的实现细节 —— 参数决策表（为什么取这个数、备选是什么、代价多少）、
> 缓冲深度推导、端到端延迟预算、以及 WNS 优化路线 —— 见 **[MICROARCH.md](MICROARCH.md)**。

---

## 9. 管理通道骨架（对应 UCIe 2.0 的 manageability，**自定简化实现**）

> ⚠ **重要声明（讲的时候不要说过头）**：本节描述的是**按 UCIe 2.0 公开白皮书列出的机制清单
> 自行设计的简化实现**，**不是规范合规实现** —— 规范全文是会员制的，本机没有，
> 因此**寄存器映射、消息编码、握手时序全部为自定**。它证明的是
> "我知道管理通道要做什么、它在数字侧长什么样"，**不是**"我实现了 UCIe 2.0 的可管理性"。

### 9.1 依据：白皮书列出的机制清单

UCIe 2.0 白皮书（官网公开 PDF）原文：

> In the UCIe 2.0 Specification, **manageability is optional**. The mechanisms supported include
> **discovery** of chiplets and their configuration; **initialization** of chiplet structures and
> parameters (i.e., serial EEPROM replacement); **firmware download**; **power and thermal
> management**; **error reporting**; **telemetry**; retrieval of **log and crash dump**;
> **test and debug**; initiation and reporting of **self-test status**; and various aspects of
> chiplet **security**. …The required core capabilities of UCIe manageability
> **may be realized through hardware and/or firmware**.

架构上它定义"一个带 **bridging function** 的公共基础设施，对外接 **SMBus 或 PCIe**"。

**要点：这些都是数字逻辑/固件 —— 不需要测试硬件设备。** 需要硬件的是 **CTS / 互操作验证**
（要有真实对端芯片），那是**验证环节**，不是实现环节。

### 9.2 本 demo 覆盖的子集（三类 + 一个控制位）

| 白皮书机制 | 本 demo | 落点 |
| --- | --- | --- |
| discovery of chiplets | ✅ | 读 `REG_CHIPLET_ID`；sideband 上 DISCOVER/ID 握手 |
| error reporting | ✅ | 读 `REG_ERR_A` / `REG_ERR_B`（CRC 错 / NAK / 重传） |
| test and debug | ⚠️ 最小落点 | 写 `REG_CTRL[0]` 远程请求重训 |
| 状态查询（manageability 基础） | ✅ | 读 `REG_LINK_STATUS`（LTSSM 态 / active / 有效 lane / 修复标志） |
| initialization / firmware download / power & thermal / telemetry / log & crash dump / self-test / security | ❌ **未做** | 见 §9.5 |

### 9.3 寄存器映射（**自定**，非规范定义）

| 地址 | 名称 | 属性 | 内容 |
| --- | --- | --- | --- |
| `0x00` | `CHIPLET_ID` | RO | `[7:0]` chiplet 标识（0xA0）/ `[15:8]` 管理通道版本（0x20） |
| `0x01` | `LINK_STATUS` | RO | `[3:0]` LTSSM 态 / `[4]` link_active / `[12:5]` 有效 lane 数 / `[13]` repair_used |
| `0x02` | `ERR_A` | RO | `[15:0]` a_crc_err / `[31:16]` a_retry |
| `0x03` | `ERR_B` | RO | `[15:0]` b_crc_err / `[31:16]` a_nak_sent |
| `0x04` | `CTRL` | RW | `[0]` 远程重训请求 / `[1]` 发起一次发现（自清） |
| `0x05` | `SCRATCH` | RW | 读写回环，用于验证写通路真的通 |

访问模型：`req_valid` + **`req_we`（1=写 / 0=读）** + `req_addr` + `req_wdata`
→ `resp_rdata` + `resp_valid`（请求后一拍脉冲）。

> **踩过的两个真缺陷（不是笔误，是接口语义不全）**：
> 1. **缺读写方向信号 → 读操作顺带写寄存器**：最初写通路只判 `req_valid && addr 匹配`，
>    于是 `mgmt_read` 拉 `req_valid` 时用 `req_wdata=0` 把刚写的值清零（实测读回 `0x00000000`）。
>    补 `req_we` 后修复。
> 2. **环回结构下的发现死锁**：sideband 在顶层环回，而端点只在"收到 DISCOVER"时才发送，
>    没有任何一方主动发起 → 双方永远互等。补 `REG_CTRL[1]`（发起一次发现）后修复。

### 9.4 跨 die 发现的消息编码（**自定**）

| 码 | 含义 |
| --- | --- |
| `0xD0` | `MGMT_MSG_DISCOVER`（请求对端上报身份） |
| `0xD1` | `MGMT_MSG_ID`（身份响应） |

侧带与 LTSSM 共用同一物理通道（本 demo 里是**顶层环回**），但消息码空间独立。

### 9.5 明确未覆盖 / 与真实规范的差距

| 项 | 现状 |
| --- | --- |
| 寄存器地址与字段定义 | **自定** —— 规范定义在会员制全文里，本机没有 |
| 消息格式与握手时序 | **自定** |
| firmware download / 遥测 / 电源热管理 / 日志与崩溃转储 / 自检 / 安全 | **未实现** |
| 外部接口桥接（SMBus / PCIe） | 只建模了"下游请求"的抽象接口，**没有真实 SMBus/PCIe 桥** |
| **CTS / 互操作验证** | 未做 —— 需要真实对端设备，属**验证**环节而非设计环节 |

### 9.6 复现

```bash
make mgmt    # 管理通道骨架验证（12 项检查：discovery / status / error / 写通路 / 发现握手）
```
