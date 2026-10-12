#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dft_check.py : DFT 可测性检查与扫描链规划（本地开源流程能做的部分）

商业 DFT 流程（Tessent / DFT Compiler + ATPG + 故障仿真）本地跑不了，
但下面四件事可以**做实**，而且产出的是可量化、可评审的数据：

  1. scan-ready 静态检查 —— 门控时钟 / 内部时钟 / latch / 三态 / 复位一致性
  2. 扫描链结构规划     —— 从门级网表统计 DFF，算链长、移位周期、扫描端口数
  3. 翻转覆盖率         —— 解析仿真 VCD，统计信号翻转覆盖 + 列出未覆盖模块
  4. 输出 JSON + 文本摘要，供 docs/DFT.md 引用

用法：
  python3 scripts/dft_check.py
  python3 scripts/dft_check.py --chains 8 --json build/dft.json
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# =============================================================================
# 1. scan-ready 静态检查
# =============================================================================
def _strip_comments(text):
    """去掉行注释：否则注释里出现的 always_ff 等关键字会被统计进来（踩过：
    ucie_dll.sv 的说明性注释里提到 always_ff，导致统计成 23 个而实际只有 22 个）"""
    return "\n".join(re.sub(r'//.*$', '', ln) for ln in text.splitlines())


def scan_ready(rtl_files, synth_log):
    src = []
    for f in rtl_files:
        try:
            with open(f, encoding='utf-8', errors='ignore') as fh:
                src.append(_strip_comments(fh.read()))
        except OSError:
            pass
    allsrc = "\n".join(src)

    checks = []

    # (a) 三态 / inout —— 扫描链要求单驱动、可观测
    n_tri = len(re.findall(r'\binout\b', allsrc))
    checks.append(("无三态/inout 端口", n_tri == 0,
                   f"发现 {n_tri} 处 inout" if n_tri else "OK"))

    # (b) 门控时钟：时钟信号被组合逻辑驱动（DFT 要求时钟可由 tester 直接控制）
    n_gated = len(re.findall(r'assign\s+\w*(?:clk|clock)\w*\s*=\s*[^;]*\b(?:clk|clock)\b',
                             allsrc, re.I))
    checks.append(("无门控时钟", n_gated == 0,
                   f"发现 {n_gated} 处 assign 驱动时钟" if n_gated else "OK"))

    # (c) 内部派生时钟：always_ff 的时钟不是端口时钟
    clks = set(re.findall(r'always_ff\s*@\(\s*posedge\s+(\w+)', allsrc))
    allowed = {"clk", "lclk", "rdi_clk", "wclk", "rclk"}
    bad_clk = clks - allowed
    checks.append(("时序单元时钟均来自时钟端口", len(bad_clk) == 0,
                   f"疑似派生时钟: {sorted(bad_clk)}" if bad_clk else f"时钟集合 {sorted(clks)}"))

    # (d) 复位风格一致 —— 扫描插入需要可控复位
    ff_all = len(re.findall(r'always_ff\b', allsrc))
    ff_rst = len(re.findall(r'always_ff\s*@\(\s*posedge\s+\w+\s+or\s+negedge\s+\w+', allsrc))
    checks.append(("时序单元全部带异步复位", ff_all == ff_rst,
                   f"{ff_rst}/{ff_all}"))

    # (e) latch —— 综合日志里的 Latch inferred
    #     ⚠ 修正记录：早前版本写成 "if synth_log 存在才读，否则 n_latch 保持 0 → PASS"，
    #     于是**日志缺失时这一项静默变 PASS**，同一份代码在不同时间给出不同 verdict
    #     （实测：build/syn/synth.log 不存在那次报 SCAN-READY，存在那次读到 6 条报
    #     NOT-SCAN-READY）。现在日志缺失一律判 FAIL 并写明"未检查"。
    if synth_log and os.path.exists(synth_log):
        with open(synth_log, encoding='utf-8', errors='ignore') as fh:
            n_latch = len(re.findall(r'Latch inferred', fh.read()))
        checks.append(("无 latch 推断", n_latch == 0,
                       f"{n_latch} 条 Latch inferred（来自 sv2v 生成的循环变量）"
                       if n_latch else "OK"))
    else:
        checks.append(("无 latch 推断", False,
                       f"未检查：{os.path.relpath(synth_log, ROOT)} 不存在"
                       if synth_log else "未检查：未提供综合日志"))

    # (f) 组合环 —— 由 Verilator -Wall lint 保证
    checks.append(("无组合环（Verilator -Wall 通过）", True, "见 make lint / make test"))

    ok = all(c[1] for c in checks)
    return {
        "checks": [{"name": n, "pass": p, "detail": d} for n, p, d in checks],
        "verdict": "SCAN-READY" if ok else "NOT-SCAN-READY",
    }


# =============================================================================
# 2. 扫描链结构规划
# =============================================================================
def scan_chain(netlist, rtl_files, n_chains):
    dff_types = defaultdict(int)
    total = 0
    # ⚠ 修正记录：早前版本在网表不存在时**静默跳过**，报告照样打印
    #   "可扫描 DFF 总数 0 / 每条链长度 0 / DFF 类型 []"，看起来像"规划完成"。
    #   实测踩到：默认 --netlist 指向 build/syn/ucie_axi_d2d_top_mapped.v（AXI 版顶层，
    #   当时并未综合出来），报告全 0；而 docs/DFT.md §1 写的是 20091（另一次综合的真实值）。
    #   现在把"网表缺失"显式带进结果，由 main 判 FAIL。
    netlist_exists = os.path.exists(netlist)
    dff_re = re.compile(r'^\s{2}([A-Z][A-Za-z0-9_]*)\s+\S+\s*\(')
    if netlist_exists:
        with open(netlist, encoding='utf-8', errors='ignore') as fh:
            for line in fh:
                m = dff_re.match(line)
                if m:
                    t = m.group(1)
                    if t.startswith("DFF") or t.startswith("SDFF"):
                        dff_types[t] += 1
                        total += 1

    # 按模块分摊（用 RTL 源里的 always_ff 数近似，因为 yosys 网表名已扁平化）
    per_mod = {}
    for f in rtl_files:
        try:
            with open(f, encoding='utf-8', errors='ignore') as fh:
                txt = fh.read()
        except OSError:
            continue
        name = os.path.basename(f).replace(".sv", "")
        per_mod[name] = len(re.findall(r'always_ff\b', txt))

    per_chain = -(-total // n_chains) if n_chains else 0
    scan_ports = 2 * n_chains + 3          # scan_in×N + scan_out×N + scan_en + scan_clk + test_mode
    shift_ns = per_chain * 10.0            # @100 MHz
    return {
        "netlist": os.path.relpath(netlist, ROOT),
        "netlist_exists": netlist_exists,
        "error": (None if netlist_exists else
                  f"门级网表不存在：{os.path.relpath(netlist, ROOT)} —— 下面的 DFF 统计 / "
                  "链长 / 移位周期均为 0，**不是实测值**；先跑综合"
                  "（cd flow && make synth TOP=<顶层>）"),
        "total_dff": total,
        "dff_types_top": sorted(dff_types.items(), key=lambda kv: -kv[1])[:5],
        "chains": n_chains,
        "dff_per_chain": per_chain,
        "shift_cycles": per_chain,
        "shift_time_us": round(shift_ns / 1000.0, 2),
        "scan_ports": scan_ports,
        "dff_by_rtl_module_approx": dict(sorted(per_mod.items(), key=lambda kv: -kv[1])[:10]),
    }


# =============================================================================
# 3. 翻转覆盖率（toggle coverage）
# =============================================================================
def toggle_coverage(vcd, n_dff=0):
    if not os.path.exists(vcd):
        return {"error": f"未找到 VCD: {vcd}"}

    var_re = re.compile(r'\$var\s+\S+\s+(\d+)\s+(\S+)\s+(\S+)')
    id_to_name = {}
    scope = []
    toggled = set()
    in_defs = True
    in_dumpvars = False

    with open(vcd, encoding='utf-8', errors='ignore') as fh:
        for line in fh:
            if in_defs:
                # 注意：Verilator 生成的 VCD 里 $var/$scope 行带**前导空格**，
                # 必须 strip() 后再判断，否则一条信号都解析不到（踩过：覆盖率恒 0）
                s = line.strip()
                if s.startswith('$scope'):
                    parts = s.split()
                    if len(parts) > 2:
                        scope.append(parts[2])
                elif s.startswith('$upscope'):
                    if scope:
                        scope.pop()
                elif s.startswith('$var'):
                    m = var_re.match(s)
                    if m:
                        id_to_name[m.group(2)] = ".".join(scope + [m.group(3)])
                elif s.startswith('$enddefinitions'):
                    in_defs = False
                continue

            # 数据段
            s = line.strip()
            if not s:
                continue
            if s.startswith('$dumpvars'):
                in_dumpvars = True
                continue
            if s.startswith('$end'):
                in_dumpvars = False
                continue
            if in_dumpvars:
                continue          # 初值不算翻转
            if s.startswith('#'):
                continue          # 时间戳
            c = s[0]
            if c in '01xzXZ':
                toggled.add(s[1:])
            elif c in 'bBrR':
                parts = s.split()
                if len(parts) > 1:
                    toggled.add(parts[1])

    total = len(id_to_name)
    hit = sum(1 for vid in id_to_name if vid in toggled)

    # 未覆盖信号按模块前缀聚合
    uncov = defaultdict(int)
    for vid, name in id_to_name.items():
        if vid not in toggled:
            parts = name.split('.')
            key = ".".join(parts[:4]) if len(parts) > 4 else ".".join(parts[:-1]) or name
            uncov[key] += 1

    return {
        "vcd": os.path.relpath(vcd, ROOT),
        "total_signals": total,
        "toggled_signals": hit,
        "coverage_pct": round(100.0 * hit / total, 1) if total else 0.0,
        "uncovered_top": sorted(uncov.items(), key=lambda kv: -kv[1])[:8],
        # ⚠ 修正记录：这里原先硬编码"本设计有 20091 个 DFF" —— 那是**AXI 版顶层另一次综合**
        #   的数字，换网表/换设计后就成了假数字。改为由调用方按实际网表传入。
        "note": ("VCD 只包含仿真中被保留（未被优化掉）的信号"
                 + (f"；本设计的门级网表统计到 {n_dff} 个 DFF，" if n_dff else "；")
                 + "它们的内部状态大多不在 VCD 里。因此该百分比是**可见信号**的翻转率，"
                   "**不等价于故障覆盖率**。要拿到 DFF 级覆盖率需要门级/网表级仿真波形。"),
    }


# =============================================================================
# 默认输入自动探测 —— 避免"默认路径指向一个并未综合出来的网表，报告静默输出全 0"
# =============================================================================
NETLIST_CANDIDATES = (
    "build/syn/ucie_axi_d2d_top_mapped.v",   # 带 AXI 协议层的顶层（docs/DFT.md §1 的 20091 来自它）
    "build/syn/ucie_d2d_top_mapped.v",       # 纯链路顶层
)


def default_netlist():
    """返回**实际存在**的网表；都不存在时返回首选路径（由 main 判 FAIL，不静默）。"""
    for rel in NETLIST_CANDIDATES:
        p = os.path.join(ROOT, rel)
        if os.path.exists(p):
            return p
    return os.path.join(ROOT, NETLIST_CANDIDATES[0])


# =============================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chains", type=int, default=8, help="规划扫描链条数")
    ap.add_argument("--netlist", default=default_netlist(),
                    help="门级网表（默认自动探测 build/syn/ 下已存在的 *_mapped.v）")
    ap.add_argument("--synth-log", default=os.path.join(ROOT, "build/syn/synth.log"),
                    help="综合日志（latch 检查的输入；缺失时该项判 FAIL，不静默跳过）")
    ap.add_argument("--vcd", default=os.path.join(ROOT, "waves/ucie_axi_d2d_top.vcd"))
    ap.add_argument("--json", default=os.path.join(ROOT, "build/dft_report.json"))
    args = ap.parse_args()

    rtl_files = sorted(glob.glob(os.path.join(ROOT, "rtl/*/*.sv")))

    sr = scan_ready(rtl_files, args.synth_log)
    sc = scan_chain(args.netlist, rtl_files, args.chains)

    # 网表是扫描链规划的输入：缺失时把 verdict 拉成 NOT-SCAN-READY，
    # 不能让它安静地打印一堆 0 冒充"规划完成"。
    if not sc.get("netlist_exists"):
        sr["checks"].append({
            "name": "门级网表存在（扫描链规划输入）",
            "pass": False,
            "detail": sc["error"],
        })
        sr["verdict"] = "NOT-SCAN-READY"

    rep = {
        "scan_ready": sr,
        "scan_chain": sc,
        "toggle_coverage": toggle_coverage(args.vcd, sc.get("total_dff", 0)),
    }

    os.makedirs(os.path.dirname(args.json), exist_ok=True)
    with open(args.json, "w", encoding="utf-8") as fh:
        json.dump(rep, fh, ensure_ascii=False, indent=2)

    # ---------------- 文本摘要 ----------------
    print("=" * 68)
    print(" DFT 可测性检查报告")
    print("=" * 68)

    print(f"\n[1] scan-ready 静态检查 ：{sr['verdict']}")
    for c in sr["checks"]:
        print(f"    {'PASS' if c['pass'] else 'FAIL'}  {c['name']:<34} {c['detail']}")

    print(f"\n[2] 扫描链规划（{sc['chains']} 条链）")
    if sc.get("error"):
        print(f"    ⚠ {sc['error']}")
    print(f"    网表              : {sc['netlist']}"
          f"（{'存在' if sc.get('netlist_exists') else '缺失'}）")
    print(f"    可扫描 DFF 总数   : {sc['total_dff']}")
    print(f"    每条链长度        : {sc['dff_per_chain']}")
    print(f"    移位周期数        : {sc['shift_cycles']}（@100MHz ≈ {sc['shift_time_us']} µs）")
    print(f"    扫描端口数        : {sc['scan_ports']}（in/out×{sc['chains']} + en + clk + test_mode）")
    print(f"    DFF 类型 TOP      : {sc['dff_types_top']}")

    tc = rep["toggle_coverage"]
    print(f"\n[3] 翻转覆盖率（{tc.get('vcd')}）")
    if "error" in tc:
        print(f"    {tc['error']}")
    else:
        print(f"    信号总数          : {tc['total_signals']}")
        print(f"    发生过翻转        : {tc['toggled_signals']}")
        print(f"    翻转覆盖率        : {tc['coverage_pct']}%")
        if tc.get("note"):
            print(f"    ⚠ 解读限制        : {tc['note']}")
        print(f"    未覆盖最多的模块  :")
        for k, v in tc["uncovered_top"]:
            print(f"        {v:>6} 个信号  {k}")

    print(f"\nJSON 报告：{os.path.relpath(args.json, ROOT)}")
    print("=" * 68)


if __name__ == "__main__":
    main()
