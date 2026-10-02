#!/bin/sh
# common.sh 白盒测试：逐分支覆盖日子判定 / 节假日解析 / 额度 / 用量 / 配额。
# 运行： sh test/common_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
t_setup

# ============================================================
echo '== uci 助手（pc_ids_all / pc_ids_on）=='
cfg_reset
cat > "$T_TMP/ids" <<'EOF'
config weburl
	option enable '1'
config weburl
	option enable '0'
config weburl
	option enable '1'
config weburl
	option enabled '1'
EOF
# 位置无关：直接用 uci 写多位数下标
cfg_set 'parentcontrol.@weburl[11].enable' '1'
cfg_set 'parentcontrol.@weburl[11].sd_mode' 'quota'
cfg_load parentcontrol "$T_TMP/ids"
t_eq 'ids_all 含 0..3/11' '0 1 2 3 11' "$(pc_ids_all weburl | tr '\n' ' ' | sed 's/ $//')"
t_eq 'ids_on 只取 enable=1' '0 2 11' "$(pc_ids_on weburl | tr '\n' ' ' | sed 's/ $//')"
t_eq 'ids_all 空配置' '' "$(cfg_reset; pc_ids_all time)"

# ============================================================
echo '== pc_holiday_flag：jsonfilter 路径 =='
put_holiday 2026 '{"year": 2026, "days": [
    {"name": "元旦", "date": "2026-01-01", "isOffDay": true},
    {"name": "春节", "date": "2026-02-16", "isOffDay": false}
]}'
FAKE_JSONFILTER=on
t_eq 'jsonfilter 放假 → 1' 1 "$(pc_holiday_flag 2026-01-01)"
t_eq 'jsonfilter 调休 → 0' 0 "$(pc_holiday_flag 2026-02-16)"
t_eq 'jsonfilter 无此日期 → 空' '' "$(pc_holiday_flag 2026-03-03)"
t_eq 'jsonfilter 无该年文件 → 空' '' "$(pc_holiday_flag 2027-01-01)"

echo '== pc_holiday_flag：兜底路径（jsonfilter 不可用）=='
FAKE_JSONFILTER=off
t_eq '兜底 带空格 JSON → 1' 1 "$(pc_holiday_flag 2026-01-01)"
t_eq '兜底 带空格 JSON → 0' 0 "$(pc_holiday_flag 2026-02-16)"
put_holiday 2026 '{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},{"name":"2026-03-03 提示","date":"2026-04-04","isOffDay":true},{"name":"春节","date":"2026-02-16","isOffDay":false}]}'
t_eq '兜底 压缩 JSON → 1' 1 "$(pc_holiday_flag 2026-01-01)"
t_eq '兜底 压缩 JSON → 0' 0 "$(pc_holiday_flag 2026-02-16)"
t_eq '兜底 只有 name 含该日期 → 不误命中' '' "$(pc_holiday_flag 2026-03-03)"
t_eq '兜底 无该年文件 → 空' '' "$(pc_holiday_flag 2027-01-01)"
FAKE_JSONFILTER=on

# ============================================================
echo '== pc_in_vacation =='
cfg_reset
cat > "$T_TMP/vac" <<'EOF'
config vacation
	option name 'summer'
	option start '07-01'
	option end '08-31'
config vacation
	option name 'winter'
	option start '2026-01-20'
	option end '2026-02-16'
config vacation
	option name 'newyear'
	option start '12-28'
	option end '01-03'
config vacation
	option name 'broken'
	option start '05-01'
EOF
cfg_load parentcontrol "$T_TMP/vac"
t_eq 'MM-DD 每年重复：区间内' 1 "$(pc_in_vacation 2027-07-15)"
t_eq 'MM-DD 每年重复：区间外' 0 "$(pc_in_vacation 2027-06-30)"
t_eq 'MM-DD 起点当日含' 1 "$(pc_in_vacation 2026-07-01)"
t_eq 'MM-DD 终点当日含' 1 "$(pc_in_vacation 2026-08-31)"
t_eq 'MM-DD 起点前一天' 0 "$(pc_in_vacation 2026-06-30)"
t_eq 'MM-DD 终点后一天' 0 "$(pc_in_vacation 2026-09-01)"
t_eq '绝对日期：区间内' 1 "$(pc_in_vacation 2026-02-01)"
t_eq '绝对日期：跨年不适用' 0 "$(pc_in_vacation 2027-02-01)"
t_eq '跨年区间：12 月' 1 "$(pc_in_vacation 2026-12-30)"
t_eq '跨年区间：1 月' 1 "$(pc_in_vacation 2026-01-02)"
t_eq '跨年区间：11 月' 0 "$(pc_in_vacation 2026-11-30)"
t_eq '跨年区间：1/4' 0 "$(pc_in_vacation 2026-01-04)"
t_eq '缺 end 的坏行被跳过' 0 "$(pc_in_vacation 2026-05-01)"

# ============================================================
echo '== pc_today_type 优先级 =='
cfg_reset
cat > "$T_TMP/day" <<'EOF'
config vacation
	option name 'winter'
	option start '01-01'
	option end '01-10'
EOF
cfg_load parentcontrol "$T_TMP/day"
put_holiday 2026 '{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true},{"name":"调休","date":"2026-01-11","isOffDay":false}]}'
FAKE_DATE_YMD=2026-01-05 FAKE_DATE_DOW=1
t_eq '寒暑假优先于周末/工作日判定' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-01-01 FAKE_DATE_DOW=4
t_eq '法定放假 → 节假日' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-01-11 FAKE_DATE_DOW=7
t_eq '调休上班的周末 → 平日' school "$(pc_today_type)"
FAKE_DATE_YMD=2026-06-06 FAKE_DATE_DOW=6
t_eq '无数据 周六 → 节假日' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-06-07 FAKE_DATE_DOW=7
t_eq '无数据 周日 → 节假日' holiday "$(pc_today_type)"
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1
t_eq '无数据 周一 → 平日' school "$(pc_today_type)"
FAKE_DATE_YMD=2028-06-06 FAKE_DATE_DOW=6
t_eq '无该年数据 周六 → 降级节假日' holiday "$(pc_today_type)"

# ============================================================
echo '== pc_suffix / pc_reset_for / pc_allowance_issued =='
t_eq 'suffix holiday→hd' hd "$(pc_suffix holiday)"
t_eq 'suffix school→sd' sd "$(pc_suffix school)"
cfg_reset
cfg_set 'parentcontrol.@basic[0].reset_school' '07:30'
t_eq 'reset 缺省 12:00' '12:00' "$(pc_reset_for holiday)"
t_eq 'reset 自定义生效' '07:30' "$(pc_reset_for school)"
FAKE_DATE_HM=07:29; t_eq '07:29 未发放' 1 "$(pc_allowance_issued 07:30 && echo 0 || echo 1)"
FAKE_DATE_HM=07:30; t_eq '07:30 恰好发放' 0 "$(pc_allowance_issued 07:30 && echo 0 || echo 1)"
FAKE_DATE_HM=07:31; t_eq '07:31 已发放' 0 "$(pc_allowance_issued 07:30 && echo 0 || echo 1)"
FAKE_DATE_HM=00:00; t_eq 'reset=00:00 恒已发放' 0 "$(pc_allowance_issued 00:00 && echo 0 || echo 1)"
t_eq 'HH:MM→分钟 08:05' 485 "$(pc_hhmm_to_min 08:05)"
t_eq 'HH:MM→分钟 09:30' 570 "$(pc_hhmm_to_min 09:30)"
t_eq 'HH:MM→分钟 00:00' 0 "$(pc_hhmm_to_min 00:00)"
t_eq 'HH:MM→分钟 23:59' 1439 "$(pc_hhmm_to_min 23:59)"
t_eq 'HH+MM 参数形式' 485 "$(pc_hhmm_to_min 08 05)"
t_eq '空输入→0' 0 "$(pc_hhmm_to_min '')"
t_eq '北京→UTC 08:00' '00:00' "$(pc_utc_hhmm 08:00)"
t_eq '北京→UTC 18:00' '10:00' "$(pc_utc_hhmm 18:00)"
t_eq '北京→UTC 00:00（跨日）' '16:00' "$(pc_utc_hhmm 00:00)"
t_eq '北京→UTC 23:59（跨日）' '15:59' "$(pc_utc_hhmm 23:59)"
t_eq '北京→UTC 12:00' '04:00' "$(pc_utc_hhmm 12:00)"
FAKE_DATE_HM=08:05; t_eq '08:05 == 08:05 → 已发放' 0 "$(pc_allowance_issued 08:05 && echo 0 || echo 1)"
FAKE_DATE_HM=08:04; t_eq '08:04 < 08:05 → 未发放' 1 "$(pc_allowance_issued 08:05 && echo 0 || echo 1)"
FAKE_DATE_HM=23:59; t_eq '23:59 已发放' 0 "$(pc_allowance_issued 00:00 && echo 0 || echo 1)"

# ============================================================
echo '== 用量读写 =='
FAKE_DATE_YMD=2026-03-01
t_eq '无文件时用量为 0' 0 "$(pc_usage_get weburl_0)"
pc_usage_add weburl_0 1
pc_usage_add weburl_0 2
pc_usage_add weburl_1 5
t_eq '同键累加' 3 "$(pc_usage_get weburl_0)"
t_eq '不同键独立' 5 "$(pc_usage_get weburl_1)"
t_eq '不存在的键 → 0' 0 "$(pc_usage_get weburl_9)"
FAKE_DATE_YMD=2026-03-02
t_eq '跨天清零' 0 "$(pc_usage_get weburl_0)"
FAKE_DATE_YMD=2026-03-01

# ============================================================
echo '== pc_lan_nets（防自锁用）=='
cfg_reset
cat > "$T_TMP/net.uci" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
config interface 'wan'
	option proto 'dhcp'
EOF
cfg_load network "$T_TMP/net.uci"
t_eq '静态 LAN 网段' '192.0.2.1/255.255.255.0' "$(pc_lan_nets)"
cfg_reset
t_eq '无 network 配置 → 空' '' "$(pc_lan_nets)"

echo '== 配额归一 / 池 =='
t_eq '空 → 不限(0)' 0 "$(pc_quota_positive '')"
t_eq '非数字 → 不限(0)' 0 "$(pc_quota_positive abc)"
t_eq '0 → 不限(0)' 0 "$(pc_quota_positive 0)"
t_eq '正常数字' 60 "$(pc_quota_positive 60)"
t_eq '带空格 → 不限(0)' 0 "$(pc_quota_positive ' 60')"
cfg_reset
cat > "$T_TMP/pool" <<'EOF'
config quota
	option name 'kid1'
	option sd_quota '60'
	option hd_quota '120'
config quota
	option name 'onlyone'
	option quota '45'
EOF
cfg_load parentcontrol "$T_TMP/pool"
t_eq '池 平日额度' 60 "$(pc_pool_quota kid1 school)"
t_eq '池 节假日额度' 120 "$(pc_pool_quota kid1 holiday)"
t_eq '池 单 quota 兜底(平日)' 45 "$(pc_pool_quota onlyone school)"
t_eq '池 单 quota 兜底(节假日)' 45 "$(pc_pool_quota onlyone holiday)"
t_eq '不存在的池 → 空' '' "$(pc_pool_quota nope school)"

echo '== 条目档案取值 =='
cfg_reset
cat > "$T_TMP/entry" <<'EOF'
config weburl
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '30'
	option sd_pool 'kid1'
	option hd_mode 'time'
	option hd_start '08:00'
	option hd_end '20:00'
config weburl
	option enable '1'
config weburl
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '10'
config weburl
	option enable '0'
	option sd_mode 'quota'
	option sd_quota '99'
config time
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '7'
EOF
cfg_load parentcontrol "$T_TMP/entry"
t_eq '平日 mode' quota "$(pc_entry_mode weburl 0 school)"
t_eq '节假日 mode' time "$(pc_entry_mode weburl 0 holiday)"
t_eq '平日 quota' 30 "$(pc_entry_quota weburl 0 school)"
t_eq '平日 pool' kid1 "$(pc_entry_pool weburl 0 school)"
t_eq '节假日 pool 为空' '' "$(pc_entry_pool weburl 0 holiday)"
t_eq '未设 mode → 空' '' "$(pc_entry_mode weburl 1 school)"
t_eq 'eff_mode 未设 → time(兼容老配置)' time "$(pc_entry_eff_mode weburl 1 school)"
t_eq 'eff_mode quota' quota "$(pc_entry_eff_mode weburl 0 school)"

echo '== pc_quota_keys：唯一额度遍历入口 =='
t_eq '只列 enable=1 且额度的条目（模块序 time/protocol/weburl）' 'time_0 weburl_0 weburl_2' \
	"$(pc_quota_keys school | tr '\n' ' ' | sed 's/ $//')"
t_eq '该日为非额度模式 → 空' '' "$(pc_quota_keys holiday)"

t_summary
