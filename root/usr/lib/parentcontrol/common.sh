# 纯逻辑库：日子类型判定 / 额度状态 / 用量读写 / 配额计算
# 被 /etc/init.d/parentcontrol source。
# 依赖：uci，以及 busybox 基础工具 date/sed/grep/tr/awk/sort/find。
# 测试（test/common_test.sh）只给 date 与 uci 打桩，其余走真实命令。

PC_CONF=${PC_CONF:-parentcontrol}
HOLIDAY_CACHE=${HOLIDAY_CACHE:-/etc/parentcontrol/holiday}
USAGE_DIR=${USAGE_DIR:-/etc/parentcontrol/usage}

# ---------- 基础 ----------
pc_uget() { uci -q get "$PC_CONF.$1"; }

# 某模块全部 section 下标（不论是否勾选）
pc_ids_all() {
	uci show "$PC_CONF" 2>/dev/null \
		| sed -n "s/^${PC_CONF}\.@$1\[\([0-9][0-9]*\)\]\..*=.*/\1/p" | sort -un
}

# 某模块已勾选 enable='1' 的 section 下标
pc_ids_on() {
	uci show "$PC_CONF" 2>/dev/null \
		| sed -n "s/^${PC_CONF}\.@$1\[\([0-9][0-9]*\)\]\.enable='1'$/\1/p" | sort -un
}

# ---------- 日期 ----------
pc_today() { date +%Y-%m-%d; }
pc_weekday() { date +%u; }   # 1=Mon .. 7=Sun

# ---------- 节假日数据（holiday-cn 格式）----------
# 判定 d(YYYY-MM-DD) 的法定属性：
#   输出 1 = 法定放假(isOffDay:true)；0 = 法定调休上班(isOffDay:false)；空 = 无数据
pc_holiday_flag() {
	local _d _y _f _o
	_d="$1"
	_y=${_d%%-*}
	_f="$HOLIDAY_CACHE/$_y.json"
	[ -f "$_f" ] || return 1
	# 首选 OpenWrt 规范工具 jsonfilter；它不可用/无该日期时落到下面的兜底
	if command -v jsonfilter >/dev/null 2>&1; then
		case "$(jsonfilter -i "$_f" -e "@.days[@.date='$_d'].isOffDay" 2>/dev/null)" in
		true)  echo 1; return 0 ;;
		false) echo 0; return 0 ;;
		esac
	fi
	# 兜底：去掉所有空白后按扁平对象精确匹配（不假设缩进/换行/空格）
	_o=$(tr -d ' \t\n\r' < "$_f" | grep -o "{[^{}]*\"date\":\"$_d\"[^{}]*}")
	case "$_o" in
	*'"isOffDay":true'*)  echo 1 ;;
	*'"isOffDay":false'*) echo 0 ;;
	*)                    return 1 ;;
	esac
}

# 是否落在某个 vacation 区间内。输出 1/0。
# start/end 支持 MM-DD（每年重复，自动补当年/跨年）或 YYYY-MM-DD（绝对）。
pc_in_vacation() {
	local _d _y _i _s _e _ss _ee
	_d="$1"
	_y=${_d%%-*}
	for _i in $(pc_ids_all vacation); do
		_s=$(pc_uget "@vacation[$_i].start")
		_e=$(pc_uget "@vacation[$_i].end")
		[ -n "$_s" ] && [ -n "$_e" ] || continue
		case "$_s" in *-*-*) _ss="$_s" ;; *) _ss="$_y-$_s" ;; esac
		case "$_e" in *-*-*) _ee="$_e" ;; *) _ee="$_y-$_e" ;; esac
		# ISO 日期串按字典序即时间序；ss>ee 表示跨年（寒假 12-20 ~ 01-05）
		if awk -v d="$_d" -v a="$_ss" -v b="$_ee" \
			'BEGIN { exit (a > b) ? !(d >= a || d <= b) : !(d >= a && d <= b) }'; then
			echo 1; return 0
		fi
	done
	echo 0
}

# 今天是什么日子：school | holiday
pc_today_type() {
	local _d _h
	_d=$(pc_today)
	[ "$(pc_in_vacation "$_d")" = "1" ] && { echo holiday; return; }
	_h=$(pc_holiday_flag "$_d")
	if [ "$_h" = "1" ]; then echo holiday; return; fi
	if [ "$_h" = "0" ]; then echo school;  return; fi
	# 无当年数据 → 降级：周末=节假日，周中=平日
	case "$(pc_weekday)" in
	6|7) echo holiday ;;
	*)   echo school ;;
	esac
}

# 把 school/holiday 映射成配置前缀 sd/hd
pc_suffix() { [ "$1" = "holiday" ] && echo hd || echo sd; }

# ---------- 重置时刻与额度三态 ----------
# 全局重置时间（HH:MM），按 Asia/Shanghai 解释（date 已由 wrapper 固定 TZ）
pc_reset_for() {
	local _r
	_r=$(pc_uget "@basic[0].reset_$1")
	[ -n "$_r" ] || _r="12:00"
	echo "$_r"
}

# 当前上海时间是否已过当日重置点 → 0(是，额度已发放) / 1(否)
pc_allowance_issued() {
	local _now _rh _rm
	_now=$((10#$(date +%H) * 60 + 10#$(date +%M)))
	_rh=${1%%:*}; _rm=${1##*:}
	[ "$_now" -ge $((10#$_rh * 60 + 10#$_rm)) ]
}

# ---------- 用量读写 ----------
pc_usage_file() { echo "$USAGE_DIR/$(date +%Y%m%d)"; }

pc_usage_get() {
	local _f
	_f=$(pc_usage_file)
	[ -f "$_f" ] || { echo 0; return; }
	awk -v k="$1" '$1==k{s+=$2} END{printf "%d\n", s+0}' "$_f"
}

pc_usage_add() {
	local _f
	_f=$(pc_usage_file)
	mkdir -p "$USAGE_DIR"
	printf '%s %s\n' "$1" "$2" >> "$_f"
}

# ---------- 配额计算 ----------
# 池额度（分钟）。输出空串表示不限。
pc_pool_quota() {
	local _sfx _i _v
	# $1=池名 $2=school|holiday
	_sfx=$(pc_suffix "$2")
	for _i in $(pc_ids_all quota); do
		[ "$(pc_uget "@quota[$_i].name")" = "$1" ] || continue
		_v=$(pc_uget "@quota[$_i].${_sfx}_quota")
		[ -z "$_v" ] && _v=$(pc_uget "@quota[$_i].quota")
		echo "$_v"; return
	done
}

# 条目生效的池名（空=私有）
pc_entry_pool() {
	local _sfx
	_sfx=$(pc_suffix "$3")
	pc_uget "@$1[$2].${_sfx}_pool"
}

# 条目自己的额度（分钟，空=不限）
pc_entry_quota() {
	local _sfx
	_sfx=$(pc_suffix "$3")
	pc_uget "@$1[$2].${_sfx}_quota"
}

# 条目今天的模式：off|time|quota（空=off）
pc_entry_mode() {
	local _sfx
	_sfx=$(pc_suffix "$3")
	pc_uget "@$1[$2].${_sfx}_mode"
}

# 档案生效模式：off | time | quota（未设=time，兼容老配置）
pc_entry_eff_mode() {
	local _md
	_md=$(pc_entry_mode "$1" "$2" "$3")
	[ -z "$_md" ] && _md=time
	echo "$_md"
}

# 今天处于「每日额度」模式的条目键（<module>_<idx>），每行一个。
# 所有额度相关遍历都从这里出发，避免模块清单散落各处。
pc_quota_keys() { # $1=school|holiday
	local _m _i
	for _m in time protocol weburl; do
		for _i in $(pc_ids_on "$_m"); do
			[ "$(pc_entry_mode "$_m" "$_i" "$1")" = "quota" ] && echo "${_m}_${_i}"
		done
	done
}

# 把非数字/空额度归一：输出 0 表示不限，>0 表示分钟上限
pc_quota_positive() {
	case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac
}

# ============================================================================
# 配置迁移（安装/升级时调用一次，幂等）：
#   1) 补 basic 默认值；2) 老 word(关键词) → domains；3) 老 week → 平日/节假日双档案
# 只改 uci，不 commit（由调用方决定）。
# ============================================================================
pc_migrate_config() {
	local _k _i _m _w _d _ts _te _has_sd _has_hd
	# 1) 默认值
	for _k in reset_school reset_holiday usage_keep usage_min_kb; do
		[ -n "$(pc_uget "@basic[0].$_k")" ] && continue
		case "$_k" in
		reset_school|reset_holiday) uci -q set "$PC_CONF.@basic[0].$_k=12:00" ;;
		usage_keep)                 uci -q set "$PC_CONF.@basic[0].$_k=90" ;;
		usage_min_kb)               uci -q set "$PC_CONF.@basic[0].$_k=32" ;;
		esac
	done

	# 2) 老配置里只填了 word 的，搬到 domains（否则升级后匹配串为空，静默失效）
	for _i in $(pc_ids_all weburl); do
		_w=$(pc_uget "@weburl[$_i].word")
		_d=$(pc_uget "@weburl[$_i].domains")
		[ -n "$_w" ] && [ -z "$_d" ] && uci -q set "$PC_CONF.@weburl[$_i].domains=$_w"
	done

	# 3) 老 week 拆到双档案：只含 1-5 → 平日；只含 6,7 → 节假日；* 或混合 → 两者
	for _m in time protocol weburl; do
		for _i in $(pc_ids_all "$_m"); do
			[ -n "$(pc_uget "@$_m[$_i].sd_mode")" ] && continue
			[ -n "$(pc_uget "@$_m[$_i].hd_mode")" ] && continue
			_w=$(pc_uget "@$_m[$_i].week"); [ -z "$_w" ] && _w='*'
			_ts=$(pc_uget "@$_m[$_i].timestart"); [ -z "$_ts" ] && _ts=00:00
			_te=$(pc_uget "@$_m[$_i].timeend"); [ -z "$_te" ] && _te=00:00
			_has_sd=0; _has_hd=0
			case "$_w" in
			*'*'*) _has_sd=1; _has_hd=1 ;;
			*)
				for _d in $(echo "$_w" | tr ',' ' '); do
					case "$_d" in 6|7) _has_hd=1 ;; *) _has_sd=1 ;; esac
				done ;;
			esac
			if [ "$_has_sd" = 1 ]; then
				uci -q set "$PC_CONF.@$_m[$_i].sd_mode=time"
				uci -q set "$PC_CONF.@$_m[$_i].sd_start=$_ts"
				uci -q set "$PC_CONF.@$_m[$_i].sd_end=$_te"
			else
				uci -q set "$PC_CONF.@$_m[$_i].sd_mode=off"
			fi
			if [ "$_has_hd" = 1 ]; then
				uci -q set "$PC_CONF.@$_m[$_i].hd_mode=time"
				uci -q set "$PC_CONF.@$_m[$_i].hd_start=$_ts"
				uci -q set "$PC_CONF.@$_m[$_i].hd_end=$_te"
			else
				uci -q set "$PC_CONF.@$_m[$_i].hd_mode=off"
			fi
		done
	done
}
