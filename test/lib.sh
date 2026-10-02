#!/bin/sh
# 白盒测试公共环境与断言。被 test/*_test.sh source。
# 用法：
#   HERE=$(cd "$(dirname "$0")" && pwd); . "$HERE/lib.sh"
#   t_setup          # 建临时目录 / 装桩 / source init.d（会在退出时清理）
#   t_eq desc want got / t_has desc haystack needle / t_hasnt ...
#   t_summary

HERE=${HERE:-$(cd "$(dirname "$0")" && pwd)}
REPO=$(cd "$HERE/.." && pwd)
FAKES="$HERE/fakes"

T_FAILS=0
T_CHECKS=0

t_setup() {
	T_TMP=$(mktemp -d)
	trap 'rm -rf "$T_TMP"' EXIT INT TERM
	BIN="$T_TMP/bin"
	mkdir -p "$BIN"
	# 把“快 python”放到 PATH 最前，绕开 pyenv/asdf 之类 shim（实测差 6~7 倍）
	for _py in /usr/bin/python3 /opt/homebrew/bin/python3 "$(command -v python3 2>/dev/null)"; do
		[ -n "$_py" ] && [ -x "$_py" ] && { ln -sf "$_py" "$BIN/python3"; break; }
	done
	for f in resolveip wget crontab nft conntrack jsonfilter uci date; do
		ln -s "$FAKES/$f" "$BIN/$f"
	done
	# iptables 包一层实文件（不能用符号链接：$0 会指向 BIN，找不到 iptables.py）
	printf '#!/bin/sh\nFAKE_IPT_FAMILY=v4 exec python3 "%s/iptables.py" "$@"\n' "$FAKES" > "$BIN/iptables-legacy"
	printf '#!/bin/sh\nFAKE_IPT_FAMILY=v6 exec python3 "%s/iptables.py" "$@"\n' "$FAKES" > "$BIN/ip6tables-legacy"
	chmod +x "$BIN/iptables-legacy" "$BIN/ip6tables-legacy"
	PATH="$BIN:$PATH"
	export PATH

	FAKE_IPT_STATE_DIR="$T_TMP/ipt"
	FAKE_UCI_FILE="$T_TMP/uci.json"
	FAKE_RESOLVE="$T_TMP/resolve.list"
	FAKE_WGET_LOG="$T_TMP/wget.log"
	FAKE_CRONTAB="$T_TMP/crontab"
	FAKE_WGET_MODE=fail
	FAKE_JSONFILTER=on
	FAKE_DATE_YMD=2026-10-02
	FAKE_DATE_DOW=5
	FAKE_DATE_HM=13:00
	export FAKE_IPT_STATE_DIR FAKE_UCI_FILE FAKE_RESOLVE FAKE_WGET_LOG \
		FAKE_CRONTAB FAKE_WGET_MODE FAKE_JSONFILTER \
		FAKE_DATE_YMD FAKE_DATE_DOW FAKE_DATE_HM
	mkdir -p "$FAKE_IPT_STATE_DIR"
	: > "$FAKE_UCI_FILE"
	: > "$FAKE_RESOLVE"

	IPDIR="$T_TMP/ips"
	USAGE_DIR="$T_TMP/usage"
	HOLIDAY_CACHE="$T_TMP/holiday"
	HOLIDAY_LOCAL="$T_TMP/holiday-local"
	STATE_DIR="$T_TMP/state"
	LOG_FILE="$T_TMP/log"
	LOCK="$T_TMP/lock"
	TICK_LOCK="$T_TMP/tlock"
	RESET_LOG="$T_TMP/resets.log"
	export IPDIR USAGE_DIR HOLIDAY_CACHE HOLIDAY_LOCAL STATE_DIR \
		LOG_FILE LOCK TICK_LOCK RESET_LOG
	mkdir -p "$IPDIR" "$USAGE_DIR" "$HOLIDAY_CACHE" "$HOLIDAY_LOCAL" "$STATE_DIR"

	PC_LIB="$REPO/root/usr/lib/parentcontrol/common.sh"
	export PC_LIB
	# shellcheck source=/dev/null
	. "$REPO/root/etc/init.d/parentcontrol"
}

# ---------------- 断言 ----------------
t_eq() { # desc want got
	T_CHECKS=$((T_CHECKS + 1))
	if [ "$2" = "$3" ]; then
		printf '  ok   %s\n' "$1"
	else
		printf '  FAIL %s\n       want=[%s]\n       got =[%s]\n' "$1" "$2" "$3"
		T_FAILS=$((T_FAILS + 1))
	fi
}

t_has() { # desc haystack needle
	T_CHECKS=$((T_CHECKS + 1))
	if printf '%s' "$2" | grep -qF -- "$3"; then
		printf '  ok   %s\n' "$1"
	else
		printf '  FAIL %s\n       missing [%s]\n       in      [%s]\n' "$1" "$3" "$2"
		T_FAILS=$((T_FAILS + 1))
	fi
}

t_hasnt() { # desc haystack needle
	T_CHECKS=$((T_CHECKS + 1))
	if printf '%s' "$2" | grep -qF -- "$3"; then
		printf '  FAIL %s\n       unexpected [%s]\n       in         [%s]\n' "$1" "$3" "$2"
		T_FAILS=$((T_FAILS + 1))
	else
		printf '  ok   %s\n' "$1"
	fi
}

t_summary() {
	if [ "$T_FAILS" -eq 0 ]; then
		printf 'PASS (%d checks)\n' "$T_CHECKS"
		exit 0
	fi
	printf 'FAILED (%d/%d checks failed)\n' "$T_FAILS" "$T_CHECKS"
	exit 1
}

# ---------------- uci 配置桩 ----------------
cfg_reset() { : > "$FAKE_UCI_FILE"; }

# cfg_load <config-name> <uci-text-file>
cfg_load() {
	python3 "$FAKES/uci_import.py" "$1" "$2" "$T_TMP/merge.json"
	python3 - "$FAKE_UCI_FILE" "$T_TMP/merge.json" <<'PY'
import json, os, sys
a = json.load(open(sys.argv[1])) if os.path.getsize(sys.argv[1]) else {}
a.update(json.load(open(sys.argv[2])))
json.dump(a, open(sys.argv[1], "w"), ensure_ascii=False)
PY
}

# cfg_put <text-file> 写入一段 parentcontrol 配置（追加/覆盖同名键）
cfg_put() { cfg_load parentcontrol "$1"; }

cfg_get() { uci -q get "$1"; }
cfg_set() { uci -q set "$1=$2"; }

# ---------------- 假 iptables 读取 ----------------
_ipt_py() { # $1=family，其余原样传给 python
	_fam=$1; shift
	python3 - "$FAKE_IPT_STATE_DIR/$_fam.json" "$@" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
args = sys.argv[2:]
tables = d.get("tables", {})
if len(args) == 2:                      # table, chain -> rules
    c = tables.get(args[0], {}).get("chains", {}).get(args[1])
    if c:
        for r in c["rules"]:
            print(r["args"])
elif len(args) == 1:                    # table -> chain names
    for name in sorted(tables.get(args[0], {}).get("chains", {})):
        print(name)
else:                                   # all
    for tn, to in tables.items():
        for cn, co in to["chains"].items():
            for r in co["rules"]:
                print("%s|%s|%s" % (tn, cn, r["args"]))
PY
}

ipt_rules() { _ipt_py "$1" "$2" "$3"; }   # family table chain
ipt_chains() { _ipt_py "$1" "$2"; }        # family table
ipt_all() { _ipt_py "$1"; }                # family
ipt_jump() { # family table chain -> 该链所有跳转目标（去重）
	ipt_rules "$1" "$2" "$3" | awk '{for(i=1;i<NF;i++) if($i=="-j") print $(i+1)}'
}

# 设置某链里跳向 target 的规则计数器（target=* 表示全部）
ipt_setcounters() { # family table chain target bytes
	if [ "$1" = "v6" ]; then ip6tables-legacy -t "$2" setcounters "$3" "$4" "$5"
	else iptables-legacy -t "$2" setcounters "$3" "$4" "$5"; fi
}
ipt_exists() { # family table chain
	ipt_chains "$1" "$2" | grep -qx "$3"
}

# ---------------- 假日/解析 fixture ----------------
# put_holiday <year> <json-body>
put_holiday() {
	printf '%s\n' "$2" > "$HOLIDAY_CACHE/$1.json"
}

# put_resolve 从标准输入读 "<4|6> <host> <ip>" 行，覆盖 $FAKE_RESOLVE
put_resolve() { cat > "$FAKE_RESOLVE"; }

# ---------------- 用假 iptables 跑真实构建 ----------------
# 依次执行 build_all（按当前配置与日期）。
run_build() {
	rm -rf "$STATE_DIR"
	mkdir -p "$STATE_DIR"
	refresh_ips
	build_all
}
