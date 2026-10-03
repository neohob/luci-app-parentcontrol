#!/bin/sh
# 变异测试：故意改坏源码，断言测试套件真的会失败（证明用例不是摆设）。
# 全程在仓库副本里做，绝不动工作区。
# 运行： sh test/mutation_check.sh
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/repo"
(cd "$REPO" && tar --exclude=.git -cf - .) | (cd "$WORK/repo" && tar -xf -)

# mutate <file> <old> <new>  —— 锚点找不到就退出 2
mutate() {
	python3 - "$WORK/repo/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
if old not in src:
    sys.exit(2)
open(path, "w").write(src.replace(old, new, 1))
PY
}

KILLED=0
SURVIVED=0
SKIPPED=0

run_mut() { # <名字> <文件> <老> <新> <套件>
	name=$1; file=$2; old=$3; new=$4; suite=$5
	if ! mutate "$file" "$old" "$new"; then
		printf '  FAIL  %s（锚点未命中：这条防线已失效，必须修锚点）\n' "$name"
		SKIPPED=$((SKIPPED + 1))
	FAILED=$((FAILED + 1))
		return
	fi
	if (cd "$WORK/repo" && sh "test/$suite") >"$WORK/out" 2>&1; then
		printf '  SURVIVED  %s —— 改坏后 %s 仍全过，用例没覆盖到\n' "$name" "$suite"
		SURVIVED=$((SURVIVED + 1))
	else
		printf '  killed    %s（%s 失败）\n' "$name" "$suite"
		KILLED=$((KILLED + 1))
	fi
	# 还原
	(cd "$REPO" && tar --exclude=.git -cf - "$file") | (cd "$WORK/repo" && tar -xf -)
}

INIT=root/etc/init.d/parentcontrol
COMMON=root/usr/lib/parentcontrol/common.sh

echo '== 变异测试（期望：每个都被杀死）=='

# 1) 网址 SNI 端口写错
run_mut 'SNI 端口 80,443→80,8443' "$INIT" \
	'--dports 80,443' '--dports 80,8443' init_test.sh

# 2) 网址 TCP/SNI 那条规则整条不装（就是本次修掉的真 bug 的形态）
run_mut 'SNI 规则整条删除' "$INIT" \
	'			emit_dev_rule "$_c" "$1" "$3" weburl "$6" "$4 -p TCP -m multiport --dports 80,443 -m string --algo $_algos --string $_pat" "$5" "$_dev"' ':' init_test.sh

# 3) PREROUTING 挂载顺序被改（TAGQ 不再最先 → 被封的包会先进计数链）
run_mut 'PREROUTING 顺序被改' "$INIT" \
	'		hook_chain "$_ip" mangle PREROUTING "$TAGA"
		hook_chain "$_ip" mangle PREROUTING "$TAGQ"
	done
	build_acct_rules' \
	'		hook_chain "$_ip" mangle PREROUTING "$TAGQ"
		hook_chain "$_ip" mangle PREROUTING "$TAGA"
	done
	build_acct_rules' init_test.sh

# 4) refresh_holiday 永远不联网（novet 短路被提前）
run_mut 'refresh_holiday 永不联网' "$INIT" \
	'	[ "$1" = "novet" ] && return 0' '	return 0' init_test.sh

# 5) 采样阈值失效（任何增量都记 1 分钟）
run_mut '采样阈值失效（任何非零增量都记 1 分钟）' "$INIT" \
	'		[ "$_d" -gt 0 ] && [ "$_d" -ge "$_thr" ] && pc_usage_add "$_key" 1' \
	'		[ "$_d" -gt 0 ] && pc_usage_add "$_key" 1' init_test.sh

# 6) 池额度被忽略（一律按私有额度）
run_mut '共享池口径失效' "$INIT" \
	'	[ -n "$_pool" ] && _pq=$(pc_pool_quota "$_pool" "$3")' \
	'	_pq=' init_test.sh

# 7) 重建时不再 ensure/hook（fw4 reload 后自愈能力丢失）
run_mut '重建自愈能力丢失' "$INIT" \
	'		ensure_chain "$_ip" mangle "$TAGA"
		ensure_chain "$_ip" mangle "$TAGQ"
		hook_chain "$_ip" mangle PREROUTING "$TAGA"
' '' init_test.sh

# 8) 可用时段被忽略（永远当作"不限制时段"）
run_mut '可用时段被忽略' "$COMMON" \
	'	[ "$_ss" -lt "$_ee" ] 2>/dev/null || return 0' '	return 0' common_test.sh

# 9) 节假日解析把 isOffDay 判反
run_mut 'isOffDay 判反' "$COMMON" \
	'		true)  echo 1; return 0 ;;' '		true)  echo 0; return 0 ;;' common_test.sh

# 10) 迁移：不再写可用时段（week=1-5 的老条目本应拿到 09:00-21:00）
run_mut '迁移不写可用时段' "$COMMON" \
	'					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_qstart=$_ws"' \
	'					:' migrate_test.sh

# 11) pc_active_keys 输出的 key 必须是唯一的一份（重复会让封锁链下发两遍）
run_mut '额度遍历输出重复 key' "$COMMON" \
	'			echo "${_m}_${_i}"' \
	'			echo "${_m}_${_i}"; echo "${_m}_${_i}"' init_test.sh

# 12b) 额度计数不再计入字符串（DNS/SNI）命中
run_mut '计数不计 DNS 字符串命中' "$INIT" \
	'			emit_dev_rule "$_c" "$1" "$3" weburl "$6" "$4 -p UDP --dport 53 -m string --algo $_algos --string $_pat" "$5" "$_dev"' ':' init_test.sh

# 12c) 计数/封锁装到错误的表（filter 而非 mangle）
run_mut '计数装错表(filter)' "$INIT" \
	'emit_entry_targets "$_m" "$_i" mangle "$TAGA" "$TAGA" "" "-j PCA_$_key" single' \
	'emit_entry_targets "$_m" "$_i" filter "$TAGA" "$TAGA" "" "-j PCA_$_key" single' init_test.sh

# 12d) 首次采样又变回「只写基线」（丢开机后那段用量）
run_mut '首次采样不计数（丢掉开机后那段用量）' "$INIT" \
	'			_d=$_v
		fi' '			_d=0
		fi' init_test.sh

# 12) 拆除时不清理 mangle 链
run_mut '拆除残留 mangle 链' "$INIT" \
	'		for _ta in "$TAGQ" "$TAGA"; do
			$_ip -t mangle -D PREROUTING -j "$_ta" 2>/dev/null
			$_ip -t mangle -F "$_ta" 2>/dev/null
			$_ip -t mangle -X "$_ta" 2>/dev/null
		done' '' init_test.sh

printf '\n被杀 %d / 存活 %d / 锚点失效 %d\n' "$KILLED" "$SURVIVED" "$SKIPPED"
[ "$SURVIVED" -eq 0 ] && [ "$SKIPPED" -eq 0 ] || exit 1
