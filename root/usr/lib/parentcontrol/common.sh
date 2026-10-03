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

# 该条目今天是否勾了「不限额度」（输出 1=不限）。
# 这是全仓唯一的「谁受额度限制」判定口径：build_quota_blocks / pool_usage / stats_tsv / 列表页 都读它。
pc_entry_unlimited() { # $1=module $2=idx $3=school|holiday
	local _v _q _p _pq
	_v=$(pc_uget "@$1[$2].$(pc_suffix "$3")_unlimited")
	[ "$_v" = "1" ] && { echo 1; return 0; }
	[ -n "$_v" ] && { echo 0; return 0; }          # 显式写了 0 → 按有限额处理
	# _unlimited 没设：看额度/共享池来决定。凡是「没有任何额度来源」都算不限（fail-open）——
	# 否则“新条目还没配额度”“老配置漏了额度”“挂了池但池没额度”都会被静默当成 0 分钟 = 全天全禁。
	_q=$(pc_uget "@$1[$2].$(pc_suffix "$3")_quota")
	[ -n "$_q" ] && { echo 0; return 0; }
	# 没填自己的额度：挂了池且池确实有额度 → 限制由池负责，算“有限额”
	_p=$(pc_entry_pool "$1" "$2" "$3")
	if [ -n "$_p" ]; then
		_pq=$(pc_pool_quota "$_p" "$3")
		[ -n "$_pq" ] && { echo 0; return 0; }
	fi
	echo 1
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

# 只在 uci 里没设过该项时才写。迁移幂等的关键：绝不覆盖用户已经设过的值。
_pcset() { # $1=@type[idx].option=value
	[ -n "$(pc_uget "${1%%=*}")" ] || uci -q set "$PC_CONF.$1"
}

# 把空/非数字额度归一为 0。注意新语义：0 = 一分钟都不给（全禁），不是"不限"。
pc_quota_positive() {
	case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac
}

# ============================================================================
# 配置迁移（安装/升级时调用一次，幂等）：
#   1) 补 basic 默认值；2) 老 word(关键词) → domains；3) 统一为「可用时段 + 额度」模型
# 只改 uci，不 commit（由调用方决定）。
# ============================================================================
pc_migrate_config() {
	local _k _i _m _w _d _f _has_sd _has_hd _sfx _md _ws _we _on _had_dual
	# 0) 迁移会删老字段、并可能改变封锁行为，不可逆 —— 先留一份带时间戳的备份。
	#    （README 里承诺了这件事，就必须真的做；测试环境没有 /etc/config 时自动跳过。）
	if [ -f "/etc/config/$PC_CONF" ]; then
		mkdir -p /etc/parentcontrol/backup 2>/dev/null
		cp -a "/etc/config/$PC_CONF" 			"/etc/parentcontrol/backup/$PC_CONF.$(date +%Y%m%d%H%M%S).bak" 2>/dev/null
	fi
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

	# 3) 统一为「可用时段 + 额度」模型。老配置有两代：
	#      a) 双档案时代：<sfx>_mode ∈ off|time|quota|block（另有 <sfx>_start/<sfx>_end）
	#      b) 更早的「按星期」时代：week + timestart/timeend（由 week 决定哪个档案生效）
	#    映射（既定方案）：
	#      time  → 不限额度 + 09:00-21:00（老语义是"封某一段"，新模型只有"可用时段"，
	#              无法无损换算；给 WhatsApp 工作时段、并在日志里留痕）
	#      quota → 额度原样保留，只补 unlimited=0。老 quota 本来全天 24h 可用，
	#              不额外加时段，免得把存量用户静默收紧成每天 12 小时
	#      block → 额度 0（0 = 一分钟都不给）
	#      off   → 不限额度（不写时段 = 全天可用）
	#      week  → 该档案在老模型里生效 = 当年有时段限制 → 不限额度 + 09:00-21:00
	#              没生效 → 不限额度（不写时段）
	#    幂等的关键：所有写入都走 _pcset（只在没设过时写），重跑绝不覆盖用户改过的值；
	#    老键（mode/start/end/week/timestart/timeend）一次性清掉，断掉重跑触发源。
	for _m in $PC_MODULES; do
		for _i in $(pc_ids_all "$_m"); do
			# 这个条目属于哪个时代？有 <sfx>_mode（双档案时代）或任一新模型字段 → 已经是新模型，
			# 此时残留的 week 只是垃圾：删掉即可，绝不能用它给没配过的档案凭空造出一条限制。
			_had_dual=0
			for _sfx in sd hd; do
				[ -n "$(pc_uget "@$_m[$_i].${_sfx}_mode")" ] && _had_dual=1
				for _f in unlimited qstart qend quota pool; do
					[ -n "$(pc_uget "@$_m[$_i].${_sfx}_$_f")" ] && _had_dual=1
				done
			done
			# 老 week：决定哪几个档案在老模型里是"生效"的（没设 week = 不是"按星期"时代）
			_w=$(pc_uget "@$_m[$_i].week")
			_has_sd=1; _has_hd=1
			if [ -n "$_w" ]; then
				case "$_w" in
				*'*'*) ;;
				*)
					_has_sd=0; _has_hd=0
					for _d in $(echo "$_w" | tr ',' ' '); do
						case "$_d" in 6|7) _has_hd=1 ;; *) _has_sd=1 ;; esac
					done ;;
				esac
			fi
			for _sfx in sd hd; do
				_md=$(pc_uget "@$_m[$_i].${_sfx}_mode")
				_ws=; _we=
				case "$_md" in
				time)
					_pcset "@$_m[$_i].${_sfx}_unlimited=1"
					_ws=09:00:00; _we=21:00:00
					_pclog "migrate: $_m[$_i] ${_sfx}: 老「时段」→ 不限额度 + 09:00-21:00" ;;
				block)
					_pcset "@$_m[$_i].${_sfx}_unlimited=0"
					_pcset "@$_m[$_i].${_sfx}_quota=0"
					_pclog "migrate: $_m[$_i] ${_sfx}: 老「全天禁止」→ 额度 0" ;;
				quota)
					# 老配额模式当年的运行判据是 `[ "$q" -gt 0 ] || continue`（c4fe179..a1ae0e9），
					# 也就是「没填」和「填 0」在老语义里都等于"不限"。新语义里 0 = 全禁，
					# 所以这两种都必须显式补成不限，否则升级后会静默把设备锁死。
					case "$(pc_uget "@$_m[$_i].${_sfx}_quota")" in
					''|0)
						_pcset "@$_m[$_i].${_sfx}_unlimited=1"
						_pclog "migrate: $_m[$_i] ${_sfx}: 老配额为空/0（老语义=不限）→ 不限" ;;
					*)
						_pcset "@$_m[$_i].${_sfx}_unlimited=0" ;;
					esac ;;
				off)
					_pcset "@$_m[$_i].${_sfx}_unlimited=1" ;;
				'')
					# 只有真的处在「按星期」时代的老条目才推窗口；已经是新模型的条目
					# 完全不动（这样"只配了某一边档案"的条目不会被造出另一边）
					if [ "$_had_dual" = 0 ]; then
						if [ "$_sfx" = "sd" ]; then _on=$_has_sd; else _on=$_has_hd; fi
						_pcset "@$_m[$_i].${_sfx}_unlimited=1"
						if [ -n "$_w" ] && [ "$_on" = 1 ]; then
							_ws=09:00:00; _we=21:00:00
							_pclog "migrate: $_m[$_i] ${_sfx}: 老「按星期 + 时段」→ 不限额度 + 09:00-21:00"
						fi
					fi ;;
				esac
				# 只在确定存在"老时段限制"时才补窗口；其余一律不写时段
				# （= 全天可用），避免把本来 24h 可用的条目静默收紧。
				if [ -n "$_ws" ]; then
					_pcset "@$_m[$_i].${_sfx}_qstart=$_ws"
					_pcset "@$_m[$_i].${_sfx}_qend=$_we"
				fi
				uci -q delete "$PC_CONF.@$_m[$_i].${_sfx}_mode"
				uci -q delete "$PC_CONF.@$_m[$_i].${_sfx}_start"
				uci -q delete "$PC_CONF.@$_m[$_i].${_sfx}_end"
			done
			uci -q delete "$PC_CONF.@$_m[$_i].week"
			uci -q delete "$PC_CONF.@$_m[$_i].timestart"
			uci -q delete "$PC_CONF.@$_m[$_i].timeend"
		done
	done
}

# 迁移期的日志：uci-defaults 环境没有 elog（那是 init.d 的），这里自带兜底格式
_pclog() {
	mkdir -p /tmp/log 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "${LOG_FILE:-/tmp/log/parentcontrol.log}"
}
