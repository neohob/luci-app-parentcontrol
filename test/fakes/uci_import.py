#!/usr/bin/env python3
"""把 UCI 文本配置解析成 uci 模拟器的 JSON 存储（测试用）。

用法：uci_import.py <config-name> <in.uci> <out.json>
"""
import json
import re
import sys


def parse(name, text):
    out = {}
    cur = None
    counts = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^config\s+(\S+)(?:\s+'?([^']*)'?)?\s*$", line)
        if m:
            typ, nm = m.group(1), (m.group(2) or "").strip()
            if nm:
                cur = "%s.%s" % (name, nm)
            else:
                i = counts.get(typ, 0)
                counts[typ] = i + 1
                cur = "%s.@%s[%d]" % (name, typ, i)
            out[cur] = typ
            continue
        m = re.match(r"^(option|list)\s+(\S+)\s+'?([^']*)'?\s*$", line)
        if m and cur:
            out["%s.%s" % (cur, m.group(2))] = m.group(3)
    return out


def main():
    name, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    data = parse(name, open(src).read())
    with open(dst, "w") as fh:
        json.dump(data, fh, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
