#!/usr/bin/env python3
"""从 SKY130 完整 liberty 里，只保留白名单 cell 的 cell 块，其余 cell 删除。

用途：本机 OpenROAD（bazel-nostamp）读完整 SKY130 liberty 时，在 latch cell
`sky130_fd_sc_hd__dlclkp_4` 的 `pin(Q) function : "IQ"` 处段错误（OpenSTA 把
latch 内部状态变量 IQ 当端口解析）。综合网表只用 12 种组合/DFF 单元 + CTS 的
clkbuf，绕开所有 latch 即可，也顺带把 4MB 库缩到几十 KB、加快 read_liberty。

用法：
  python3 filter_lib.py 完整.lib 输出.lib sky130_fd_sc_hd__and2_1 ...

保留：cell 名出现在参数列表里的 `cell(...) { ... }` 块，以及所有非 cell 内容
（library 头部、lu_table_template、默认值等——这些 STA 仍需）。
"""
import re
import sys


def main():
    src = sys.argv[1]
    dst = sys.argv[2]
    whitelist = set(sys.argv[3:])

    with open(src) as f:
        lines = f.readlines()

    out = []
    i = 0
    n = len(lines)
    cell_re = re.compile(r'\s*cell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{')

    while i < n:
        line = lines[i]
        m = cell_re.match(line)
        if m:
            name = m.group(1)
            # 收集整个 cell 块（按花括号配对）
            block = [line]
            depth = line.count('{') - line.count('}')
            i += 1
            while i < n and depth > 0:
                block.append(lines[i])
                depth += lines[i].count('{') - lines[i].count('}')
                i += 1
            if name in whitelist:
                out.extend(block)
        else:
            out.append(line)
            i += 1

    with open(dst, 'w') as f:
        f.writelines(out)

    kept = [c for c in sorted(whitelist)]
    print(f"kept {len(kept)} cells -> {dst}")
    print("  " + ", ".join(kept))


if __name__ == '__main__':
    main()
