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
