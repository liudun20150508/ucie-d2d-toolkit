#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DFT Demo · Stage 03  ATPG 生成 + 故障模拟 + 模式仿真验证
方向: 数字中端综合/DFT (能力点: ATPG 仿真)
引擎: 纯 Python 自研 ATPG
  - 故障模型: stuck-at-0/1 (全引脚故障集)
  - 随机模式: 并行故障模拟 PFS (bit-parallel)
  - 确定性:   PODEM (3值X仿真 + D-frontier + 回溯)
  - 自检:     --selftest 与暴力穷举交叉验证
  - 仿真:     导出模式 -> yosys sim 门级仿真 (ATPG仿真)
输入: build/dft/02_scan/<TOP>_scan.v + Nangate45 liberty
输出: build/dft/03_atpg/
"""
import re, json, os, sys, random, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
# ---- 移植适配：UCIe 子模块 + Nangate45（原版：tinyNPU + SKY130）----
TOP  = os.environ.get("DFT_TOP", "ucie_ltssm")
SCAN = os.path.join(ROOT, "build/dft/02_scan", f"{TOP}_scan.v")
LIB  = os.environ.get(
    "UCIE_LIB",
    os.path.join(ROOT, "resources", "nangate45", "NangateOpenCellLibrary_typical.lib"))
OUT  = os.path.join(ROOT, "build/dft/03_atpg")
NPAT = 512
NCAP = 1            # capture 周期数 (多 cycle capture: 1 = 标准单周期)
DENSITY = 1.0       # 模式随机密度: 1.0 = 所有 PI 随机; <1 时其余 PI 置 0
SEED = 20260831
PODEM_MAX = 200

# ================================================================ liberty
class BoolExpr:
    def __init__(self, expr, pins):
        self.pins = pins
        toks = re.findall(r"[!&|^()]|[A-Za-z_]\w*", expr)
        self.toks = toks; self.pos = 0
        self.tree = self.parse_or()
    def peek(self): return self.toks[self.pos] if self.pos < len(self.toks) else None
    def nxt(self): self.pos += 1; return self.toks[self.pos-1]
    def parse_or(self):
        v = self.parse_xor()
        while self.peek() == "|": self.nxt(); v = ("|", v, self.parse_xor())
        return v
    def parse_xor(self):
        v = self.parse_and()
        while self.peek() == "^": self.nxt(); v = ("^", v, self.parse_and())
        return v
    def parse_and(self):
        v = self.parse_not()
        while self.peek() == "&": self.nxt(); v = ("&", v, self.parse_not())
        return v
    def parse_not(self):
        if self.peek() == "!":
            self.nxt(); return ("!", self.parse_not())
        if self.peek() == "(":
            self.nxt(); v = self.parse_or(); self.nxt(); return v
        return self.nxt()
    def eval(self, vals):
        def go(node):
            if isinstance(node, str):
                return vals[node] & 1
            op = node[0]
            if op == "!": return go(node[1]) ^ 1
            if op == "&": return go(node[1]) & go(node[2])
            if op == "|": return go(node[1]) | go(node[2])
            return go(node[1]) ^ go(node[2])
        return go(self.tree)

def parse_liberty(path):
    txt = open(path).read()
    cells = {}
    i = 0
    while True:
        m = re.search(r'cell\s*\(["\']?([A-Za-z_]\w*)["\']?\)\s*\{', txt[i:])
        if not m:
            break
        name = m.group(1)
        start = i + m.end()
        depth = 1
        j = start
        while j < len(txt) and depth > 0:
            if txt[j] == '{':
                depth += 1
            elif txt[j] == '}':
                depth -= 1
            j += 1
        body = txt[start:j-1]
        i = j
        fn = re.search(r'function\s*:\s*"([^"]*)"', body)
        if not fn:
            continue
        pins = []
        # pin 名的引号形式随库而异：sky130 是 `pin ("A") {`，Nangate45 是 `pin (A1) {`。
        # 原正则只认带引号的写法，在 Nangate45 下解析出 0 个单元（踩过：liberty cells: 0）。
        for pm in re.finditer(r'(?<![\w])pin\s*\(["\']?(\w+)["\']?\)\s*\{', body):
            pname = pm.group(1)
            d = 1
            k = pm.end()
            while k < len(body) and d > 0:
                if body[k] == '{':
                    d += 1
                elif body[k] == '}':
                    d -= 1
                k += 1
            pblk = body[pm.end():k-1]
            # direction 的引号形式同样随库而异：sky130 是 `direction : "input";`，
            # Nangate45 是 `direction : input;`（无引号）。原正则只认带引号写法 ->
            # 每个 pin 的 direction 取不到 -> pins 全空 -> len(outs)!=1 ->
            # 每个 cell 都被 continue -> liberty cells: 0（踩过）。
            dm = re.search(r'direction\s*:\s*["\']?(\w+)["\']?', pblk)
            if dm:
                pins.append((pname, dm.group(1)))
        outs = [p for p, d in pins if d == "output"]
        ins  = [p for p, d in pins if d == "input"]
        if len(outs) != 1 or not ins:
            continue
        try:
            cells[name] = (outs[0], ins, BoolExpr(fn.group(1), ins))
        except Exception:
            pass
    return cells

# ================================================================ netlist
def parse_assigns(t):
    const_vec, alias_vec, bit_map = {}, {}, {}
    for m in re.finditer(r"^\s*assign\s+(.+?);", t, re.M):
        a = m.group(1)
        mm = re.match(r"^\s*(\S+)\s*=\s*(.+?)\s*$", a)
        if not mm:
            continue
        lhs, rhs = mm.group(1).strip(), mm.group(2).strip()
        if re.fullmatch(r"\d+'[bhd][0-9x]+", rhs):
            const_vec[lhs] = rhs
        elif re.fullmatch(r"(\\\S+|[A-Za-z_]\w*)(\s*\[\d+(:\d+)?\])?", rhs):
            alias_vec[lhs] = rhs
        elif "{" in rhs:
            bit_map.update(parse_concat(lhs, rhs))
    return const_vec, alias_vec, bit_map

def parse_concat(lhs, rhs):
    out = {}
    parts = re.findall(r"([^{},]+)", rhs)
    expanded = []
    for p in parts:
        p = p.strip()
        mm = re.fullmatch(r"\d+'[bhd]([0-9x]+)", p)
        if mm:
            nbits = len(mm.group(1))
            for b in range(nbits):
                expanded.append(("c", mm.group(1)[nbits-1-b]))
        else:
            pm = re.fullmatch(r"(\\\S+|[A-Za-z_]\w*)\s*\[\s*(\d+)\s*\]", p)
            if pm:
                expanded.append(("n", (pm.group(1), int(pm.group(2)))))
            else:
                return out
    lm = re.fullmatch(r"(\\\S+|[A-Za-z_]\w*)\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]", lhs)
    if lm:
        base, msb, lsb = lm.group(1), int(lm.group(2)), int(lm.group(3))
        for i, (k, v) in enumerate(expanded):
            if lsb + i > msb:
                break
            bit = lsb + i
            out[f"{base}[{bit}]"] = _bit_val(k, v)
    else:
        for i, (k, v) in enumerate(expanded):
            out[f"{lhs}[{i}]"] = _bit_val(k, v)
    return out

def _bit_val(k, v):
    if k == "c":
        return None if v in "xz" else int(v)
    return f"{v[0]}[{v[1]}]"

# ================================================================ 图
class Circuit:
    def __init__(self, gates, lib, const_vec, alias_vec, bit_map, dffs, top_inputs):
        self.lib = lib
        self.const_vec = const_vec
        self.alias = alias_vec
        self.bit_map = bit_map
        self.dffs = dffs
        self.pi_net = set()
        self.po_net = set()
        self.pseudo_pi = {}
        self.pseudo_po = {}
        self.gates = gates            # (type, out, {pin:net}, name)
        # 功能 D = scan mux A0
        mux_a0 = {}
        for (ty, out, ins, name) in gates:
            if name.endswith("_scanmux"):
                mux_a0[out] = ins.get("A0", "")
        self.mux_a0 = mux_a0
        for (name, pins) in dffs:
            q = pins.get("Q", "").strip()
            d = pins.get("D", "").strip()
            if q:
                self.pseudo_pi[q] = name
                self.pi_net.add(q)
            if d:
                self.pseudo_po[name] = mux_a0.get(d, d)
                if self.pseudo_po[name]:
                    self.po_net.add(self.pseudo_po[name])
        for p in top_inputs:
            self.pi_net.add(p)
        # 驱动关系
        self.drivers = {}
        for gi, (ty, out, ins, name) in enumerate(gates):
            self.drivers[out] = gi
    def resolve(self, net):
        net = net.strip()
        # Verilog 字面常量 (如 mux 的 .A1(1'b1)): 单比特常量直接求值,
        # 否则会被当成未驱动网取 0 —— 曾导致 capture 期间复位去耦 mux 被误算成复位有效
        m = re.fullmatch(r"(\d+)'([bBdDhH])([0-9a-fA-FxXzZ_]+)", net)
        if m and int(m.group(1)) == 1:
            v = m.group(3)
            if v in "xXzZ":
                return ("const", None)
            return ("const", int(v, {"b": 2, "d": 10, "h": 16}[m.group(2).lower()]))
        if net in self.const_vec:
            v = self.const_vec[net]
            mm = re.fullmatch(r"\d+'[bhd]([0-9]+)", v)
            if mm and len(mm.group(1)) == 1:
                return ("const", int(mm.group(1)))
            return ("constvec", v)
        if net in self.alias:
            return ("alias", self.alias[net])
        if net in self.bit_map:
            bv = self.bit_map[net]
            if bv is None:
                return ("const", None)
            if isinstance(bv, int):
                return ("const", bv)
            return ("alias", bv)
        return ("net", net)
    def net_name(self, net):
        r = self.resolve(net)
        if r[0] == "net":
            return r[1]
        return None

# ================================================================ 电路构建 (含捕获期复位建模)
def load_circuit(t, lib):
    """解析扫描网表 -> (cir, order, top_inputs)

    - 向量输入展开为逐位 PI
    - 捕获期复位建模: RESET_B 被 _rbgmux 门控的 DFF, 捕获时
      Q' = D & 内部复位网 (复位有效 -> FF 异步复位为 0)。
      以合成 and2_1 门 (rg_and_* 前缀) 插入观测路径, 与门级仿真一致。
      合成门不参与故障生成 (避免与 rbgmux 路径重复计故障)。
    """
    top_inputs = []
    for d, names in re.findall(r"^\s*(input|output)\s+(.*?);", t, re.M):
        for raw in names.split(","):
            parts = raw.strip().split()
            if not parts:
                continue
            nm = parts[-1]
            if d == "input" and nm not in ("clk", "rst_n", "scan_en", "scan_in"):
                # 向量输入展开为逐位 PI (门引脚直接引用位网)
                if len(parts) > 1 and parts[0].startswith("["):
                    m = re.match(r"\[(\d+):(\d+)\]", parts[0])
                    msb, lsb = int(m.group(1)), int(m.group(2))
                    for b in range(min(msb, lsb), max(msb, lsb) + 1):
                        top_inputs.append(f"{nm}[{b}]")
                else:
                    top_inputs.append(nm)
    const_vec, alias_vec, bit_map = parse_assigns(t)
    gates, dffs = [], []
    # Nangate45 单元名（原版为 sky130_fd_sc_hd__*）
    pat = re.compile(r"^\s{1,4}([A-Z][A-Za-z0-9_]+)\s+(\S+)\s*\((.*?)^\s*\);", re.M | re.S)
    for mm in pat.finditer(t):
        ty, name, body = mm.group(1), mm.group(2), mm.group(3)
        pins = {k: v.strip() for k, v in
                dict(re.findall(r"\.(\w+)\((.*?)\)", body, re.S)).items()}
        if ty == "DFF_X1":
            dffs.append((name, pins))
        elif ty in lib:
            out_pin, ins, expr = lib[ty]
            out_net = pins.get(out_pin, "")
            if out_net:
                gates.append((ty, out_net, {p: pins.get(p, "") for p in ins}, name))
    # 捕获期复位建模：原版针对 SKY130 的复位门控（_rbgmux + and2_1 合成门）。
    # Nangate45 适配：DFF_X1 是纯 D 触发器（CK/D/Q/QN），**无异步复位引脚**；
    # ucie_ltssm 综合时已用 async2sync 把异步复位转成同步逻辑，因此不存在
    # "链上寄存器翻转内部复位逻辑"的问题 —— 复位门控与去耦都不需要。
    # 下面保留原逻辑，但以"网表里存在 _rbgmux"为前提，当前不会进入。
    rbg = {}
    if "AND2_X1" in lib and any(n.endswith("_rbgmux") for (_t, _o, _i, n) in gates):
        mux_a0 = {}
        for (ty, out, ins, name) in gates:
            if name.endswith("_scanmux"):
                mux_a0[out] = ins.get("A", "")
            elif name.endswith("_rbgmux"):
                rbg[name[:-len("_rbgmux")]] = ins.get("A", "")
        n_rmodel = 0
        for (ffname, pins) in dffs:
            rst = rbg.get(ffname, "")
            if not rst or rst.strip() == "rst_n":
                continue
            dnet = mux_a0.get(pins.get("D", ""), "")
            if not dnet:
                continue
            rg = f"rg_{ffname}"
            gates.append(("AND2_X1", rg,
                          {"A1": dnet, "A2": rst}, f"rg_and_{ffname}"))
            pins["D"] = rg          # pseudo_po 指向合成门输出
            n_rmodel += 1
        if n_rmodel:
            print(f"capture reset model: {n_rmodel} gated-FF and2 gates added")
    cir = Circuit(gates, lib, const_vec, alias_vec, bit_map, dffs, top_inputs)
    cir.gated_rst = rbg          # {ffname: rbgmux.A0} 子集 (捕获期复位门控)
    cir.ff_rst = {}              # 全部 FF 的异步复位网: rbgmux 已插入的取 A0, 否则取 RESET_B
    for (ffname, pins) in dffs:
        rst = rbg.get(ffname)
        if rst is None:
            rst = pins.get("RESET_B", "").strip()
            if rst in ("rst_n", ""):
                rst = ""             # 外部复位 (仿真中恒 1) 无需建模
        cir.ff_rst[ffname] = rst
    return cir, topo_order(cir), top_inputs

# ================================================================ 拓扑序
def topo_order(cir):
    from collections import deque
    indeg = {}
    adj = {}
    gids = list(range(len(cir.gates)))
    for gi, (ty, out, ins, name) in enumerate(cir.gates):
        for p, n in ins.items():
            src = cir.net_name(n)
            if src and src in cir.drivers and isinstance(cir.drivers[src], int):
                drv = cir.drivers[src]
                adj.setdefault(drv, []).append(gi)
                indeg[gi] = indeg.get(gi, 0) + 1
    q = deque(g for g in gids if indeg.get(g, 0) == 0)
    order = []
    while q:
        g = q.popleft()
        order.append(g)
        for nxt in adj.get(g, []):
            indeg[nxt] -= 1
            if indeg[nxt] == 0:
                q.append(nxt)
    order += [g for g in gids if g not in order]
    return order

# ================================================================ 故障集
def build_faults(cir):
    EXCL_NETS = {"clk", "rst_n", "rst_int_n", "scan_en"}
    def excluded(net):
        n = net.strip()
        return n in EXCL_NETS or (n.endswith("_rbg") and "_rbg" in n)
    faults = []
    for n in sorted(cir.pi_net):
        if excluded(n):
            continue
        for v in (0, 1):
            faults.append((len(faults), f"stem {n}", "stem", n, v))
    for gi, (ty, out, ins, name) in enumerate(cir.gates):
        if name.startswith("rg_and_"):
            continue          # 合成复位建模门不参与故障生成
        for p, n in ins.items():
            if p == "S" and name.endswith(("_scanmux", "_rbgmux")):
                continue
            if p == "A1" and name.endswith(("_scanmux", "_rbgmux")):
                continue
            if excluded(n):
                continue
            for v in (0, 1):
                faults.append((len(faults), f"{name}.{p}", "pin", (gi, p), v))
        if excluded(out):
            continue
        for v in (0, 1):
            faults.append((len(faults), f"{name}.out", "out", gi, v))
    return faults

# ================================================================ 好机仿真
# 捕获期控制网默认值 (与门级 TB 一致): rst_n=1 (复位释放), scan_en=0 (功能捕获)
# 历史 bug: 这两个网被 load_circuit 排除出 PI 列表, 而 val.get(...,0) 使 rst_n 恒为 0,
# 即 ATPG 一直在"复位有效"的假想态下做故障模拟 —— 导致 FC 低估 + PODEM 大量 abort。
CAPTURE_CTRL = {"rst_n": 1, "scan_en": 0}

def good_sim(cir, order, pi_vals):
    val = dict(CAPTURE_CTRL)
    val.update(pi_vals)
    for gi in order:
        ty, out, ins, name = cir.gates[gi]
        _, _, expr = cir.lib[ty]
        args = {}
        for p, n in ins.items():
            r = cir.resolve(n)
            if r[0] == "const":
                args[p] = 0 if r[1] in (None, 0) else 1
            elif r[0] == "net":
                args[p] = val.get(r[1], 0)
            else:
                args[p] = 0
        val[out] = expr.eval(args)
    return val

# ================================================================ 捕获态稳态 (异步复位反馈)
def resolve_val(cir, vals, net):
    r = cir.resolve(net)
    if r[0] == "const":
        return 0 if r[1] in (None, 0) else 1
    if r[0] == "net":
        return vals.get(r[1], 0)
    if r[0] == "alias":
        return resolve_val(cir, vals, r[1])
    return 0

def capture_state(cir, order, pi_vals, max_iter=8, ncap=None):
    """求 capture 之后的自洽状态, 返回 (q_net, q_ff, vals).

    每个 capture 拍分两步 (顺序不能颠倒, 否则会把状态连推多拍):
      1) 本拍内的组合不动点 —— 只做"异步复位一致化": 复位网可能由链上寄存器算出来
         (`rst_int_n = isobufsrc(A=rst_n, SLEEP=reg_ctrl[1])`), 复位有效则 FF 立即清零,
         清零又可能改变复位网 -> 迭代到稳定;
      2) 时钟沿 —— 全部 FF 更新一次: Q <- D & rst。
    重复 ncap 拍: ncap=1 即标准单周期 capture, ncap>1 为多 cycle capture。

    返回的 vals 是**最后一拍沿更新前**的组合值, 供调用方按 S2 = D & rst 取捕获值;
    q_ff 是沿更新后的状态 (捕获后状态), 供故障模拟使用。
    """
    if ncap is None:
        ncap = NCAP
    mux_a0 = cir.mux_a0
    ff_rst = getattr(cir, "ff_rst", {})
    qname = {ff: q for q, ff in cir.pseudo_pi.items()}
    q = {ff: int(pi_vals.get(qname.get(ff, ""), 0)) for (ff, _) in cir.dffs}
    vals = None

    def comb(q):
        pi = dict(pi_vals)
        for ff, v in q.items():
            if qname.get(ff):
                pi[qname[ff]] = v
        return good_sim(cir, order, pi)

    for _cyc in range(max(1, ncap)):
        # 1) 本拍内的复位一致化 (组合不动点)
        for _ in range(max_iter):
            vals = comb(q)
            changed = False
            for (ff, _pins) in cir.dffs:
                rnet = ff_rst.get(ff, "")
                r = resolve_val(cir, vals, rnet) if rnet else 1
                if r == 0 and q.get(ff, 0) != 0:
                    q[ff] = 0
                    changed = True
            if not changed:
                break
        # 2) 时钟沿: 全部 FF 更新一拍
        vals = comb(q)                     # 沿更新前的组合值 -> 捕获值 S2 = D & rst
        q = {ff: (resolve_val(cir, vals, mux_a0.get(p.get("D", "").strip(), p.get("D", "").strip()))
                  & (resolve_val(cir, vals, ff_rst.get(ff, "")) if ff_rst.get(ff) else 1))
             for (ff, p) in cir.dffs}
    q_net = {qname[ff]: v for ff, v in q.items() if qname.get(ff)}
    return q_net, q, vals

# ================================================================ PFS
def pfs(cir, order, pi_vals, faults, ALL, ncap=None):
    # 捕获态先求自洽状态 (含异步复位反馈 / 多 cycle capture), 再做故障模拟
    q_net, _, _ = capture_state(cir, order, pi_vals, ncap=ncap)
    pi_vals = dict(pi_vals)
    pi_vals.update(q_net)
    good = good_sim(cir, order, pi_vals)
    fid2bit = {f[0]: i for i, f in enumerate(faults)}
    pin_stuck = {}
    out_stuck = {}
    stem_stuck = {}
    for f in faults:
        fid, desc, kind, site, v = f
        bit = 1 << fid2bit[fid]
        if kind == "pin":
            d = pin_stuck.setdefault(site, [0, 0]); d[v] |= bit
        elif kind == "out":
            d = out_stuck.setdefault(site, [0, 0]); d[v] |= bit
        else:
            d = stem_stuck.setdefault(site, [0, 0]); d[v] |= bit
    word = {}
    for n in cir.pi_net:
        w = ALL if good.get(n, 0) else 0
        s0, s1 = stem_stuck.get(n, [0, 0])
        word[n] = (w | s1) & ~s0
    for gi in order:
        ty, out, ins, name = cir.gates[gi]
        _, _, expr = cir.lib[ty]
        pins = list(ins.keys())
        in_words = []
        for p in pins:
            n = ins[p]
            r = cir.resolve(n)
            if r[0] == "const":
                in_words.append(ALL if r[1] == 1 else 0)
            elif r[0] == "net":
                in_words.append(word.get(r[1], 0))
            else:
                in_words.append(0)
        n_in = len(pins)
        out_w = 0
        for combo in range(1 << n_in):
            mask = ALL
            for i, p in enumerate(pins):
                bitv = (combo >> i) & 1
                wi = in_words[i]
                s0, s1 = pin_stuck.get((gi, p), [0, 0])
                mask &= (wi | s1) if bitv else ((~wi) | s0)
            if mask:
                args = {p: (combo >> i) & 1 for i, p in enumerate(pins)}
                if expr.eval(args):
                    out_w |= mask
        s0, s1 = out_stuck.get(gi, [0, 0])
        out_w = (out_w | s1) & ~s0
        word[out] = out_w
    detected = 0
    for po in cir.po_net:
        if po not in word:
            continue
        g = good.get(po, 0)
        detected |= (word[po] ^ (ALL if g else 0)) & ALL
    return detected

# ================================================================ PODEM
class Podem:
    """PODEM: 目标激励(故障激活) + D-frontier 传播 + 决策栈回溯。

    - 决策全部落在 PI 上 (PODEM 标准), 冲突 = PI 已赋相反值
    - tsim: 好机/故障机并行 3 值 X 仿真 (stem/pin/out 三种故障注入)
    - 回溯: 栈顶未翻转的决策取反重试; 栈空 -> aborted
    """
    def __init__(self, cir, order, fault, max_decisions=200):
        self.cir = cir; self.order = order
        self.fid, self.desc, self.kind, self.site, self.sv = fault
        self.max_decisions = max_decisions
        self.decisions = 0
        self.stack = []      # [pi, val, flipped]
    def assign_map(self):
        d = {}
        for (pi, v, _) in self.stack:
            d[pi] = v
        return d
    # ---- 门分类 ----
    def gate_kind(self, gi):
        ty, out, ins, name = self.cir.gates[gi]
        _, _, expr = self.cir.lib[ty]
        pins = list(ins.keys())
        n = len(pins)
        f_all1 = expr.eval({p: 1 for p in pins})
        f_all0 = expr.eval({p: 0 for p in pins})
        if n == 1:
            return "INV" if f_all0 == 1 and f_all1 == 0 else "BUF"
        # 控制值探测
        and_like = or_like = False
        for i in range(n):
            a = {p: 0 if j == i else 1 for j, p in enumerate(pins)}
            if expr.eval(a) != f_all1:
                and_like = True
            a = {p: 1 if j == i else 0 for j, p in enumerate(pins)}
            if expr.eval(a) != f_all0:
                or_like = True
        if and_like and not or_like:
            return "NAND" if f_all0 == 1 else "AND"
        if or_like and not and_like:
            return "OR" if f_all1 == 1 else "NOR"
        if and_like and or_like:
            return "XOR"
        return "OTHER"
    def input_val(self, net, vals):
        r = self.cir.resolve(net)
        if r[0] == "const":
            return 0 if r[1] in (None, 0) else 1
        if r[0] == "net":
            return vals.get(r[1], 2)
        return 2
    # ---- 3 值 X 仿真 (好机/故障机并行) ----
    def tsim(self, vals):
        cir = self.cir
        fvals = dict(vals)
        kind, site, sv = self.kind, self.site, self.sv
        for gi in self.order:
            ty, out, ins, name = cir.gates[gi]
            _, _, expr = cir.lib[ty]
            args = {}
            fargs = {}
            for p, n in ins.items():
                gv = self.input_val(n, vals)
                fv = self.input_val(n, fvals)   # 故障机读故障机自身的值
                if kind == "pin" and site == (gi, p):
                    fv = sv
                elif kind == "stem" and cir.net_name(n) == site:
                    fv = sv
                args[p] = gv
                fargs[p] = fv
            gv = _eval3(expr, args)
            fv = _eval3(expr, fargs)
            if kind == "out" and site == gi:
                fv = sv
            vals[out] = gv
            fvals[out] = fv
        return vals, fvals
    # ---- 故障是否已激活 (故障点出现 D) ----
    def excited(self, vals):
        kind, site, sv = self.kind, self.site, self.sv
        cir = self.cir
        if kind == "stem":
            return vals.get(site, 2) == 1 - sv
        if kind == "pin":
            gi, p = site
            ty, out, ins, name = cir.gates[gi]
            g = self.input_val(ins[p], vals)
            return g == 1 - sv
        gi = site
        ty, out, ins, name = cir.gates[gi]
        return vals.get(out, 2) == 1 - sv
    # ---- 激励目标 (故障点取相反值) ----
    def excite_objective(self):
        kind, site, sv = self.kind, self.site, self.sv
        cir = self.cir
        if kind == "stem":
            return (site, 1 - sv)
        if kind == "pin":
            gi, p = site
            ty, out, ins, name = cir.gates[gi]
            return (ins[p], 1 - sv)
        gi = site
        ty, out, ins, name = cir.gates[gi]
        return (out, 1 - sv)
    # ---- D-frontier ----
    def d_frontier(self, vals, fvals):
        kind, site, sv = self.kind, self.site, self.sv
        fr = []
        for gi in self.order:
            ty, out, ins, name = self.cir.gates[gi]
            og, of = vals.get(out, 2), fvals.get(out, 2)
            if og != 2 and of != 2:
                continue          # 输出两侧均已知: D 已被吸收或已在输出上
            has_d = False
            for p, n in ins.items():
                nn = self.cir.net_name(n)
                g = vals.get(nn, 2) if nn else self.input_val(n, vals)
                f = fvals.get(nn, 2) if nn else self.input_val(n, fvals)
                # 故障注入覆盖: 故障引脚在故障机中恒为 sv
                if kind == "pin" and site == (gi, p):
                    f = sv
                elif kind == "stem" and nn == site:
                    f = sv
                if g != 2 and f != 2 and g != f:
                    has_d = True
                    break
            if has_d:
                fr.append(gi)
        return fr
    # ---- 回溯: 目标 (net, want) -> (PI 网名, PI 上的值) ----
    # 值在穿越 NAND/NOR/INV 时取反, 返回值是 PI 端要施加的值
    def backtrace(self, net, want, vals):
        cir = self.cir
        nn = cir.net_name(net)
        if nn is None:
            return None
        if nn in cir.pi_net:
            return (nn, want)
        drv = cir.drivers.get(nn)
        if not isinstance(drv, int):
            return None
        ty, out, ins, name = cir.gates[drv]
        kind = self.gate_kind(drv)
        pins = [p for p in ins.keys()]
        def bt_pin(p, w):
            return self.backtrace(ins[p], w, vals)
        if kind == "INV":
            for p in pins:
                if self.input_val(ins[p], vals) == 2:
                    return bt_pin(p, 1 - want)
            return None
        if kind == "BUF":
            for p in pins:
                if self.input_val(ins[p], vals) == 2:
                    return bt_pin(p, want)
            return None
        if kind == "AND":
            if want == 0:   # 控制: 任一输入 0
                for p in pins:
                    if self.input_val(ins[p], vals) == 2:
                        return bt_pin(p, 0)
                return None
            for p in pins:  # 非控制: 输入 1
                if self.input_val(ins[p], vals) == 2:
                    return bt_pin(p, 1)
            return None
        if kind == "NAND":
            if want == 1:   # 控制: 任一输入 0
                for p in pins:
                    if self.input_val(ins[p], vals) == 2:
                        return bt_pin(p, 0)
                return None
            for p in pins:
                if self.input_val(ins[p], vals) == 2:
                    return bt_pin(p, 1)
            return None
        if kind == "OR":
            if want == 1:
                for p in pins:
                    if self.input_val(ins[p], vals) == 2:
                        return bt_pin(p, 1)
                return None
            for p in pins:
                if self.input_val(ins[p], vals) == 2:
                    return bt_pin(p, 0)
            return None
        if kind == "NOR":
            if want == 0:
                for p in pins:
                    if self.input_val(ins[p], vals) == 2:
                        return bt_pin(p, 1)
                return None
            for p in pins:
                if self.input_val(ins[p], vals) == 2:
                    return bt_pin(p, 0)
            return None
        # XOR/OTHER: 无控制值, 任意 X 输入
        for p in pins:
            if self.input_val(ins[p], vals) == 2:
                return bt_pin(p, 0)
        return None
    # ---- 非控制输入值 (D-frontier 推进用) ----
    def nonctrl(self, gi):
        k = self.gate_kind(gi)
        if k in ("AND", "NAND"):
            return 1
        if k in ("OR", "NOR"):
            return 0
        return 0
    def backtrack(self):
        while self.stack:
            pi, v, flipped = self.stack.pop()
            if not flipped:
                self.stack.append([pi, 1 - v, True])
                return True
        return False
    def run(self):
        cir = self.cir
        for _ in range(self.max_decisions):
            self.decisions += 1
            assigns = self.assign_map()
            vals, fvals = self.tsim(dict(assigns))
            if self.fault_at_po(vals, fvals):
                return ("detected", assigns, self.decisions)
            # ---- 目标选择: 激励 or 传播 ----
            if not self.excited(vals):
                obj = self.excite_objective()
            else:
                fr = self.d_frontier(vals, fvals)
                if not fr:
                    # D 消失/被吸收, 本分支死路 -> 回溯
                    if not self.backtrack():
                        return ("aborted", self.assign_map(), self.decisions)
                    continue
                gi = fr[0]
                ty, out, ins, name = cir.gates[gi]
                ncv = self.nonctrl(gi)
                obj = None
                for p, n in ins.items():
                    if self.input_val(n, vals) == 2:
                        obj = (n, ncv)
                        break
                if obj is None:
                    # frontier 输入全定, D 推不过去 -> 回溯
                    if not self.backtrack():
                        return ("aborted", self.assign_map(), self.decisions)
                    continue
            # ---- 回溯目标到 PI 并赋值 ----
            r = self.backtrace(obj[0], obj[1], vals)
            if r is None:
                # 目标由常数/别名驱动, 不可控 (该故障冗余/此路径不可测)
                if not self.backtrack():
                    return ("undetected", self.assign_map(), self.decisions)
                continue
            pi, pv = r
            cur = self.assign_map()
            if pi in cur and cur[pi] != pv:
                # 与既有决策冲突 -> 回溯
                if not self.backtrack():
                    return ("aborted", self.assign_map(), self.decisions)
                continue
            self.stack.append([pi, pv, False])
        return ("aborted", self.assign_map(), self.decisions)

    def fault_at_po(self, vals, fvals):
        for po in self.cir.po_net:
            if po in vals and po in fvals:
                g, f = vals[po], fvals[po]
                if g != 2 and f != 2 and g != f:
                    return True
        return False

def _eval3(expr, args):
    """3 值仿真: 已知值 -> 精确; 含 X -> [lo,hi] 区间 (X 全按 0 / 全按 1)"""
    if 2 in args.values():
        lo = expr.eval({p: (1 if args[p] == 1 else 0) for p in args})
        hi = expr.eval({p: (0 if args[p] == 0 else 1) for p in args})
        return lo if lo == hi else 2
    return expr.eval(args)

# ================================================================ 自检
def selftest(lib):
    print("== ATPG 自检 (与暴力穷举交叉验证) ==")
    ok_all = True
    # 电路: z = ~(a&b) 与 ~(c|d) 的 NOR = (a&b)|(c|d) ... 用真实单元
    # Nangate45 单元（引脚名取自 liberty 的 function）：
    #   NAND2_X1: "!(A1 & A2)"   INV_X1: A -> ZN
    #   NOR2_X1 : "!(A1 | A2)"   XOR2_X1: A ^ B
    gates = [
        ("NAND2_X1", "n3", {"A1": "a", "A2": "b"}, "g1"),
        ("INV_X1",   "n4", {"A": "n3"}, "g2"),
        ("NOR2_X1",  "n5", {"A1": "c", "A2": "d"}, "g3"),
        ("NOR2_X1",  "z",  {"A1": "n4", "A2": "n5"}, "g4"),
        ("XOR2_X1",  "x",  {"A": "a", "B": "d"}, "g5"),
    ]
    cir = Circuit(gates, lib, {}, {}, {}, [], ["a", "b", "c", "d"])
    cir.po_net = {"z", "x"}
    order = topo_order(cir)
    faults = build_faults(cir)
    from itertools import product
    inputs = list(product([0, 1], repeat=4))
    def bf_test(f):
        fid, desc, kind, site, sv = f
        for combo in inputs:
            pi = {p: v for p, v in zip(["a", "b", "c", "d"], combo)}
            good = good_sim(cir, order, pi)
            vals = dict(pi)
            if kind == "stem":
                vals[site] = sv
            for gi in order:
                ty, out, ins, name = cir.gates[gi]
                _, _, expr = lib[ty]
                args = {}
                for p, n in ins.items():
                    args[p] = vals.get(n, 0) if cir.net_name(n) is None else vals.get(cir.net_name(n), 0)
                ov = expr.eval(args)
                if kind == "pin" and site[0] == gi:
                    args[site[1]] = sv
                    ov = expr.eval(args)
                if kind == "out" and site == gi:
                    ov = sv
                vals[out] = ov
            if any(vals[po] != good[po] for po in cir.po_net if po in vals):
                return True
        return False
    n_match = n_tot = 0
    for f in faults:
        n_tot += 1
        p = Podem(cir, order, f, max_decisions=60)
        status, assign, d = p.run()
        det_p = (status == "detected")
        det_b = bf_test(f)
        if det_p == det_b:
            n_match += 1
        else:
            print(f"  MISMATCH {f[1]}: podem={det_p} brute={det_b}")
            ok_all = False
    print(f"  PODEM vs 暴力: {n_match}/{n_tot} 一致")
    return ok_all

# ================================================================ 主流程
def main():
    global NPAT, PODEM_MAX, NCAP, DENSITY
    args = sys.argv[1:]
    if "--npat" in args:
        NPAT = int(args[args.index("--npat") + 1])
    if "--ncap" in args:
        NCAP = int(args[args.index("--ncap") + 1])
    if "--density" in args:
        DENSITY = float(args[args.index("--density") + 1])
    if "--podem-max" in args:
        PODEM_MAX = int(args[args.index("--podem-max") + 1])
    os.makedirs(OUT, exist_ok=True)
    lib = parse_liberty(LIB)
    print(f"liberty cells: {len(lib)}")

    if "--selftest" in sys.argv:
        ok = selftest(lib)
        print("SELFTEST", "PASS" if ok else "FAIL")
        sys.exit(0 if ok else 1)

    t = open(SCAN).read()
    cir, order, top_inputs = load_circuit(t, lib)
    print(f"gates: {len(cir.gates)}, dffs: {len(cir.dffs)}, PIs: {len(top_inputs)}")
    print(f"pseudo-PI: {len(cir.pseudo_pi)}, pseudo-PO: {len(cir.pseudo_po)}, topo: {len(order)} gates")

    faults = build_faults(cir)
    nf = len(faults)
    print(f"fault universe: {nf}")
    ALL = (1 << nf) - 1

    # ---- 随机模式 + PFS ----
    rng = random.Random(SEED)
    all_pi = sorted(cir.pi_net)
    detected = 0
    patterns = []
    rand_masks = []
    cov_curve = []
    t0 = time.time()
    for i in range(NPAT):
        if DENSITY >= 1.0:
            pi = {n: rng.randint(0, 1) for n in all_pi}
        else:
            pi = {n: (rng.randint(0, 1) if rng.random() < DENSITY else 0) for n in all_pi}
        mask = pfs(cir, order, pi, faults, ALL, ncap=NCAP)
        patterns.append(pi)
        rand_masks.append(mask)
        detected |= mask
        if (i+1) % 25 == 0 or i < 3:
            fc = bin(detected).count("1") / nf * 100
            cov_curve.append((i+1, round(fc, 2)))
            print(f"  random #{i+1}: FC={fc:.2f}% ({bin(detected).count('1')}/{nf})")
    t_random = time.time() - t0
    n_rand = bin(detected).count("1")
    print(f"random phase: {t_random:.1f}s, detected {n_rand} ({n_rand/nf*100:.2f}%)")

    # ---- PODEM ----
    undet = [f for f in faults if not (detected >> f[0]) & 1]
    if "--max-podem-faults" in sys.argv:
        undet = undet[:int(sys.argv[sys.argv.index("--max-podem-faults") + 1])]
    print(f"PODEM targets: {len(undet)}")
    n_det_p = n_red = n_abort = 0
    podem_pats = []      # (fault, assign_map)
    t1 = time.time()
    for k, f in enumerate(undet):
        p = Podem(cir, order, f, max_decisions=PODEM_MAX)
        status, assign, d = p.run()
        if status == "detected":
            n_det_p += 1
            podem_pats.append((f, assign))
        elif status == "aborted":
            n_abort += 1
        else:
            n_red += 1
        if (k+1) % 100 == 0:
            print(f"  PODEM {k+1}/{len(undet)}: det={n_det_p} red={n_red} abort={n_abort}")
    t_podem = time.time() - t1
    print(f"PODEM: {n_det_p} detected, {n_red} redundant, {n_abort} aborted ({t_podem:.1f}s)")

    # ---- PODEM 模式补全 (未赋值 PI 填 0) + 逐模式故障模拟 ----
    # 每个 PODEM 模式除目标故障外往往还能检测其它故障, 用 PFS 取精确检测集
    print(f"fault-sim {len(podem_pats)} PODEM patterns...")
    t2 = time.time()
    podem_masks = []
    for k, (f, assign) in enumerate(podem_pats):
        pi = {n: 0 for n in all_pi}
        pi.update(assign)
        mask = pfs(cir, order, pi, faults, ALL, ncap=NCAP)
        podem_masks.append((f, pi, mask))
        detected |= mask
        if (k+1) % 500 == 0:
            print(f"  faultsim {k+1}/{len(podem_pats)}")
    t_fsim = time.time() - t2
    total_det = bin(detected).count("1")
    fc = total_det / nf * 100
    te = total_det / (nf - n_red) * 100 if nf > n_red else 100.0
    print(f"faultsim: {t_fsim:.1f}s, 最终: FC={fc:.2f}% TE={te:.2f}%")

    # ---- 未检测故障分布 (诊断覆盖率上限来源) ----
    undet_now = [f for f in faults if not (detected >> f[0]) & 1]
    from collections import Counter
    by_kind = Counter(f[2] for f in undet_now)
    def site_net(f):
        """故障站点对应网名: stem 直接是网, pin/out 需经所在门反查"""
        kind, site = f[2], f[3]
        if kind == "stem":
            return site
        gi = site[0] if kind == "pin" else site
        if gi >= len(cir.gates):
            return ""
        if kind == "pin":
            return cir.gates[gi][2].get(site[1], "")
        return cir.gates[gi][1]
    by_mod = Counter()
    for f in undet_now:
        m = re.search(r"\\u_([A-Za-z_]\w*)", site_net(f) or "")
        by_mod[m.group(1) if m else "(top/实例名无模块)"] += 1
    print(f"未检测 {len(undet_now)}: 按类型 {dict(by_kind)}")
    print(f"未检测按模块 top8: {by_mod.most_common(8)}")

    # ---- 模式导出 (ATPG 仿真用) ----
    EXPORT_MAX = 512          # 门级交叉验证只跑前若干模式, 避免 patterns.json 过大
    for a in sys.argv[1:]:
        if a.startswith("--export"):
            EXPORT_MAX = int(sys.argv[sys.argv.index(a) + 1])
    n_exp = min(len(patterns), EXPORT_MAX)
    print(f"模式导出: {n_exp} random + {min(len(podem_masks), EXPORT_MAX)} podem")

    def bits(pi):
        return "".join("1" if pi.get(n, 0) else "0" for n in all_pi)
    export = {
        "design": f"{TOP} scan (mux-D)",
        "n_chain": 4,
        "shift_cycles": 179,
        "capture_cycles": NCAP,
        "pi_names": all_pi,
        "pi_is_q": {n: (n in cir.pseudo_pi) for n in all_pi},
        "ff_q_map": {q: cir.pseudo_pi[q] for q in cir.pseudo_pi},
        "n_patterns_exported": n_exp,
        "random_patterns": [
            {"bits": bits(pi), "mask": hex(mask)}
            for pi, mask in zip(patterns[:n_exp], rand_masks[:n_exp])],
        "podem_patterns": [
            {"fault": f[1], "fault_id": f[0], "fault_val": f[4],
             "bits": bits(pi), "mask": hex(mask)}
            for f, pi, mask in podem_masks[:EXPORT_MAX]],
    }
    json.dump(export, open(os.path.join(OUT, "patterns.json"), "w"),
              indent=1, ensure_ascii=False)
    print(f"patterns exported: {len(export['random_patterns'])} random + "
          f"{len(export['podem_patterns'])} podem -> patterns.json")

    # checkpoint 折叠
    fanout = {}
    for gi, (ty, out, ins, name) in enumerate(cir.gates):
        for p, n in ins.items():
            src = cir.net_name(n)
            if src:
                fanout[src] = fanout.get(src, 0) + 1
    n_collapsed = (len(cir.pi_net) + sum(1 for f in fanout.values() if f > 1)) * 2
    n_pat_total = NPAT + n_det_p
    shift_used = max(len(c) for c in chains) if 'chains' in dir() else 179
    results = {
        "design": f"{TOP} (扫描网表)",
        "method": "PFS 随机模式 + PODEM 确定性 ATPG + 逐模式故障模拟 (纯 Python 引擎)",
        "fault_model": "stuck-at-0/1, 全引脚故障集 (扫描链移位路径故障除外, 由链测试覆盖)",
        "fault_universe": nf,
        "collapsed_checkpoint_faults": n_collapsed,
        "collapse_ratio": round(1 - n_collapsed / nf, 3),
        "n_random_patterns": NPAT,
        "n_random_patterns_exported": n_exp,
        "undetected_by_kind": dict(by_kind),
        "undetected_by_module_top": dict(by_mod.most_common(10)),
        "detected_random": n_rand,
        "detected_podem_targets": n_det_p,
        "redundant": n_red,
        "aborted": n_abort,
        "total_detected": total_det,
        "fault_coverage_pct": round(fc, 2),
        "test_coverage_pct": round(te, 2),
        "n_test_patterns": n_pat_total,
        "shift_cycles": shift_used,
        "capture_cycles": NCAP,
        "pattern_density": DENSITY,
        "test_cycles": n_pat_total * (2 * shift_used + 1 + NCAP) + shift_used,
        "test_time_us_50MHz": round((n_pat_total * (2 * shift_used + 1 + NCAP) + shift_used) * 20 / 1000, 1),
        "runtime_random_s": round(t_random, 1),
        "runtime_podem_s": round(t_podem, 1),
        "runtime_faultsim_s": round(t_fsim, 1),
        "cov_curve": cov_curve,
    }
    json.dump(results, open(os.path.join(OUT, "atpg_results.json"), "w"),
              indent=2, ensure_ascii=False)
    print(json.dumps(results, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
