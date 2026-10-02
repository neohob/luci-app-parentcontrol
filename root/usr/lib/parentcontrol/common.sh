# 纯逻辑库：日子类型判定 / 额度状态 / 用量读写 / 配额计算
# 被 /etc/init.d/parentcontrol source。除 `uci` 外不依赖任何外部命令，
# 便于 test/common_test.sh 直接 source 后用桩函数测试。

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
	_d="$1"
	_y=${_d%%-*}
	_f="$HOLIDAY_CACHE/$_y.json"
	[ -f "$_f" ] || return 1
	# 每个 { ... } 对象压到一行（holiday-cn 的对象无嵌套花括号），再找日期
	_line=$(tr '}' '\n' < "$_f" | grep -F "$_d" | head -1)
	[ -n "$_line" ] || return 1
	case "$_line" in
	*'"isOffDay": true'*)  echo 1 ;;
	*'"isOffDay": false'*) echo 0 ;;
	*)                     return 1 ;;
	esac
}

# 是否落在某个 vacation 区间内。输出 1/0。
# start/end 支持 MM-DD（每年重复，自动补当年/跨年）或 YYYY-MM-DD（绝对）。
pc_in_vacation() {
	_d="$1"
	_y=${_d%%-*}
	for _i in $(pc_ids_all vacation); do
		_s=$(pc_uget "@vacation[$_i].start")
		_e=$(pc_uget "@vacation[$_i].end")
		[ -n "$_s" ] && [ -n "$_e" ] || continue
		case "$_s" in *-*-*) _ss="$_s" ;; *) _ss="$_y-$_s" ;; esac
		case "$_e" in *-*-*) _ee="$_e" ;; *) _ee="$_y-$_e" ;; esac
		if [ "$_ss" \> "$_ee" ]; then
			# 跨年区间（如寒假 12-20 ~ 01-05）
			if [ "$_d" \> "$_ss" ] || [ "$_d" = "$_ss" ] \
			   || [ "$_d" \< "$_ee" ] || [ "$_d" = "$_ee" ]; then
				echo 1; return 0
			fi
		else
			if { [ "$_d" \> "$_ss" ] || [ "$_d" = "$_ss" ]; } \
			   && { [ "$_d" \< "$_ee" ] || [ "$_d" = "$_ee" ]; }; then
				echo 1; return 0
			fi
		fi
	done
	echo 0
}

# 今天是什么日子：school | holiday
pc_today_type() {
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
	_r=$(pc_uget "@basic[0].reset_$1")
	[ -n "$_r" ] || _r="12:00"
	echo "$_r"
}

# 当前上海时间是否已过当日重置点 → 0(是，额度已发放) / 1(否)
pc_allowance_issued() {
	_now=$((10#$(date +%H) * 60 + 10#$(date +%M)))
	_rh=${1%%:*}; _rm=${1##*:}
	[ "$_now" -ge $((10#$_rh * 60 + 10#$_rm)) ]
}

# ---------- 用量读写 ----------
pc_usage_file() { echo "$USAGE_DIR/$(date +%Y%m%d)"; }

pc_usage_get() {
	_f=$(pc_usage_file)
	[ -f "$_f" ] || { echo 0; return; }
	awk -v k="$1" '$1==k{s+=$2} END{printf "%d\n", s+0}' "$_f"
}

pc_usage_add() {
	_f=$(pc_usage_file)
	mkdir -p "$USAGE_DIR"
	printf '%s %s\n' "$1" "$2" >> "$_f"
}

# ---------- 配额计算 ----------
# 池额度（分钟）。输出空串表示不限。
pc_pool_quota() {
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
	_sfx=$(pc_suffix "$3")
	pc_uget "@$1[$2].${_sfx}_pool"
}

# 条目自己的额度（分钟，空=不限）
pc_entry_quota() {
	_sfx=$(pc_suffix "$3")
	pc_uget "@$1[$2].${_sfx}_quota"
}

# 条目今天的模式：off|time|quota（空=off）
pc_entry_mode() {
	_sfx=$(pc_suffix "$3")
	pc_uget "@$1[$2].${_sfx}_mode"
}

# 把非数字/空额度归一：输出 0 表示不限，>0 表示分钟上限
pc_quota_positive() {
	case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac
}
