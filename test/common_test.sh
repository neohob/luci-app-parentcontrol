#!/bin/sh
# 纯逻辑自测：不依赖路由器。运行： sh test/common_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)

PC_CONF=parentcontrol
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HOLIDAY_CACHE="$TMP/holiday"
USAGE_DIR="$TMP/usage"
mkdir -p "$HOLIDAY_CACHE"

cat > "$HOLIDAY_CACHE/2025.json" <<'EOF'
{
  "year": 2025,
  "days": [
    {"name": "元旦", "date": "2025-01-01", "isOffDay": true},
    {"name": "春节", "date": "2025-01-26", "isOffDay": false},
    {"name": "春节", "date": "2025-01-27", "isOffDay": true}
  ]
}
EOF

# 压缩（无空格）的 2026：上游把 JSON 压成一行时，解析不能因此失效（B1 回归）
cat > "$HOLIDAY_CACHE/2026.json" <<'EOF'
{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},{"name":"2026-03-03 提示","date":"2026-04-04","isOffDay":true},{"name":"春节","date":"2026-02-16","isOffDay":false}]}
EOF

# ---------- stubs ----------
FAKE_YMD=2025-01-01
FAKE_WD=3
FAKE_HM=09:00
date() {
	case "$1" in
	+%Y-%m-%d) echo "$FAKE_YMD" ;;
	+%u)       echo "$FAKE_WD" ;;
	+%Y%m%d)   echo "$FAKE_YMD" | tr -d '-' ;;
	+%H)       echo "${FAKE_HM%%:*}" ;;
	+%M)       echo "${FAKE_HM##*:}" ;;
	*)         echo "" ;;
	esac
}

# uci 桩：够用即可
uci() {
	[ "$1" = "-q" ] && shift
	case "$1" in
	get)  uci_get "$2" ;;
	show) uci_show ;;
	*)    return 0 ;;
	esac
}
uci_get() {
	case "$1" in
	'parentcontrol.@basic[0].reset_school')  echo "${RESET_SCHOOL:-12:00}" ;;
	'parentcontrol.@basic[0].reset_holiday') echo "${RESET_HOLIDAY:-12:00}" ;;
	'parentcontrol.@vacation[0].start')       echo "${VAC0_S:-}" ;;
	'parentcontrol.@vacation[0].end')         echo "${VAC0_E:-}" ;;
	'parentcontrol.@vacation[1].start')       echo "${VAC1_S:-}" ;;
	'parentcontrol.@vacation[1].end')         echo "${VAC1_E:-}" ;;
	'parentcontrol.@quota[0].name')           echo "${Q0_NAME:-}" ;;
	'parentcontrol.@quota[0].sd_quota')       echo "${Q0_SD:-}" ;;
	'parentcontrol.@quota[0].hd_quota')       echo "${Q0_HD:-}" ;;
	'parentcontrol.@weburl[0].enable')        echo "${W0_EN:-}" ;;
	'parentcontrol.@weburl[0].sd_mode')       echo "${W0_SDM:-}" ;;
	*) return 1 ;;
	esac
}
uci_show() {
	[ -n "${W0_EN:-}" ] && echo "parentcontrol.@weburl[0].enable='$W0_EN'"
	[ -n "${VAC0_S:-}" ] && echo "parentcontrol.@vacation[0].start='$VAC0_S'"
	[ -n "${VAC1_S:-}" ] && echo "parentcontrol.@vacation[1].start='$VAC1_S'"
	[ -n "${Q0_NAME:-}" ] && echo "parentcontrol.@quota[0].name='$Q0_NAME'"
	return 0
}

. "$HERE/../root/usr/lib/parentcontrol/common.sh"

# ---------- assert ----------
fails=0
eq() { # $1=desc $2=want $3=got
	if [ "$2" = "$3" ]; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s want=[%s] got=[%s]\n' "$1" "$2" "$3"
		fails=$((fails + 1))
	fi
}

# 节假日
echo '--- 空格 JSON ---'
eq 'holiday offday'     1  "$(pc_holiday_flag 2025-01-01)"
eq 'holiday workday'    0  "$(pc_holiday_flag 2025-01-26)"
eq 'holiday unknown'   ''  "$(pc_holiday_flag 2025-02-01)"

# B1 回归：强制走兜底解析（遮蔽 command 使 jsonfilter 探测失败）的压缩 JSON
echo '--- 压缩 JSON（兜底路径）---'
command() { return 1; }
eq 'compressed offday'   1 "$(pc_holiday_flag 2026-01-01)"
eq 'compressed workday'  0 "$(pc_holiday_flag 2026-02-16)"
eq 'compressed name-only date not matched' '' "$(pc_holiday_flag 2026-03-03)"
unset -f command

# 寒暑假
VAC0_S=07-01 VAC0_E=08-31
eq 'summer in'   1 "$(pc_in_vacation 2025-07-15)"
eq 'summer out'  0 "$(pc_in_vacation 2025-06-15)"

# 跨年寒假（绝对区间）
VAC0_S=2025-07-01 VAC0_E=2025-08-31
VAC1_S=12-20 VAC1_E=01-05
eq 'winter dec'  1 "$(pc_in_vacation 2025-12-25)"
eq 'winter jan'  1 "$(pc_in_vacation 2025-01-03)"
eq 'winter out'  0 "$(pc_in_vacation 2025-02-20)"

# 日子类型
VAC0_S= VAC0_E= VAC1_S= VAC1_E=
FAKE_YMD=2025-01-01 FAKE_WD=3; eq 'daytype holiday' holiday "$(pc_today_type)"
FAKE_YMD=2025-01-26 FAKE_WD=7; eq 'daytype makeup'  school  "$(pc_today_type)"
FAKE_YMD=2025-02-01 FAKE_WD=6; eq 'daytype weekend' holiday "$(pc_today_type)"
FAKE_YMD=2025-02-03 FAKE_WD=1; eq 'daytype weekday' school  "$(pc_today_type)"

# 重置时刻
FAKE_HM=09:00; pc_allowance_issued 12:00 && eq 'before reset issued' 1 0 || eq 'before reset issued' 0 0
FAKE_HM=13:00; pc_allowance_issued 12:00 && eq 'after reset issued' 0 0 || eq 'after reset issued' 1 0

# 用量读写
FAKE_YMD=2025-01-01
pc_usage_add weburl_0 1
pc_usage_add weburl_0 1
pc_usage_add weburl_1 5
eq 'usage get key0' 2 "$(pc_usage_get weburl_0)"
eq 'usage get key1' 5 "$(pc_usage_get weburl_1)"
eq 'usage get none' 0 "$(pc_usage_get weburl_9)"

# 配额归一
eq 'quota empty unlimited' 0 "$(pc_quota_positive '')"
eq 'quota text unlimited'  0 "$(pc_quota_positive 'abc')"
eq 'quota number'         60 "$(pc_quota_positive 60)"

# 池
Q0_NAME=kid Q0_SD=60 Q0_HD=120
eq 'pool school' 60  "$(pc_pool_quota kid school)"
eq 'pool holiday' 120 "$(pc_pool_quota kid holiday)"

# section 列表
W0_EN=1
eq 'ids_on'  '0' "$(pc_ids_on weburl)"
eq 'ids_all' '0' "$(pc_ids_all weburl)"

if [ "$fails" -eq 0 ]; then
	echo "ALL PASS"
else
	echo "$fails FAILED"
	exit 1
fi
