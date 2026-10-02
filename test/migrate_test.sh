#!/bin/sh
# 配置迁移（pc_migrate_config）白盒测试：逐分支覆盖 week→双档案 / word→domains / 默认值。
# 运行： sh test/migrate_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
t_setup

cat > "$T_TMP/old.uci" <<'EOF'
config basic
	option enabled '1'
	option reset_school '07:00'

config weburl
	option enable '1'
	option word 'xhs'
	option week '1,2,3,4,5'
	option timestart '08:00'
	option timeend '18:00'

config weburl
	option enable '1'
	option domains 'keep.com'
	option week '6,7'

config time
	option enable '1'

config time
	option enable '1'
	option week '1,7'

config protocol
	option enable '1'
	option week '3'
	option timestart '09:30'
	option timeend '10:30'
EOF

echo '== 迁移前 =='
cfg_reset
cfg_load parentcontrol "$T_TMP/old.uci"
pc_migrate_config
echo '== 默认值（缺失才补，已有不动）=='
t_eq 'reset_school 已有值不动' '07:00' "$(cfg_get parentcontrol.@basic[0].reset_school)"
t_eq 'reset_holiday 补默认' '12:00' "$(cfg_get parentcontrol.@basic[0].reset_holiday)"
t_eq 'usage_keep 补默认' '90' "$(cfg_get parentcontrol.@basic[0].usage_keep)"
t_eq 'usage_min_kb 补默认' '32' "$(cfg_get parentcontrol.@basic[0].usage_min_kb)"

echo '== word → domains =='
t_eq '只有 word 时搬到 domains' 'xhs' "$(cfg_get parentcontrol.@weburl[0].domains)"
t_eq '已有 domains 时不覆盖' 'keep.com' "$(cfg_get parentcontrol.@weburl[1].domains)"
t_eq 'word 已删除（铲除幽灵匹配源）' '' "$(cfg_get parentcontrol.@weburl[0].word)"

echo '== week=1,2,3,4,5 → 平日=时段；节假日=关闭 =='
t_eq 'sd_mode' time "$(cfg_get parentcontrol.@weburl[0].sd_mode)"
t_eq 'sd_start 照抄' '08:00' "$(cfg_get parentcontrol.@weburl[0].sd_start)"
t_eq 'sd_end 照抄' '18:00' "$(cfg_get parentcontrol.@weburl[0].sd_end)"
t_eq 'hd_mode=off' off "$(cfg_get parentcontrol.@weburl[0].hd_mode)"
t_eq 'hd 起止未写' '' "$(cfg_get parentcontrol.@weburl[0].hd_start)"

echo '== week=6,7 → 节假日=时段；平日=关闭 =='
t_eq 'sd_mode=off' off "$(cfg_get parentcontrol.@weburl[1].sd_mode)"
t_eq 'hd_mode=time' time "$(cfg_get parentcontrol.@weburl[1].hd_mode)"
t_eq 'hd_start 缺省 00:00' '00:00' "$(cfg_get parentcontrol.@weburl[1].hd_start)"
t_eq 'hd_end 缺省 00:00' '00:00' "$(cfg_get parentcontrol.@weburl[1].hd_end)"

echo '== week 缺失 → 视作 * → 两侧都设 =='
t_eq 'time[0] sd_mode' time "$(cfg_get parentcontrol.@time[0].sd_mode)"
t_eq 'time[0] hd_mode' time "$(cfg_get parentcontrol.@time[0].hd_mode)"
t_eq 'time[0] sd_start 缺省 00:00' '00:00' "$(cfg_get parentcontrol.@time[0].sd_start)"

echo '== week 混合(1,7) → 两侧都设 =='
t_eq 'time[1] sd_mode' time "$(cfg_get parentcontrol.@time[1].sd_mode)"
t_eq 'time[1] hd_mode' time "$(cfg_get parentcontrol.@time[1].hd_mode)"

echo '== 只含工作日(3) → 平日=时段（协议模块）=='
t_eq 'protocol sd_mode' time "$(cfg_get parentcontrol.@protocol[0].sd_mode)"
t_eq 'protocol sd_start' '09:30' "$(cfg_get parentcontrol.@protocol[0].sd_start)"
t_eq 'protocol sd_end' '10:30' "$(cfg_get parentcontrol.@protocol[0].sd_end)"
t_eq 'protocol hd_mode=off' off "$(cfg_get parentcontrol.@protocol[0].hd_mode)"

echo '== 幂等：再跑一次不改动已迁移项 =='
BEFORE=$(uci -q show parentcontrol)
pc_migrate_config
t_eq '重复迁移结果不变' "$BEFORE" "$(uci -q show parentcontrol)"

echo '== 已是新格式的条目被跳过 =='
cfg_reset
cat > "$T_TMP/new.uci" <<'EOF'
config weburl
	option enable '1'
	option week '1,2,3'
	option timestart '08:00'
	option timeend '09:00'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_load parentcontrol "$T_TMP/new.uci"
pc_migrate_config
t_eq '已有 sd_mode → 不覆盖' quota "$(cfg_get parentcontrol.@weburl[0].sd_mode)"
t_eq '已有 sd_mode → 不补 hd_mode' '' "$(cfg_get parentcontrol.@weburl[0].hd_mode)"

t_summary
