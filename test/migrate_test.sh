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
t_eq 'reset_holiday 不再补默认（概念已移除）' '' "$(cfg_get parentcontrol.@basic[0].reset_holiday)"
t_eq 'usage_keep 补默认' '90' "$(cfg_get parentcontrol.@basic[0].usage_keep)"
t_eq 'usage_min_kb 补默认' '8' "$(cfg_get parentcontrol.@basic[0].usage_min_kb)"

echo '== word → domains =='
t_eq '只有 word 时搬到 domains' 'xhs' "$(cfg_get parentcontrol.@weburl[0].domains)"
t_eq '已有 domains 时不覆盖' 'keep.com' "$(cfg_get parentcontrol.@weburl[1].domains)"
t_eq 'word 已删除（铲除幽灵匹配源）' '' "$(cfg_get parentcontrol.@weburl[0].word)"

# 注意：week→双档案会先写 time，随后被「统一模型」一步转成
#       quota + unlimited=1 + 09:00:00-21:00:00（老的时段语义无法无损换算，按既定方案处理）
echo '== week=1,2,3,4,5 → 平日=额度(不限)+09:00-21:00；节假日=关闭 =='
t_eq 'sd_mode 已统一为 quota → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@weburl[0].sd_mode)"
t_eq 'sd_unlimited=1（原时段无额度）' 1 "$(cfg_get parentcontrol.@weburl[0].sd_unlimited)"
t_eq 'sd 可用时段 起' '09:00:00' "$(cfg_get parentcontrol.@weburl[0].sd_qstart)"
t_eq 'sd 可用时段 止' '21:00:00' "$(cfg_get parentcontrol.@weburl[0].sd_qend)"
t_eq 'sd_start 老键已删除（N2：与统一模型字段并存的死字段会误导维护者）' '' "$(cfg_get parentcontrol.@weburl[0].sd_start)"
t_eq 'week 老键已删除（断掉重跑触发源）' '' "$(cfg_get parentcontrol.@weburl[0].week)"
t_eq 'timestart 老键已删除' '' "$(cfg_get parentcontrol.@weburl[0].timestart)"
t_eq 'hd_mode=off → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@weburl[0].hd_mode)"
t_eq 'hd 起止未写' '' "$(cfg_get parentcontrol.@weburl[0].hd_start)"

echo '== week=6,7 → 节假日=额度(不限)；平日=关闭 =='
t_eq 'sd_mode=off → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@weburl[1].sd_mode)"
t_eq 'hd_mode 已统一为 quota → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@weburl[1].hd_mode)"
t_eq 'hd_unlimited=1' 1 "$(cfg_get parentcontrol.@weburl[1].hd_unlimited)"
t_eq 'hd 可用时段' '09:00:00-21:00:00' "$(cfg_get parentcontrol.@weburl[1].hd_qstart)-$(cfg_get parentcontrol.@weburl[1].hd_qend)"

echo '== week 缺失 → 视作 * → 两侧都设 =='
t_eq 'time[0] sd_mode → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@time[0].sd_mode)"
t_eq 'time[0] hd_mode → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@time[0].hd_mode)"

echo '== week 混合(1,7) → 两侧都设 =='
t_eq 'time[1] sd_mode → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@time[1].sd_mode)"
t_eq 'time[1] hd_mode → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@time[1].hd_mode)"

echo '== 只含工作日(3) → 平日=额度(不限)（协议模块）=='
t_eq 'protocol sd_mode → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@protocol[0].sd_mode)"
t_eq 'protocol sd_unlimited' 1 "$(cfg_get parentcontrol.@protocol[0].sd_unlimited)"
t_eq 'protocol hd_mode=off → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@protocol[0].hd_mode)"

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
t_eq '已有 sd_mode → 不覆盖 → 模式键已删除（统一模型没有模式枚举）' '' "$(cfg_get parentcontrol.@weburl[0].sd_mode)"
t_eq '已有 sd_mode → 不补 hd_mode' '' "$(cfg_get parentcontrol.@weburl[0].hd_mode)"
t_eq '已有额度 → unlimited 补 0' 0 "$(cfg_get parentcontrol.@weburl[0].sd_unlimited)"
t_eq '已有额度 → 额度不动' 30 "$(cfg_get parentcontrol.@weburl[0].sd_quota)"
t_eq '已有额度 → 不加时段（老额度模式本来 24h 可用，别静默收紧成 12h）' '-' "$(cfg_get parentcontrol.@weburl[0].sd_qstart)-$(cfg_get parentcontrol.@weburl[0].sd_qend)"

echo '== B1 防线：只配了节假日档案 + 残留 week → 不得覆盖已设值，也不得凭空造出平日档案 =='
cfg_reset
cat > "$T_TMP/hdonly.uci" <<'EOF'
config weburl
	option enable '1'
	option week '1,2,3'
	option hd_unlimited '0'
	option hd_quota '30'
	option hd_qstart '08:00:00'
	option hd_qend '20:00:00'
EOF
cfg_load parentcontrol "$T_TMP/hdonly.uci"
pc_migrate_config
t_eq 'hd 额度未被覆盖' '30' "$(cfg_get parentcontrol.@weburl[0].hd_quota)"
t_eq 'hd_unlimited 未被改成 1（老 bug：会被无条件写 1 → 升级后静默解封）' '0' "$(cfg_get parentcontrol.@weburl[0].hd_unlimited)"
t_eq 'hd 时段未被改成 00:00:00-23:59:59' '08:00:00-20:00:00' "$(cfg_get parentcontrol.@weburl[0].hd_qstart)-$(cfg_get parentcontrol.@weburl[0].hd_qend)"
t_eq '未凭空造出平日档案（sd_quota 应为空）' '' "$(cfg_get parentcontrol.@weburl[0].sd_quota)"
t_eq '未凭空造出平日时段' '-' "$(cfg_get parentcontrol.@weburl[0].sd_qstart)-$(cfg_get parentcontrol.@weburl[0].sd_qend)"
t_eq 'week 残留已清掉' '' "$(cfg_get parentcontrol.@weburl[0].week)"

t_summary
