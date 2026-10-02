#!/bin/sh
# 跑全部白盒测试套件。运行： sh test/run.sh
HERE=$(cd "$(dirname "$0")" && pwd)
fails=0
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
