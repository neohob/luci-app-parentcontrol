#!/usr/bin/env python3
"""Lint：被 require 的 LuCI 模块不能直接用 CBI 注入的全局类名。

CBI 模型文件（luasrc/model/cbi/**.lua）在被 LuCI 加载时，会拿到
Map/TypedSection/Value/ListValue/Flag/DummyValue 这些**全局**类。
但同一个目录下被 `require` 的子模块（如 parts.lua）拿不到它们 —— 用了就是
`t:option(nil, ...)` → 运行时 "class must be a descendant of AbstractValue"。

判定：文件里没有顶层 `Map(` 调用（即不是模型文件），却出现裸的 CBI 类名
（未加 `cbi.` / `luci.cbi.` 前缀）→ 报错。

用法： python3 test/lint_luci_globals.py <file>...
"""
import re
import sys

# CBI 模型文件会被注入这些全局名；被 require 的子模块必须显式 require 后取用。
CLASSES = ("Map", "TypedSection", "NamedSection", "Table", "SimpleSection",
           "AbstractSection", "AbstractValue", "Value", "DummyValue", "Flag",
           "ListValue", "MultiValue", "StaticList", "DynamicList", "TextValue",
           "Button", "FileUpload", "FileBrowser",
           "translate", "pcdata")

BARE = re.compile(r"(?<![.\w])(" + "|".join(CLASSES) + r")\b")


def main():
    bad = 0
    for path in sys.argv[1:]:
        src = open(path).read()
        if re.search(r"(?<![.\w])Map\s*\(", src):      # 是 CBI 模型文件
            continue
        # 去掉注释与字符串里的内容，避免文档/提示文本误报
        stripped = re.sub(r"--[^\n]*", "", src)
        stripped = re.sub(r'"(?:\\.|[^"\\])*"', '""', stripped)
        stripped = re.sub(r"'(?:\\.|[^'\\])*'", "''", stripped)
        hits = [(i + 1, m.group(1)) for i, line in enumerate(stripped.split("\n"))
                for m in [BARE.search(line)] if m]
        if hits:
            for ln, name in hits:
                print("%s:%d 裸用 LuCI 注入的全局 %s —— 子模块需显式 require 后取用"
                      "（CBI 类从 luci.cbi，translate 从 luci.i18n）" % (path, ln, name))
            bad += 1
    if bad:
        return 1
    print("luci globals 检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
