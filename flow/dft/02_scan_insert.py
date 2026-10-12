#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DFT Stage 02 · SCAN 串链（mux-D scan insertion）
=============================================================================
移植自 backend/flow/dft/02_scan_insert.py（原项目：SKY130 + tinyNPU）。

**保留自原流程**：
  - 测试点插入（观测点）：给"既非 FF-D、也非顶层输出"的高扇出内部网加 test-only
    DFF 采样，并串入扫描链 —— 这是提升覆盖率的标准手段
  - mux-D 串链：D <- scan_en ? SI : D
  - 外科手术式网表改写（只替换必要片段，其余文本逐字节保留）
  - 链完整性验证 TB：内置**独立参考移位模型**，与 yosys 门级行为仿真结果比对

**与原流程的差异（Nangate45 适配）**：
  - 单元名：sky130_fd_sc_hd__* -> Nangate45（DFF_X1 / MUX2_X1 / ...）
  - mux 引脚：A0/A1/S/X -> **A/B/S/Z**
  - **整块去掉复位门控与复位去耦**：Nangate45 的 DFF_X1 是纯 D 触发器（CK/D/Q/QN），
    **没有异步复位引脚**，原流程中"RESET_B != rst_n 的 DFF 需在 scan_en 期门控复位"
    的问题在此不存在（综合时已用 async2sync 把异步复位转成同步逻辑）
  - DFF 数不硬编码（原版 assert 713），按网表实际统计

用法：DFT_TOP=ucie_ltssm python3 flow/dft/02_scan_insert.py
输出：build/dft/02_scan/<TOP>_scan.v + scan_stats.json + tb_scan_shift.v
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
TOP = os.environ.get("DFT_TOP", "ucie_ltssm")
SRC = os.path.join(ROOT, "build/dft/01_synth", f"{TOP}_netlist.v")
OUT = os.path.join(ROOT, "build/dft/02_scan")
LIB = os.environ.get(
    "UCIE_LIB",
    os.path.join(ROOT, "resources", "nangate45", "NangateOpenCellLibrary_typical.lib"),
)

NCHAIN = 4
NCYC = 80                    # TB 移位周期数（> 2*max_chain）
MUX_AREA = 1.862             # Nangate45 MUX2_X1
FF_AREA = 4.522              # Nangate45 DFF_X1
TOTAL_AREA = 441.826         # ucie_ltssm 综合面积（build/dft/01_synth/<TOP>_synth.log）
TP_MAX = 12                  # 观测点上限
TP_MIN_FANOUT = 4            # 只挑高扇出网

os.makedirs(OUT, exist_ok=True)
txt = open(SRC, encoding="utf-8").read()

# ============================================================== 解析网表
m = re.search(r"module\s+(\w+)\s*\((.*?)\)\s*;", txt, re.S)
modname, portlist = m.group(1), m.group(2)
ports = [p.strip() for p in portlist.replace("\n", " ").split(",") if p.strip()]

decl = {}
for d, names in re.findall(r"^\s*(input|output)\s+(.*?);", txt, re.M):
    for raw in names.split(","):
        nm = raw.strip().split()
        nm = nm[-1] if nm else ""
        if nm:
            decl[nm] = d
inports = [p for p in ports if decl.get(p) == "input"]
outports = [p for p in ports if decl.get(p) == "output"]

# Nangate45 单元实例：DFF_X1 / MUX2_X1 / NAND2_X1 ...
CELL_RE = re.compile(r"^\s{1,2}([A-Z][A-Za-z0-9_]+)\s+(\S+)\s*\((.*?)^\s*\);", re.M | re.S)
insts = []
for mm in CELL_RE.finditer(txt):
    pins = dict(re.findall(r"\.(\w+)\((.*?)\)", mm.group(3), re.S))
    # 注意：不 strip —— Verilog 转义标识符（\name ）的尾随空格是语法的一部分
    insts.append(dict(type=mm.group(1), name=mm.group(2), pins=pins))

dffs = [i for i in insts if i["type"] == "DFF_X1"]
dffs.sort(key=lambda i: i["name"])
assert len(dffs) > 0, f"{TOP} 综合后没有 DFF_X1 —— 纯组合模块，无法插扫描链"
print(f"[02] 模块 {modname}: {len(insts)} 实例, {len(dffs)} 个 DFF_X1, "
      f"{len(inports)} 输入 / {len(outports)} 输出")

# ============================================================== 测试点插入
# 覆盖率瓶颈：组合逻辑内部节点既不是任何 FF 的 D，也不是顶层输出 —— 其 stuck-at
# 故障传不到伪 PO。标准做法是插观测点：给这类高扇出网各加一个 test-only DFF
# （Q 不参与功能逻辑）采样该网，并把该 DFF 串入扫描链。
fanout = {}
for ins in insts:
    for _p, n in ins["pins"].items():
        k = n.strip()
        if k:
            fanout[k] = fanout.get(k, 0) + 1
observed = set(o.strip() for o in outports)
for d in dffs:
    observed.add(d["pins"].get("D", "").strip())
pi_set = set(inports)
cand = [(c, n) for n, c in fanout.items()
        if c >= TP_MIN_FANOUT and n not in observed and n not in pi_set
        and not n.startswith("{") and "'" not in n and not n[0].isdigit()]
cand.sort(key=lambda x: (-x[0], x[1]))
tp_nets = [n for _c, n in cand[:TP_MAX]]


def vname(net):
    """Verilog 转义标识符（\\ 开头）必须以空白结束，否则 .A(\\u.x), 会被解析成
    标识符 'u.x),' -> 语法错误。统计时 strip 过，这里补回尾随空格。"""
    return net + " " if net.startswith("\\") else net


for i, net in enumerate(tp_nets):
    dffs.append(dict(type="DFF_X1", name=f"tp_obs_{i}",
                     pins={"CK": "clk", "D": vname(net), "Q": f"tp_q_{i}", "QN": f"tp_qn_{i}"}))
print(f"[02] 测试点插入: {len(tp_nets)} 个观测点 "
      f"(候选中 {len(cand)} 个, 阈值 fanout>={TP_MIN_FANOUT}, "
      f"最高扇出 {cand[0][0] if cand else 0})")

# ============================================================== mux-D 替换 + 串链
chain_members = [[] for _ in range(NCHAIN)]
new_mux = []
dff_patch = {}
for k, d in enumerate(dffs):
    c = k % NCHAIN
    j = len(chain_members[c])
    chain_members[c].append(d["name"])
    si = f"scan_in[{c}]" if j == 0 else dffs[k - NCHAIN]["pins"]["Q"]
    new_mux.append((f"{d['name']}_scanmux", "MUX2_X1",
                    {"A": d["pins"]["D"], "B": si, "S": "scan_en",
                     "Z": f"scan_d_{c}_{j}"}))
    dff_patch[d["name"]] = f"scan_d_{c}_{j}"

# ============================================================== 发射网表（外科手术式）
def repl_dff(m):
    name = m.group(2)
    if name in dff_patch:
        body = m.group(3)
        dm = re.search(r"\.D\(([^)]*)\)", body)
        if dm:
            body = body[:dm.start(1)] + dff_patch[name] + body[dm.end(1):]
        return f"{m.group(1)}{body}"
    return m.group(0)


newtxt = re.sub(r"(^\s{1,2}([A-Z][A-Za-z0-9_]+)\s+(\S+)\s*\()(.*?)(?=^\s*\);\)?;)",
                lambda m: repl_dff(m) if m.group(2) == "DFF_X1" else m.group(0),
                txt, flags=re.M | re.S)

# 模块头加 scan 端口
header = f"module {modname}({portlist.strip()}, scan_in, scan_out, scan_en);"
newtxt = re.sub(r"module\s+\w+\s*\(.*?\)\s*;", header, newtxt, count=1, flags=re.S)

# 声明区插入端口与内部 wire
wire_decls = []
for c in range(NCHAIN):
    for j in range(len(chain_members[c])):
        wire_decls.append(f"  wire scan_d_{c}_{j};\n")
for i in range(len(tp_nets)):
    wire_decls.append(f"  wire tp_q_{i};\n")
    wire_decls.append(f"  wire tp_qn_{i};\n")
pos = re.search(r"^\s*(?:input|output)\s", newtxt, re.M).start()
newtxt = newtxt[:pos] + ("  input [%d:0] scan_in;\n  output [%d:0] scan_out;\n  input scan_en;\n"
                         % (NCHAIN - 1, NCHAIN - 1) + "".join(wire_decls)) + newtxt[pos:]

# endmodule 前追加 scan mux + 测试点 DFF + scan_out 驱动
mux_txt = "\n".join(
    "  %s %s (\n%s\n  );" % (ctype, iname,
                              ",\n".join(f"    .{p}({n})" for p, n in pins.items()))
    for iname, ctype, pins in new_mux)
tp_inst_txt = "\n".join(
    "  DFF_X1 tp_obs_%d (\n    .CK(clk),\n    .D(%s),\n    .Q(tp_q_%d),\n    .QN(tp_qn_%d)\n  );"
    % (i, dff_patch[f"tp_obs_{i}"], i, i) for i in range(len(tp_nets)))
so_txt = "".join(
    "  assign scan_out[%d] = %s;\n"
    % (c, dffs[c + NCHAIN * (len(chain_members[c]) - 1)]["pins"]["Q"])
    for c in range(NCHAIN))
endmod = re.search(r"^\s*endmodule", newtxt, re.M).start()
newtxt = newtxt[:endmod] + mux_txt + "\n" + tp_inst_txt + "\n" + so_txt + newtxt[endmod:]
open(os.path.join(OUT, f"{TOP}_scan.v"), "w", encoding="utf-8").write(newtxt)

# ============================================================== stats
lens = [len(cm) for cm in chain_members]
n_mux_added = len(new_mux)
area_over = n_mux_added * MUX_AREA + len(tp_nets) * (MUX_AREA + FF_AREA)
stats = {
    "design": f"{modname} (扫描网表)",
    "method": "mux-D scan (Nangate45 DFF_X1 无异步复位 -> 无需复位门控)",
    "n_dff": len(dffs),
    "n_dff_original": len(dffs) - len(tp_nets),
    "n_chain": NCHAIN,
    "chain_lengths": lens,
    "max_chain": max(lens),
    "min_chain": min(lens),
    "n_mux_added": n_mux_added,
    "n_test_points": len(tp_nets),
    "test_point_note": "观测点：采样既非 FF-D 也非顶层输出的高扇出内部网（test-only DFF，串入扫描链）",
    "no_reset_gating_note": "Nangate45 DFF_X1 为纯 D 触发器（CK/D/Q/QN），无异步复位引脚，"
                            "故原流程的复位门控与复位去耦不需要",
    "area_overhead_um2": round(area_over, 3),
    "total_area_um2": TOTAL_AREA,
    "area_overhead_pct": round(area_over / TOTAL_AREA * 100, 2),
    "n_ports_added": 1 + NCHAIN + NCHAIN,     # scan_en + scan_in[N] + scan_out[N]
    "shift_cycles": max(lens),
    "cell_areas": {"MUX2_X1": MUX_AREA, "DFF_X1": FF_AREA},
}
json.dump(stats, open(os.path.join(OUT, "scan_stats.json"), "w", encoding="utf-8"),
          indent=2, ensure_ascii=False)

# ============================================================== 链完整性 TB
def seq(c):
    """每条链独立的确定性移位序列（不同 LFSR/模式，避免相关性掩盖错误）"""
    if c == 0:
        s, out = 0x5A5A, []
        for _ in range(NCYC):
            out.append(s & 1)
            s = ((s >> 1) | (((s ^ (s >> 2)) & 1) << 14))
        return out
    if c == 1:
        return [t & 1 for t in range(NCYC)]
    if c == 2:
        return [int(b) for b in "10100101"] * (NCYC // 8 + 1)
    s, out = 0x39, []
    for _ in range(NCYC):
        out.append(s & 1)
        s = ((s >> 1) | (((s ^ (s >> 1)) & 1) << 6))
    return out


seql = [seq(c)[:NCYC] for c in range(NCHAIN)]
tb = ["module tb_scan_shift;", "  reg clk = 0;", "  reg scan_en = 1;",
      f"  reg [{NCHAIN-1}:0] scan_in = 0;", f"  wire [{NCHAIN-1}:0] scan_out;",
      "  integer t = 0;", "  integer tchk = 0;", "  integer err = 0;"]
for c in range(NCHAIN):
    tb.append("  reg [%d:0] seq%d = %d'b%s;" % (
        NCYC - 1, c, NCYC, "".join(str(b) for b in reversed(seql[c]))))
conn = [".clk(clk)", ".rst_n(1'b1)", ".scan_en(scan_en)",
        ".scan_in(scan_in)", ".scan_out(scan_out)"]
conn += [f".{p}(_w_{i})" for i, p in enumerate(outports)]
conn += [f".{p}(1'b0)" for p in inports if p not in ("clk", "rst_n")]
for i in range(len(outports)):
    tb.append(f"  wire _w_{i};")
tb.append(f"  {modname} dut (" + ", ".join(conn) + ");")
tb.append("  always #1 clk = ~clk;")
tb.append("  // 激励: negedge 施加 seq[t] (下一 posedge 捕获)")
tb.append("  always @(negedge clk) begin")
tb.append(f"    if (t < {NCYC}) begin")
for c in range(NCHAIN):
    tb.append(f"      scan_in[{c}] = seq{c}[t];")
tb.append("      t = t + 1;")
tb.append("    end")
tb.append("  end")
tb.append("  // 独立参考模型: tchk=N 时 scan_out 为 N-1 周期捕获值 = seq[N-(L+2)]")
tb.append("  always @(negedge clk) begin")
tb.append("    tchk = tchk + 1;")
for c in range(NCHAIN):
    L = lens[c]
    tb.append(f"    if (tchk >= {L+2} && tchk <= {NCYC+2} && scan_out[{c}] !== seq{c}[tchk-{L+2}]) begin")
    tb.append(f'      $display("FAIL chain{c} tchk=%0d exp=%0b got=%0b", tchk, seq{c}[tchk-{L+2}], scan_out[{c}]);')
    tb.append("      err = err + 1;")
    tb.append("    end")
tb.append("  end")
tb.append("  initial begin")
tb.append(f"    #{2*NCYC + 40};")
tb.append('    if (err == 0) $display("SCAN_CHAIN_SHIFT_ALL_PASS");')
tb.append('    else $display("SCAN_CHAIN_SHIFT_FAIL err=%0d", err);')
tb.append("  end")
tb.append("endmodule")
open(os.path.join(OUT, "tb_scan_shift.v"), "w", encoding="utf-8").write("\n".join(tb) + "\n")

# ============================================================== 链验证: yosys sim
os.chdir(OUT)
ys = (f"read_verilog {TOP}_scan.v; read_liberty -ignore_miss_func {LIB}; "
      f"read_verilog tb_scan_shift.v; hierarchy -top tb_scan_shift -check; proc; "
      f"sim -clock clk -n {2*NCYC + 60}")
r = subprocess.run(["yosys", "-Q", "-p", ys], capture_output=True, text=True)
log = r.stdout + r.stderr
open("chain_sim.log", "w", encoding="utf-8").write(log)

passed = "SCAN_CHAIN_SHIFT_ALL_PASS" in log
failed = "SCAN_CHAIN_SHIFT_FAIL" in log
chain_verify = {
    "sim": f"yosys sim（liberty 行为模型，{NCYC} 周期移位）",
    "result": "PASS" if (passed and not failed) else "FAIL",
    "note": "TB 内置独立参考移位模型（4 条链各自的 LFSR/模式序列），与门级行为仿真逐拍比对",
    "tail": log.strip().split("\n")[-3:],
}
json.dump(chain_verify, open("chain_verify.json", "w", encoding="utf-8"),
          indent=2, ensure_ascii=False)

print(f"[02] 扫描链: {NCHAIN} 条, 长度 {lens}, 新增 mux {n_mux_added}, "
      f"面积开销 {stats['area_overhead_um2']} um^2 ({stats['area_overhead_pct']}%)")
print(f"[02] 链验证: {chain_verify['result']}  ({chain_verify['tail']})")
print(json.dumps(stats, indent=2, ensure_ascii=False))

if chain_verify["result"] != "PASS":
    sys.exit(1)
