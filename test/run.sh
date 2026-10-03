#!/bin/sh
# 跑全部白盒测试套件 + 静态检查。运行： sh test/run.sh
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
fails=0

SHFILES="$REPO/root/etc/init.d/parentcontrol $REPO/root/usr/lib/parentcontrol/common.sh"

printf '\n########## lint: locals ##########\n'
python3 "$HERE/lint_locals.py" $SHFILES || fails=$((fails + 1))

printf '\n########## lint: busybox-ash 兼容性 ##########\n'
sh "$HERE/lint_ash.sh" $SHFILES || fails=$((fails + 1))

printf '\n########## lint: LuCI 全局类 ##########\n'
python3 "$HERE/lint_luci_globals.py" "$REPO"/luasrc/model/cbi/parentcontrol/*.lua || fails=$((fails + 1))

printf '\n########## lint: TSV 只能有一份解析器 ##########\n'
# stats_tsv 的列只有 tsv.lua 能解析。历史上 ui.lua 和 statsdata.lua 各写了一份按下标解析，
# shell 侧改了列之后其中一个漏改，那一整列就静默显示错值（"-" / 错位数字）—— 用这条守住。
# 注意：这只是个绊线（只扫本目录一层、只认字面 \t），不是契约测试；真要硬保证得用 Lua 断言。
tsv_bad=$(grep -l '\\t' "$REPO"/luasrc/model/cbi/parentcontrol/*.lua | grep -v '/tsv\.lua$')
if [ -n "$tsv_bad" ]; then
	echo "FAIL: 以下文件自己解析 TSV（只允许 tsv.lua 解析）:"
	echo "$tsv_bad"
	fails=$((fails + 1))
else
	echo 'TSV 解析器唯一性检查通过'
fi

for t in common_test.sh init_test.sh migrate_test.sh; do
	printf '\n########## %s ##########\n' "$t"
	sh "$HERE/$t" || fails=$((fails + 1))
done

printf '\n===================================\n'
if [ "$fails" -eq 0 ]; then
	echo 'ALL SUITES PASS'
else
	echo "$fails SUITE(S) FAILED"
	exit 1
fi
