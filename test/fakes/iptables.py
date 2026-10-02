#!/usr/bin/env python3
"""极简 iptables/ip6tables 模拟器（白盒测试用）。

状态：每个协议族一份 JSON，路径 = $FAKE_IPT_STATE_DIR/{v4,v6}.json
结构：{"tables": {"mangle": {"chains": {"TAGA": {"builtin": false,
      "rules": [{"args": "-m mac --mac-source x -j DROP", "pkts": 0, "bytes": 0}]}}}}}

支持 init.d 用到的子集：-N/-F/-X/-C/-I/-A/-D/-S/-L，
外加测试专用子命令：setcounters <chain> <target|*> <bytes>、dump。

严格模式：对不存在的链做 -I/-A/-C/-D 一律失败（与真 iptables 一致），
这样任何漏 ensure_chain 的路径都会在测试里暴露。
"""
import json
import os
import sys

STATE_DIR = os.environ.get("FAKE_IPT_STATE_DIR", "/tmp/fake-ipt")
FAMILY = os.environ.get("FAKE_IPT_FAMILY") or (
    "v6" if "6" in os.path.basename(sys.argv[0]) else "v4")
STATE = os.path.join(STATE_DIR, FAMILY + ".json")

BUILTINS = {
    "filter": ["INPUT", "FORWARD", "OUTPUT"],
    "mangle": ["PREROUTING", "INPUT", "FORWARD", "OUTPUT", "POSTROUTING"],
    "nat": ["PREROUTING", "INPUT", "OUTPUT", "POSTROUTING"],
}
CMDS = {"-N", "-F", "-X", "-C", "-I", "-A", "-D", "-S", "-L"}


def load():
    try:
        with open(STATE) as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return {"tables": {}}


def save(d):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(d, fh)
    os.replace(tmp, STATE)


def table(d, name):
    tab = d["tables"].setdefault(name, {"chains": {}})
    for b in BUILTINS.get(name, []):
        tab["chains"].setdefault(b, {"builtin": True, "rules": []})
    return tab


def expand(argv):
    """把 -nvx 这类合并短选项拆开（仅限 n/v/x，避免误解 --string 等长选项）。"""
    out = []
    for a in argv:
        if a.startswith("-") and not a.startswith("--") and len(a) > 2 \
                and all(c in "nvx" for c in a[1:]):
            out += ["-" + c for c in a[1:]]
        else:
            out.append(a)
    return out


def jump_target(rule_args):
    parts = rule_args.split()
    for i, a in enumerate(parts):
        if a == "-j" and i + 1 < len(parts):
            return parts[i + 1]
    return ""


def main():
    argv = sys.argv[1:]
    tabname = "filter"
    if "-t" in argv:
        i = argv.index("-t")
        tabname = argv[i + 1]
        del argv[i:i + 2]
    argv = expand(argv)
    if not argv:
        return 1

    d = load()

    # 测试专用：设置计数器
    if argv[0] == "setcounters":
        _, chain, target, nbytes = argv[:4]
        chain_obj = table(d, tabname)["chains"].get(chain)
        if chain_obj is None:
            return 1
        for r in chain_obj["rules"]:
            if target == "*" or target == jump_target(r["args"]):
                r["bytes"] = int(nbytes)
                r["pkts"] = int(nbytes)
        save(d)
        return 0

    # 测试专用：导出全部规则，便于断言
    if argv[0] == "dump":
        for tname, tobj in d["tables"].items():
            for cname, cobj in tobj["chains"].items():
                for r in cobj["rules"]:
                    print("%s|%s|%s" % (tname, cname, r["args"]))
        return 0

    ci = next((i for i, a in enumerate(argv) if a in CMDS), None)
    if ci is None:
        return 1
    cmd = argv[ci]
    after = argv[ci + 1:]
    chain = after[0] if after and not after[0].startswith("-") else None
    rule_str = " ".join(after[1:] if chain is not None else after)
    chains = table(d, tabname)["chains"]

    if cmd == "-N":
        if chain is None or chain in chains:
            return 1
        chains[chain] = {"builtin": False, "rules": []}
        save(d)
        return 0

    if cmd == "-F":
        if chain is None:
            for c in chains.values():
                c["rules"] = []
        elif chain in chains:
            chains[chain]["rules"] = []
        else:
            return 1
        save(d)
        return 0

    if cmd == "-X":
        if chain is None or chain not in chains:
            return 1
        if chains[chain]["builtin"]:
            return 1
        for oname, c in chains.items():
            if oname == chain:
                continue
            for r in c["rules"]:
                if jump_target(r["args"]) == chain:
                    return 1          # 仍被引用，真 iptables 会拒绝
        del chains[chain]
        save(d)
        return 0

    if cmd == "-C":
        c = chains.get(chain)
        if c is None:
            return 1
        return 0 if any(r["args"] == rule_str for r in c["rules"]) else 1

    if cmd in ("-I", "-A"):
        c = chains.get(chain)
        if c is None:
            return 1                 # 链不存在：必须先 -N
        r = {"args": rule_str, "pkts": 0, "bytes": 0}
        c["rules"].insert(0, r) if cmd == "-I" else c["rules"].append(r)
        save(d)
        return 0

    if cmd == "-D":
        c = chains.get(chain)
        if c is None:
            return 1
        for i, r in enumerate(c["rules"]):
            if r["args"] == rule_str:
                del c["rules"][i]
                save(d)
                return 0
        return 1

    if cmd == "-S":
        if chain is not None:
            c = chains.get(chain)
            if c is None:
                return 1
            for r in c["rules"]:
                print("-A %s %s" % (chain, r["args"]))
            return 0
        for name, c in chains.items():
            if not c["builtin"]:
                print("-N %s" % name)
        for name, c in chains.items():
            for r in c["rules"]:
                print("-A %s %s" % (name, r["args"]))
        return 0

    if cmd == "-L":
        c = chains.get(chain)
        if c is None:
            return 1
        print("Chain %s (1 references)" % chain)
        print("    pkts      bytes target     prot opt in     out     "
              "source               destination")
        for r in c["rules"]:
            parts = r["args"].split()
            tgt = jump_target(r["args"])
            prot = ""
            for i, a in enumerate(parts):
                if a == "-p" and i + 1 < len(parts):
                    prot = parts[i + 1]
            print("%8d %10d %-10s %-4s --  *      *       "
                  "0.0.0.0/0            0.0.0.0/0"
                  % (r["pkts"], r["bytes"], tgt, prot))
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
