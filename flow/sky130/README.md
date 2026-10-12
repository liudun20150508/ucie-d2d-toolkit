# flow/sky130/ — SKY130 门级仿真 / 等价检查脚本链

## 这是哪部分

本目录是 UCIe demo 的 **SKY130 门级 / 时序后仿**脚本，分两类：

| 类别 | 文件 | 是否接入 demo |
| --- | --- | --- |
| **UCIe demo 的可执行一环** | `apr_ltssm_sdf.tcl`、`ltssm_sdf_models.v`、`postapr_gatesim.sh`、`tb_ltssm_sdf.v`、`ltssm.sdc` | ✅ 是 |
| **来源示例(picorv32)的 LEC/门级参考流程**（复用） | `lec.ys`、`gold_gen.ys`、`postapr_lec.sh`、`reverse_map*.v`、`sky130_map.v`、`sky130_gatesim*.v`、`gen_*.py`、`synth*.ys/tcl` | ❌ 否（参考用） |

## 可执行一环：`make sdf`（SDF 时序后仿）

链路：`apr_ltssm_sdf.tcl`（OpenROAD APR）→ `write_sdf` 产出
`build/sdf/ucie_ltssm_apr.v` + `build/sdf/ucie_ltssm.sdf` → `postapr_gatesim.sh`
用 Icarus `-gspecify` 编译 + `$sdf_annotate` 反标后仿真。

- **判定**：日志出现 `PASS: SDF 时序后仿跑通` 即通过。
- **诚实边界（实测）**：Icarus 13.0 反标 IOPATH(单元延迟)+INTERCONNECT(互连延迟) ✅；
  但不支持 `$setup/$hold/$width` **动态** timing check（-g2005/-g2009/-g2012/-g2005-sv
  均报 "Timing checks are not supported"）。setup/hold 的**静态**签核由 OpenSTA 完成
  （`make sta`，报 WNS/TNS/VIOLATED），这里缺的只是动态 timing check 这一补充手段。
- **用法**（项目根目录）：`make sdf`，或 `sh flow/sky130/postapr_gatesim.sh`。

## 参考流程（不接入 demo）

`lec.ys` / `gold_gen.ys` / `postapr_lec.sh` 是一套 **"APR 前后 Yosys LEC"** 的方法
示例，来源是一个 picorv32 后端示例项目，原样保留以展示完整方法链（综合网表 vs
布线后网表 → 剥离物理单元 → equiv_simple/equiv_induct）。它们**针对 picorv32**、
不是 UCIe 链路：UCIe 的功能等价由 `make gatesim` 覆盖、时序后仿由 `make sdf` 覆盖。
复现需自备 picorv32 RTL 与 OpenROAD-flow-scripts 环境（见各脚本头部注释）。

`gen_gatesim.py` / `gen_reverse_map.py` 从 SKY130 `.lib.json` 自动生成组合单元的功能
Verilog 模型；`.lib.json`（skywater-pdk cell JSON）**未随包分发**，需自备并放到
`resources/sky130/cells/`（脚本头部已注明）。
