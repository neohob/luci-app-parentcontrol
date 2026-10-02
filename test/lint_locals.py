#!/usr/bin/env python3
"""静态检查：shell 函数体里赋值的 `_xxx` 临时变量必须在本函数 local 掉。

这是本项目的一个真实 bug 类的防线——busybox ash 的变量默认全局，
helper 里写 `_ip=$(...)` 会静默覆盖调用方的同名循环变量（曾导致
网址条目的 TCP/SNI 规则整条没被安装）。

用法：python3 test/lint_locals.py <file>...
退出码：0 = 干净；1 = 有未 local 的 `_` 变量。
"""
import re
import sys

FUNC_OPEN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
LOCAL = re.compile(r"^\s*local\s+(.*)$")
ASSIGN = re.compile(r"^\s*(_[A-Za-z0-9_]+)=")
FORIN = re.compile(r"\bfor\s+(_[A-Za-z0-9_]+)\s+in\b")
READIN = re.compile(r"\bread\b[^;]*?\s+(_[A-Za-z0-9_]+)\b")
CASEIN = re.compile(r"\bcase\s+(_[A-Za-z0-9_]+)\s+in\b")


def functions(text):
    """产出 (name, body_lines)。约定：函数结束的 } 在行首。"""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = FUNC_OPEN.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        if lines[i].rstrip().endswith("}"):        # 单行函数
            i += 1
            continue
        body = []
        i += 1
        while i < len(lines) and lines[i] != "}":
            body.append(lines[i])
            i += 1
        yield name, body
        i += 1


def check(path):
    problems = []
    for name, body in functions(open(path).read()):
        locals_ = set()
        for line in body:
            m = LOCAL.match(line)
            if m:
                locals_.update(m.group(1).split())
        assigned = set()
        for line in body:
            for rx in (ASSIGN, FORIN, CASEIN):
                m = rx.search(line)
                if m:
                    assigned.add(m.group(1))
            m = READIN.search(line)
            if m and line.lstrip().startswith(("while", "read")):
                assigned.add(m.group(1))
        missing = sorted(n for n in assigned if n not in locals_)
        if missing:
            problems.append((name, missing))
    return problems


def main():
    bad = 0
    for path in sys.argv[1:]:
        for name, missing in check(path):
            print("%s: 函数 %s 未 local: %s" % (path, name, " ".join(missing)))
            bad += 1
    if bad:
        print("\n%d 处未 local 的临时变量" % bad)
        return 1
    print("locals 检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
