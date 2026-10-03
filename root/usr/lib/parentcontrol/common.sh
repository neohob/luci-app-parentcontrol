# 纯逻辑库：日子类型判定 / 额度状态 / 用量读写 / 配额计算
# 被 /etc/init.d/parentcontrol source。
# 依赖：uci，以及 busybox 基础工具 date/sed/grep/tr/awk/sort/find。
# 测试（test/common_test.sh）只给 date 与 uci 打桩，其余走真实命令。

PC_CONF=${PC_CONF:-parentcontrol}
# 三个模块的固定顺序（唯一来源，别在各处再硬编码）
PC_MODULES=${PC_MODULES:-"time protocol weburl"}
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

# ---------- 配额基础 ----------
# 额度按自然日重置（用量文件按 YYYYMMDD 分文件），不再有「发放时刻」概念。

# 把 "HH:MM"（或 "HH" + 可选 MM 参数）转成分钟数。
# 注意：busybox ash 不支持 `10#` 进制前缀，"08"/"09" 直接算术也会被当八进制报错，
# 所以用字符串去前导零。
# HH:MM[:SS] → 当天秒数（非法/空 → 无输出）
pc_hhmmss_to_sec() {
	local _h _m _s
	case "$1" in
	*:*:*) _h=${1%%:*}; _m=${1#*:}; _s=${_m#*:}; _m=${_m%%:*} ;;
	*:*)   _h=${1%%:*}; _m=${1#*:}; _s=0 ;;
	*)     return 0 ;;
	esac
	_h=${_h#0}; [ -z "$_h" ] && _h=0
	_m=${_m#0}; [ -z "$_m" ] && _m=0
	_s=${_s#0}; [ -z "$_s" ] && _s=0
	case "$_h$_m$_s" in *[!0-9]*) return 0 ;; esac
	[ "$_h" -le 23 ] 2>/dev/null || return 0
	[ "$_m" -le 59 ] 2>/dev/null || return 0
	[ "$_s" -le 59 ] 2>/dev/null || return 0
	echo $((_h * 3600 + _m * 60 + _s))
}

# 当天秒数 → HH:MM:SS
pc_sec_hhmmss() {
	printf '%02d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 ))
}

# 本地秒区间 [起,止] → -m time 用的 UTC 区间。跨 UTC 零点时切成两段，逐行输出「起 止」。
# 偏移固定 UTC+8（与渲染层一致），不依赖内核时区（--kerneltz 在 OpenWrt 上不可靠）。
pc_utc_ranges() { # $1=起秒 $2=止秒
	local _s _e
	_s=$(( ($1 - 28800 + 86400) % 86400 ))
	_e=$(( ($2 - 28800 + 86400) % 86400 ))
	if [ "$_s" -le "$_e" ]; then
		echo "$_s $_e"
	else
		echo "$_s 86399"
		echo "0 $_e"
	fi
}

# 该条目今天是否勾了「不限额度」
pc_entry_unlimited() { # $1=module $2=idx $3=school|holiday
	local _v _q _p
	_v=$(pc_uget "@$1[$2].$(pc_suffix "$3")_unlimited")
	[ "$_v" = "1" ] && { echo 1; return 0; }
	[ -n "$_v" ] && { echo 0; return 0; }          # 显式写了 0 → 按有限额处理
	# _unlimited 没设：只有当额度也完全没填时才算"不限"（fail-open）。
	# 否则"新条目还没配额度""老配置漏了额度"都会被静默当成 0 分钟 = 全禁。想全禁请显式填 0。
	_q=$(pc_uget "@$1[$2].$(pc_suffix "$3")_quota")
	[ -z "$_q" ] || { echo 0; return 0; }
	# 没填自己的额度：如果挂进了共享池，限制由池负责 → 仍算"有限额"，不能当不限
	_p=$(pc_entry_pool "$1" "$2" "$3")
	[ -z "$_p" ] && echo 1 || echo 0
}

# 可用时段（本地秒）「起 止」；未设 / 全天 / 非法 → 无输出（= 不限制时段）
pc_qwin_sec() { # $1=module $2=idx $3=school|holiday
	local _s _e _ss _ee _sfx
	_sfx=$(pc_suffix "$3")
	_s=$(pc_uget "@$1[$2].${_sfx}_qstart")
	_e=$(pc_uget "@$1[$2].${_sfx}_qend")
	[ -n "$_s" ] && [ -n "$_e" ] || return 0
	_ss=$(pc_hhmmss_to_sec "$_s"); _ee=$(pc_hhmmss_to_sec "$_e")
	[ -n "$_ss" ] && [ -n "$_ee" ] || return 0
	# 起必须 < 止（表单已拦，这里兜底）：不合法就按“不限制”处理，绝不因为脏数据把设备整天封死
	[ "$_ss" -lt "$_ee" ] 2>/dev/null || return 0
	[ "$_ss" = 0 ] && [ "$_ee" = 86399 ] && return 0
	echo "$_ss $_ee"
}

# 可用时段「以外」的 UTC 区间（逐行输出「起秒 止秒」），供 -m time 正向匹配。
pc_qwin_out_ranges() { # $1=module $2=idx $3=school|holiday
	local _w _s _e
	_w=$(pc_qwin_sec "$1" "$2" "$3")
	[ -n "$_w" ] || return 0
	set -- $_w
	_s=$1; _e=$2
	[ "$_s" -gt 0 ] && pc_utc_ranges 0 $((_s - 1))
	[ "$_e" -lt 86399 ] && pc_utc_ranges $((_e + 1)) 86399
	return 0
}


# 北京时间 HH:MM → UTC HH:MM（iptables 的 -m time 默认 UTC，用它就不依赖内核时区）

# 当前上海时间是否已过当日重置点 → 0(是，额度已发放) / 1(否)

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

# 档案生效模式：off | time | quota（未设=time，兼容老配置）

# 今天处于「每日额度」模式的条目键（<module>_<idx>），每行一个。
# 所有额度相关遍历都从这里出发，避免模块清单散落各处。
# 所有已启用条目的 key（模块序 time/protocol/weburl）。
# 统一模型里没有"模式"了：每个条目都有「可用时段 + 额度」，是否真的限制由这两个字段决定
# （额度 0 = 全禁；勾了不限额度 + 时段全天 = 完全不限制，此时只计数不封锁）。
pc_active_keys() {
	local _m _i
	for _m in $PC_MODULES; do
		for _i in $(pc_ids_on "$_m"); do
			echo "${_m}_${_i}"
		done
	done
}

# 局域网网段（IPv4，UCI 里所有 proto=static 的 network 节）。
# 用途：封锁规则前面先放行「到局域网/路由器自身」的流量，避免把自己锁在门外。
pc_lan_nets() {
	local _s _ip _nm
	uci -q show network 2>/dev/null \
		| sed -n "s/^network\.\([A-Za-z0-9_-]*\)\.proto='static'$/\1/p" \
		| while read -r _s; do
			_ip=$(uci -q get "network.$_s.ipaddr")
			_nm=$(uci -q get "network.$_s.netmask")
			[ -n "$_ip" ] && [ -n "$_nm" ] && echo "$_ip/$_nm"
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
	local _k _i _m _w _d _ts _te _has_sd _has_hd _sfx _md
	# 1) 默认值
	for _k in usage_keep usage_min_kb; do
		[ -n "$(pc_uget "@basic[0].$_k")" ] && continue
		case "$_k" in
		usage_keep)                 uci -q set "$PC_CONF.@basic[0].$_k=90" ;;
		usage_min_kb)               uci -q set "$PC_CONF.@basic[0].$_k=8" ;;
		esac
	done

	# 2) 老配置里只填了 word 的，搬到 domains（否则升级后匹配串为空，静默失效）
	for _i in $(pc_ids_all weburl); do
		_w=$(pc_uget "@weburl[$_i].word")
		_d=$(pc_uget "@weburl[$_i].domains")
		if [ -n "$_w" ] && [ -z "$_d" ]; then
			uci -q set "$PC_CONF.@weburl[$_i].domains=$_w"
		fi
		# 老 word 一律删除：否则改了域名后，旧关键词仍会生成幽灵匹配规则
		[ -n "$_w" ] && uci -q delete "$PC_CONF.@weburl[$_i].word"
	done

	# 3) 老 week 拆到双档案：只含 1-5 → 平日；只含 6,7 → 节假日；* 或混合 → 两者
	for _m in time protocol weburl; do
		for _i in $(pc_ids_all "$_m"); do
			# 守卫：已有 mode 键、或已有任一「新模型字段」都算处理过 —— 直接跳过。
			# （mode 键会被第 4 步删掉，所以不能只靠它当守卫，否则第二次跑会把用户设过的值覆盖。）
			[ -n "$(pc_uget "@$_m[$_i].sd_mode")" ] && continue
			[ -n "$(pc_uget "@$_m[$_i].sd_qstart")" ] && continue
			[ -n "$(pc_uget "@$_m[$_i].sd_quota")" ] && continue
			[ -n "$(pc_uget "@$_m[$_i].sd_unlimited")" ] && continue
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

	# 4) 统一模型迁移：老的「时段」模式没有额度、语义是“封某一段”，而新模型只有
	#    “可用时段”，两者补集跨日、无法无损换算。按既定方案：
	#      老时段 → 每日额度 + 不限额度 + 09:00:00-21:00:00
	#      已有额度 → 额度保持不变，仅补上「不限额度=否」与时段
	#    已有 entries 在档时段的条目也会被补上 09:00-21:00（与迁移方案一致）。
	for _m in time protocol weburl; do
		for _i in $(pc_ids_all "$_m"); do
			for _sfx in sd hd; do
				# mode 已废弃：改成由「可用时段 + 额度」表达（不再有模式枚举）
				_md=$(pc_uget "@$_m[$_i].${_sfx}_mode")
				case "$_md" in
				time)
					# 老「时段」语义是"封某一段"，新模型只有"可用时段"（不跨日），无法无损换算
					# → 按既定方案统一为 不限额度 + 09:00-21:00
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
					_pclog "migrate: $_m[$_i] ${_sfx}: 老「时段」→ 不限额度 + 09:00-21:00" ;;
				off)
					# 老「关闭」= 不限制 → 不限额度 + 全天
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_qstart=00:00:00"
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_qend=23:59:59" ;;
				block)
					# 上一版短暂存在过的 block → 额度 0（0 = 一分钟都不给）
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=0"
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_quota=0" ;;
				quota)
					# 只在没设过时才补；且「没填额度」的老语义是不限 → 补 1 而不是 0
					if [ -z "$(pc_uget "@$_m[$_i].${_sfx}_unlimited")" ]; then
						if [ -n "$(pc_uget "@$_m[$_i].${_sfx}_quota")" ]; then
							uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=0"
						else
							uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
							_pclog "migrate: $_m[$_i] ${_sfx}: 额度模式但没填额度 → 不限（否则会被当成 0 分钟全禁）"
						fi
					fi ;;
				esac
				[ -n "$_md" ] && uci -q delete "$PC_CONF.@$_m[$_i].${_sfx}_mode"
				# 只有确实在迁移某个老 mode 时才补时段。若 _md 为空（例如出厂默认配置里
				# 只配了 sd_* 的条目），**整个 suffix 不动**——否则会凭空给它 09:00-21:00 +
				# 空额度 → 被当成 0 分钟全禁（B4）。
				if [ -n "$_md" ]; then
					[ -n "$(pc_uget "@$_m[$_i].${_sfx}_qstart")" ] || uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_qstart=09:00:00"
					[ -n "$(pc_uget "@$_m[$_i].${_sfx}_qend")" ] || uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_qend=21:00:00"
				fi
				# 老的「额度模式但没填额度」原来等于"不限"。新语义里 0 = 全天禁止，
				# 不显式标一下就会在升级后被静默全禁 —— 这里补成"不限"（只在没设过时补，幂等）。
				# 想全禁请显式填 0。
				if [ "$(pc_uget "@$_m[$_i].${_sfx}_mode")" = "quota" ] && \
				   [ -z "$(pc_uget "@$_m[$_i].${_sfx}_quota")" ] && \
				   [ -z "$(pc_uget "@$_m[$_i].${_sfx}_unlimited")" ]; then
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
					_pclog "migrate: $_m[$_i] ${_sfx}: 额度模式但没填额度 → 显式「不限额度」（新语义 0=全禁）"
				fi
				# 上一版短暂存在过的 block 模式 → 每日额度 + 额度 0
				if [ "$(pc_uget "@$_m[$_i].${_sfx}_mode")" = "block" ]; then
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_mode=quota"
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_quota=0"
					uci -q set "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=0"
					_pclog "migrate: $_m[$_i] ${_sfx}: block 模式 → 每日额度 + 0 分钟（全天禁止）"
				fi
			done
		done
	done
}

# 迁移期的日志：uci-defaults 环境没有 elog（那是 init.d 的），这里自带兜底格式
_pclog() {
	mkdir -p /tmp/log 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "${LOG_FILE:-/tmp/log/parentcontrol.log}"
}
