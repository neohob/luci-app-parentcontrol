# 纯逻辑库：日子类型判定 / 额度状态 / 用量读写 / 配额计算
# 被 /etc/init.d/parentcontrol source。
# 依赖：uci，以及 busybox 基础工具 date/sed/grep/tr/awk/sort/find。
# 测试（test/common_test.sh）只给 date 与 uci 打桩，其余走真实命令。

PC_CONF=${PC_CONF:-parentcontrol}
PC_CONF_DIR=${PC_CONF_DIR:-/etc/config}
# 三个模块的固定顺序（唯一来源，别在各处再硬编码）
PC_MODULES=${PC_MODULES:-"time protocol weburl"}
HOLIDAY_CACHE=${HOLIDAY_CACHE:-/etc/parentcontrol/holiday}
USAGE_DIR=${USAGE_DIR:-/etc/parentcontrol/usage}
BACKUP_DIR=${BACKUP_DIR:-/etc/parentcontrol/backup}
# 陈旧锁判定（分钟）。start() 与 tick 共用 —— 唯一来源，别在 init.d 里再硬编码。
# 取值理由（A119/D51）：统一到 2（等效门槛 ≈180 s）。start 侧原为 1（≈120 s），提高一分钟是
# **有意**的保守化 —— 慢 start（DNS 黑洞下 15–20 个 weburl 条目逐个解析）实测可达 ~180 s；
# 若 tick 或另一个 start 在 120 s 就判陈旧并抢占，正是 design §11.26.1 L-2 描述的「并发写
# netfilter」。代价：start 死锁（被 OOM/拔电/杀）后的自恢复从 ~120 s 变为 ~180 s，可接受。
PC_LOCK_STALE_MIN=${PC_LOCK_STALE_MIN:-2}

# ---------- 基础 ----------
# ============================================================================
# 运行期 uci 快照（A70/D43，第 11h 轮）
# ============================================================================
# 为什么：tick 热路径**逐规则/逐条目**调 pc_uget()/pc_uci_scan()，每次都会 fork 一个
# uci（真机 ≈11ms）—— 启用态稳态 tick 实测 575 次 uci ≈ 6.5s/分钟（占空比约 12%）。
# 快照把「整个 run 只读一次 `uci show`」，两个取值口改从快照解析 ⇒ uci 调用降到 1 次。
# 快照内容含 ai.apikey ⇒ 文件权限必须 0600（用 umask 077 创建）。
# 失效纪律（A70-2）：任何写操作之后必须让快照失效 —— 见 pc_uset()/pc_udelete()。
# tick / refresh_ip / stats_tsv 是**只读**路径；写点（迁移 / apps / 配额）都在冷路径，
# 失效后回落直连即可（不重取快照，读到的一定是真值）。
#
# 查找串（避免逐次 fork awk/grep）：一次 awk 把快照压成两个字面串，
#   LIT：<键>\t<值>\n…   —— 键 = uci show 键去掉「配置名.」（覆盖命名节、匿名节地址、
#                          其选项、以及「有选项行但无节行」的老残留键）
#   IDX：@<类型>[<位次>]\t<节名>\n…  —— 命名节在 @类型[N] 下标空间里的占位映射
# 取值时用引用展开做子串匹配（不 fork、不做通配解释，'[' ']' 按字面匹配）。
PC_UCI_SNAP=${PC_UCI_SNAP:-}   # 快照文件路径；空 = 未启用（全部回落直连 uci）
PC_UCI_SNAP_LIT=
PC_UCI_SNAP_IDX=
# A98/D48（§11.22）：多行值（LIT 里只剩首行）的键集合，形如 NL+key+NL…。命中即直连取全值。
PC_UCI_SNAP_TRUNC=
PC_CL_DIR=   # 第 11k 轮：直连读缓存目录（= 快照文件 + ".d"，随快照同生共死）
_PC_SNAP_NL='
'
_PC_SNAP_TAB=$(printf '\t')

# 快照内容来源：有快照读快照，否则直连 `uci show`（也是 pc_uci_scan 的输入口）。
# A77/D46：判据必须与 pc_uget 同源（LIT 非空）—— 否则「文件在但 LIT 空」时
# pc_uci_scan 读旧文件、pc_uget 回落直连，两个消费者反向分叉（review15 L-4）。
_pc_snap_src() {
	if [ -n "$PC_UCI_SNAP" ] && [ -n "$PC_UCI_SNAP_LIT" ] && [ -r "$PC_UCI_SNAP" ]; then
		cat "$PC_UCI_SNAP"
	else
		uci show "$PC_CONF" 2>/dev/null
	fi
}

# 一次 awk 把快照压成 LIT/IDX（见上）。值只剥**最外层成对引号**（与真机 uci show 的
# `key='value'` 一致）；用 index() 找第一个 '='，容忍值里含 '='（如带查询串的 URL）。
#
# A73/D45（真机事实，conductor 用 `uci -c` 临时 confdir 逐字节取证）：`uci show` 把值内的
# 单引号印成 **4 字节 `'\''`（hex 27 5c 27 27）**，而 `uci -q get` 原样返回单字节 `'`。
# 转义面**只有单引号一种**（反斜杠 / 双引号 / `$` / 空格 / `=` 在 uci show 里均原样）。
# ⇒ 剥完最外层引号后必须把 `'\''` 还原为 `'`，否则快照值 `it'\''s` ≠ 直连 `it's`，
# 违反 §11.15.2 等价性硬门槛（受影响字段：remarks / ai.apikey 等）。
_pc_snap_build() { # $1=快照文件
	local _all _mk _mk2 _t
	_mk=__pcsnapidx__      # LIT 与 IDX 的分段标记（只可能出现在键行之外）
	_mk2=__pcsnaptrunc__   # A98：IDX 与 TRUNC 的分段标记（同上，只可能出现在键行之外）
	_all=$(awk -v c="$PC_CONF" -v mk="$_mk" -v mk2="$_mk2" '
		{
			if (index($0, c ".") != 1) next
			p = index($0, "=")
			if (p <= length(c) + 1) next
			s = substr($0, length(c) + 2, p - length(c) - 2)
			v = substr($0, p + 1)
			# A98/D48（§11.22.2）：值内的真换行在 uci show 里原样印出 ⇒ 行导向解析只吃得到
			# 首行。**完整（单行）值**必为「单引号 + esc(值) + 单引号」：末字符是收尾引号，且末尾 4 字节
			# 绝不等于转义三元组 \047\\\047\047（该三元组只出现在值内 ⇒ 收尾引号必然缺席）。两者任一
			# 不成立 ⇒ 本行是某多行值的首行（被截断）。判定必须看**原始** v（剥引号之前）。
			# 注：设计书 §11.22.2 的字面写法（只判「首字符是单引号 且末字符非单引号」）漏掉两种形态：
			# 多行值首行恰以引号结尾（raw=\047abc\047\\\047\047）与多行值首行为空（raw=\047）—— 两者末字符
			# 都是单引号，但收尾引号其实在后续行；实证见 test/init_test.sh W164/W165。
			# （W169 护栏：本 awk 程序由 shell 单引号串包裹，其内部**不得**出现字面单引号字节 ——
			#   必须用 \047 八进制写法；11k-2 的注释里写了字面单引号 ⇒ 串提前闭合，注释被当命令
			#   执行，每次调用打 3 行 `not found`。）
			if (substr(v, 1, 1) == "\047") {
				_vl = length(v)
				if (_vl < 2 || substr(v, _vl, 1) != "\047" || (_vl >= 4 && substr(v, _vl - 3, 4) == "\047\\\047\047")) trunc = trunc s "\n"
			}
			# 双引号分支：真机 uci show 只用单引号包裹（§11.17.1 实测），此处为防御性保留
			if (length(v) >= 2) {                  # 只剥最外层成对引号（"\047" = 单引号）
				q1 = substr(v, 1, 1); q2 = substr(v, length(v), 1)
				if ((q1 == "\047" && q2 == "\047") || (q1 == "\"" && q2 == "\"")) v = substr(v, 2, length(v) - 2)
			}
			# A76/D46：把真机 uci show 转义出来的 4 字节序列**单遍**还原为单字节引号。
			# 绝不能重扫已解码的输出：否则当值里**逐字出现** 4 字节 \047\\\047\047 时，
			# 上一次写进去的单字节引号会与后续字节重新拼成假序列被二次折叠（review15
			# Major-1；穷举 3280 例 while 版 141 反例、单遍版 0 反例）。用 oct \047 写单引号
			# （awk 程序由 shell 单引号包裹，不能出现字面单引号），不用动态正则。
			_i = 1; _v = ""
			while (_i <= length(v)) {
				if (substr(v, _i, 4) == "\047\\\047\047") { _v = _v "\047"; _i += 4 }
				else { _v = _v substr(v, _i, 1); _i++ }
			}
			v = _v
			lit = lit s "\t" v "\n"
			if (index(s, ".") != 0) next          # 含 "." ⇒ 选项行，不是节行
			if (substr(s, 1, 1) == "@") {         # 匿名节：类型从地址里取
				ty = substr(s, 2); q = index(ty, "[")
				if (q == 0) next
				ty = substr(ty, 1, q - 1)
			} else ty = v                          # 命名节：值就是类型
			if (ty == "") next
			pos = cnt[ty] + 0; cnt[ty]++
			idx = idx "@" ty "[" pos "]" "\t" s "\n"
		}
		END { printf "\n%s%s\n%s%s\n%s", lit, mk, idx, mk2, trunc }
	' "$1")
	PC_UCI_SNAP_LIT="$_PC_SNAP_NL${_all%%"$_PC_SNAP_NL$_mk"*}$_PC_SNAP_NL"
	_t="${_all#*"$_PC_SNAP_NL$_mk"}"
	PC_UCI_SNAP_IDX="${_t%%"$_mk2"*}$_PC_SNAP_NL"
	# mk2 不会出现在 LIT 里：LIT 的值不含真换行（这正是它被截断的原因），而匹配需要 NL+mk2。
	# 截断键的 LIT 记录照旧保留（不改 LIT 语义、不影响 IDX 解析）。
	# 收尾 NL 必须补：`_all=$(awk …)` 是命令替换，会剥掉末尾换行 ⇒ 段里**最后一个**截断键
	# 拿不到收尾 NL，「NL+key+NL」判据漏判，取值时退化回 LIT 首行（被截断的首行）。
	# 与 LIT/IDX 同形（两者也各补了一个 $_PC_SNAP_NL）。实证：test/init_test.sh W164②k8。
	PC_UCI_SNAP_TRUNC="${_t#*"$_mk2"}$_PC_SNAP_NL"
	# A76-3/D46：空判据 = **填充串相等**。无任何行时上面两式退化成恰好两个换行（非空串但
	# 无实义），归零为真·空 ⇒「LIT 空 ⟺ 快照不可用」不再依赖 _PC_SNAP_TAB 是否非空
	# （_PC_SNAP_TAB 仍用于 LIT/IDX 的查询前缀，只是不再当空判据）。
	if [ "$PC_UCI_SNAP_LIT" = "$_PC_SNAP_NL$_PC_SNAP_NL" ]; then
		PC_UCI_SNAP_LIT=; PC_UCI_SNAP_IDX=; PC_UCI_SNAP_TRUNC=
	fi
}

# 开快照：整个 run 只 `uci show` 一次（已开则空操作）。失败就退回直连。
pc_uci_snap_begin() {
	# A74：只有「本进程真构建过（LIT 非空）」才算已开 —— 挡住 PID 复用读到上一个进程
	# 残留文件的僵态（那时 PC_UCI_SNAP 指向可读的旧文件，但本进程 LIT 还是空的）。
	# 同进程内二次调用仍为空操作（幂等）。
	[ -n "$PC_UCI_SNAP" ] && [ -n "$PC_UCI_SNAP_LIT" ] && return 0
	local _f
	_f=${PC_UCI_SNAP_FILE:-${TMPDIR:-/tmp}/parentcontrol-uci.$$}
	( umask 077; uci show "$PC_CONF" 2>/dev/null > "$_f" ) || { rm -f "$_f"; return 0; }
	PC_UCI_SNAP=$_f
	PC_CL_DIR=$_f.d
	rm -rf "$PC_CL_DIR"   # 新快照代 ⇒ 清派生缓存（防 PID 复用读到上一进程残留）
	_pc_snap_build "$_f"
	if [ -z "$PC_UCI_SNAP_LIT" ]; then   # A74：文件空 / 解析无输出 ⇒ 不留半成品，全量回落直连
		rm -f "$_f"
		rm -rf "$PC_CL_DIR"
		PC_UCI_SNAP=
		PC_UCI_SNAP_LIT=
		PC_UCI_SNAP_IDX=
		PC_UCI_SNAP_TRUNC=
		PC_CL_DIR=
	fi
	return 0
}

# 关快照：删文件 + 清查找串（幂等）。
pc_uci_snap_drop() {
	[ -n "$PC_UCI_SNAP" ] && rm -f "$PC_UCI_SNAP"
	[ -n "$PC_CL_DIR" ] && rm -rf "$PC_CL_DIR"
	PC_UCI_SNAP=
	PC_UCI_SNAP_LIT=
	PC_UCI_SNAP_IDX=
	PC_UCI_SNAP_TRUNC=
	PC_CL_DIR=            # 第 11k 轮：直连读缓存随快照失效一并清（写操作也会走这里）
	return 0
}

# A25（第 15 轮真机 O-8）：回收 /tmp/parentcontrol-uci.<pid> 的代际残留。
# 为什么需要：pc_uci_snap_begin 在 /tmp 落一个按 PID 命名的快照文件（+ .d 派生缓存目录），
# 正常路径由 pc_uci_snap_drop 删；但进程被 kill -9 / OOM / 拔电时 drop 永不执行 ⇒ 每次
# 非正常退出都在 /tmp 留一份（30 天的路由器上会攒成几十份，而 /tmp 是 tmpfs，吃 RAM）。
#
# 与 A26（$STATE_DIR/offloadsig.cur.* 回收）同构但**不复用其代码**：那边按时间判死，
# 这边按 PID 判活（快照文件名自带 PID，kill -0 是唯一可靠的活体判据）。
# 红线：只用设备实测存在的 applet（白名单见 test/fixtures/device_applets.txt）—— 不用校验和、
# 行拼接、八进制/十六进制转储这类设备上没有的命令。
#
# 四道保护（review2 L3/L4 修正：旧注释号称「两条安全阀」，其中「kill 不可用」一条
# 在 dash 下是恒假的空话 —— kill 是内建命令，PATH 里删不掉，只能被同名函数覆盖；
# 该分支永远走不到，等于没有。第 4 轮又拆掉两条（A40/A41），现在在挡事的是这四道）：
#   ① 白名单：当前进程自己的快照（$PC_UCI_SNAP）与派生缓存目录（$PC_CL_DIR）无条件保留；
#   ② kill -0：探针说活就不删 —— 判不了活一律当活的（回退「不删」而非「全删」）；
#   ③ 非 root 整体退化为空操作：非 root 对别人的进程 `kill -0` 返回 EPERM，②会被骗过，
#      所以非 root 环境下一份也不删（A41，第 4 轮 / review27 I5）；
#   ④ 名字过滤：非 `<数字>` / `<数字>.d` 的代际名一律不碰。
# 这四道都在「PID 已死」之外额外保护一层：宁可漏删一份，也不能删掉正在用的那份。
# A40（第 4 轮 / review27 Low-1）：原位还有一条 `[ "$_p" = "$$" ] && continue`，
# 已删除 —— 自己进程的 PID 自然活着，`kill -0 $$` 恒成功，② 已经把它挡住了（死代码）。
pc_uci_snap_gc() {
	# A41（第 4 轮 / review27 I5）：只有 root 才能对**别人的**进程 `kill -0` —— 非 root 打别人
	# 的 PID 返回 EPERM，被当作「已死」⇒ 逐代回收会把**活着**的快照当成死的一起删掉。
	# 本函数在普通用户环境（开发机 / CI / 容器）里整体退化为空操作，回退方向永远是「宁可漏删」。
	[ "$(id -u)" = 0 ] || return 0
	local _g _b _p
	for _g in "${TMPDIR:-/tmp}"/parentcontrol-uci.*; do
		[ -e "$_g" ] || continue
		# 只认 `parentcontrol-uci.<数字>` 与 `parentcontrol-uci.<数字>.d` 两种代际名，
		# 其它名字（含 PC_UCI_SNAP_FILE 指向的自定义路径）一律不碰。
		_b=${_g##*/parentcontrol-uci.}
		_p=${_b%%.d}
		case $_p in
			'' | *[!0-9]*) continue ;;
		esac
		[ -n "$PC_UCI_SNAP" ] && [ "$_g" = "$PC_UCI_SNAP" ] && continue
		[ -n "$PC_CL_DIR" ] && [ "$_g" = "$PC_CL_DIR" ] && continue
		kill -0 "$_p" 2>/dev/null && continue
		rm -rf "$_g" 2>/dev/null
	done
	return 0
}

# 写包装（A70-2）：写 uci 之后立刻失效快照 —— 冷路径下快照通常没开，drop 是空操作。
pc_uset() { uci -q set "$@"; pc_uci_snap_drop; }
pc_udelete() { uci -q delete "$@"; pc_uci_snap_drop; }

# 取 parentcontrol.<$1> 的值。$1 形如 @weburl[0].mac / @basic[0].enabled / ai / ai.endpoint。
# 快照可用 → 从快照解析，语义与 uci -q get 一致（先按**字面键**；未命中且形如「@类型[位次]」
# 时，按 pc_uci_scan 的同一编号逻辑把位次解析成节名 —— 命名节在 @类型[N] 下标空间里同样占位）。
# 快照不可用 → 保持原样直连 `uci -q get`。
pc_uget() {
	# A74：判据必须与 begin 一致（LIT 非空）⇒ 空/半截快照文件下与 pc_uci_scan 同源回落直连。
	if [ -n "$PC_UCI_SNAP" ] && [ -r "$PC_UCI_SNAP" ] && [ -n "$PC_UCI_SNAP_LIT" ]; then
		local _q _t _n _o _r
		_q=$1
		# A98-2/D48：本键的值是多行（快照 LIT 只留了首行）⇒ 直连取全值（按代缓存）。
		case "$PC_UCI_SNAP_TRUNC" in
		*"$_PC_SNAP_NL$_q$_PC_SNAP_NL"*) _pc_uget_direct "$_q"; return 0 ;;
		esac
		_r=${PC_UCI_SNAP_LIT#*"$_PC_SNAP_NL$_q$_PC_SNAP_TAB"}
		if [ "$_r" != "$PC_UCI_SNAP_LIT" ]; then printf '%s\n' "${_r%%"$_PC_SNAP_NL"*}"; return 0; fi
		case "$_q" in "@"*"["*"]"*) ;; *) return 0 ;; esac
		_t=${_q#@}; _t=${_t%%"["*}
		_r=${_q#*"["}; _n=${_r%%"]"*}; _o=${_r#*"]"}
		case "$_n" in ''|*[!0-9]*) return 0 ;; esac
		[ -n "$_t" ] || return 0
		_r=${PC_UCI_SNAP_IDX#*"$_PC_SNAP_NL@$_t[$_n]$_PC_SNAP_TAB"}
		[ "$_r" = "$PC_UCI_SNAP_IDX" ] && return 0
		_r=${_r%%"$_PC_SNAP_NL"*}$_o
		_r=${PC_UCI_SNAP_LIT#*"$_PC_SNAP_NL$_r$_PC_SNAP_TAB"}
		[ "$_r" = "$PC_UCI_SNAP_LIT" ] && return 0
		printf '%s\n' "${_r%%"$_PC_SNAP_NL"*}"
		return 0
	fi
	uci -q get "$PC_CONF.$1"
}

# A98-3/D48（§11.22.2）：多行值在行导向快照下只剩首行 ⇒ 构建期已把这类键记进 TRUNC 段；
# 命中即直连取全值，并按快照代缓存（同一代内同键只直连一次）。空值也落盘（cat 得空）
# ⇒「值确实为空」在代内同样只 fork 一次。$1=相对键（不含 $PC_CONF.）。
_pc_uget_direct() {
	# A113（design §11.25.2 / F-2，Major）：缓存键用**单射转义**，不再用校验和命令。
	#   第 11l 轮真机发现目标设备没有该校验和命令（F-2）：旧实现把它拼进缓存键，设备上返
	#   回空 ⇒ 键退化成 `<净化键>.`
	#   `_c` 为空 ⇒ 键退化成 `<净化键>.` ⇒ A106 修掉的「不同键压成同名、同代内读到别人
	#   的缓存值」原地复发，且每 tick 多 6–11 行 not-found 噪音。
	#   转义表（在闭域 [-A-Za-z0-9_@.[]] 上单射）：_ → __ ；@ → _a ；[ → _b ；] → _c。
	#   `_` 先被转义 ⇒ 所有转义码都以 `_` 开头且前缀无关 ⇒ 不同原键必得不同文件名。
	#   闭域外的键（含 `/` 等会变成路径分隔符的字符）⇒ 直读、不写不读缓存：宁可多 fork
	#   一次，也不把缓存文件写到 $PC_CL_DIR 之外。
	local _f
	[ -n "$PC_CL_DIR" ] || { uci -q get "$PC_CONF.$1"; return 0; }
	case "$1" in
		""|*[!]A-Za-z0-9_@.[-]*) uci -q get "$PC_CONF.$1"; return 0 ;;
	esac
	_f=$PC_CL_DIR/$(printf '%s' "$1" | sed 's/_/__/g; s/@/_a/g; s/\[/_b/g; s/\]/_c/g')
	if [ ! -f "$_f" ]; then
		mkdir -p "$PC_CL_DIR" 2>/dev/null
		( umask 077; uci -q get "$PC_CONF.$1" > "$_f" 2>/dev/null )
	fi
	cat "$_f" 2>/dev/null
}

# 把 uci show 规范化成 `类型|下标|字段|值` 流（节行输出 `类型|下标||类型`）。
#
# 为什么需要它：条目可以是匿名节（uci show 输出 `parentcontrol.@weburl[3]=weburl`）或命名节
# （输出 `parentcontrol.kids=weburl`）。真机实测：**命名节在 @weburl[N] 下标空间里同样占位**
# ——「匿名 / kids / 匿名」三节依次可用 @weburl[0] / [1] / [2] 取到；但 uci show 对命名节只打印
# 它的名字。所以必须自己编号，否则该条目会被整条链路静默跳过：不下规则、不计数、不执行配额，
# 且不报任何错（F5）。
#
# 下标口径：匿名节用 uci 自己打印的位置下标（权威）；命名节用「已见同类型节数」补位。
# 兼容老行为：匿名节的选项行即使没有对应节行，也能凭地址取到下标。
pc_uci_scan() {
	_pc_snap_src | awk -F= -v c="$PC_CONF" '
		{
			k = $1
			if (index(k, c ".") != 1) next
			k = substr(k, length(c) + 2)
			if (k == "") next
			v = $2
			gsub(/\047/, "", v)
			gsub(/"/, "", v)
			is_sec = 0
			if (index(k, "@") == 1) {              # 匿名节地址 @type[N][.opt]
				p = index(k, "]")
				if (p == 0) next
				addr = substr(k, 1, p)
				opt = ""
				if (p < length(k)) {
					if (substr(k, p + 1, 1) != ".") next
					opt = substr(k, p + 2)
				}
				typ = substr(addr, 2, index(addr, "[") - 2)
				idx = substr(addr, index(addr, "[") + 1)
				sub(/\]$/, "", idx)
				if (opt == "") is_sec = 1
			} else {                                # 命名节 addr[.opt]
				q = index(k, ".")
				addr = (q == 0) ? k : substr(k, 1, q - 1)
				opt = (q == 0) ? "" : substr(k, q + 1)
				if (opt == "") {
					is_sec = 1
					typ = v
					idx = cnt[typ] + 0
				} else {
					typ = name2typ[addr]
					idx = idx_of[addr]
				}
			}
			if (typ == "") next
			if (is_sec) {
				cnt[typ]++
				if (index(k, "@") != 1) { name2typ[addr] = typ; idx_of[addr] = idx }
			}
			print typ "|" idx "|" opt "|" v
		}'
}

# 某模块全部 section 下标（不论是否勾选）
pc_ids_all() { pc_uci_scan | awk -F'|' -v t="$1" '$1 == t { print $2 }' | sort -un; }

# 某模块已勾选 enable='1' 的 section 下标（匿名/命名节等价）
pc_ids_on() { pc_uci_scan | awk -F'|' -v t="$1" '$1 == t && $3 == "enable" && $4 == "1" { print $2 }' | sort -un; }

# 某模块所有节的某字段取值（匿名/命名节等价），去重。用于收集 mac / ip。
pc_opts_all() { # $1=模块 $2=字段
	pc_uci_scan | awk -F'|' -v t="$1" -v o="$2" '$1 == t && $3 == o && $4 != "" { print $4 }' | sort -u
}

# ---------- 设备清单 clients（第 11k 轮 A87/A88）----------
# clients 值为纯文本：一行一台设备，`<MAC>|<IP>`，两侧皆可空（A87-1）。
# 解析只此一处（shell 侧），Lua 侧镜像见 ui.client_rows（A88）。

# 原始 clients 文本；缺失时由老 mac/ip 合成 `mac|ip`（A87-2 双源兼容）
pc_clients_raw() { # $1=模块 $2=下标
	local _c _m _i
	# A87-1：clients 是一行一台设备的纯文本。多行值的快照截断由 pc_uget 统一承担
	# （A98-4/D48，§11.22）：构建期 TRUNC 标记 + 取值期直连缓存。这里不再自带启发式 ——
	# 11k 的「快照值以单引号开头」判据对「多行值首行恰以引号结尾」会漏判并返回被污染的值。
	_c=$(pc_uget "@$1[$2].clients")
	[ -n "$_c" ] && { printf '%s\n' "$_c"; return 0; }
	# A87-2：clients 空 ⇒ 由老 mac/ip 合成 `mac|ip`（双源兼容）
	_m=$(pc_uget "@$1[$2].mac")
	_i=$(pc_uget "@$1[$2].ip")
	[ -z "$_m$_i" ] && return 0
	printf '%s|%s\n' "$_m" "$_i"
}

# 规范化：split \r\n/\n → 去首尾空白 → 跳过空行 → 按首个 | 切分 → 两侧去空白 →
#           两侧皆空丢弃 → MAC 小写比较 → (mac,ip) 完全相同去重（保序）。
# 输出每行 `mac|ip`（IP 为空时省略 `|`；MAC 为空时保留前导 `|`）。
pc_clients_rows() { # $1=模块 $2=下标
	pc_clients_raw "$1" "$2" | awk '
		{
			line = $0
			sub(/\r$/, "", line)
			gsub(/^[ \t]+|[ \t]+$/, "", line)
			if (line == "") next
			p = index(line, "|")
			if (p > 0) { m = substr(line, 1, p - 1); ip = substr(line, p + 1) }
			else       { m = line; ip = "" }
			gsub(/^[ \t]+|[ \t]+$/, "", m)
			gsub(/^[ \t]+|[ \t]+$/, "", ip)
			if (m == "" && ip == "") next
			ml = tolower(m)
			key = ml "|" ip
			if (seen[key]++) next
			if (ip == "") print ml; else print ml "|" ip
		}'
}

# 绑定 MAC 集合（小写、去重、保序）
pc_clients_macs() { # $1=模块 $2=下标
	pc_clients_rows "$1" "$2" | awk -F'|' '$1 != "" && !seen[$1]++ { print $1 }'
}

# A111（design §11.25.2 / F-3，High）：把若干行拼成一行、以 `, ` 连接。
#   空输入 ⇒ **输出 0 字节**（不是空行、不是空字符串行）；末尾不补分隔符。
#   全仓唯一实现 —— stats 的 entry 行第 6 字段原先是借外部行拼接命令（`-sd,`）实现，
#   而目标设备没有该命令（F-3）：rc=127 ⇒ 该字段恒空 ⇒ tsv.lua 的 11 字段契约破缺 ⇒
#   统计页「设备」列整列空白（用户需求 R3 主功能失效）。故下沉到这里，只用 awk（设备必有）。
pc_join_comma() {
	awk 'NF { if (n++) printf ", "; printf "%s", $0 }'
}

# 绑定 IP 集合（去重、保序）
pc_clients_ips() { # $1=模块 $2=下标
	pc_clients_rows "$1" "$2" | awk -F'|' '$2 != "" && !seen[$2]++ { print $2 }'
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
# 这是 shell 侧唯一的「谁受额度限制」判定口径：build_quota_blocks / pool_usage / stats_tsv 都读它
# （ui.lua 渲染列表时因不能调 shell 而有一份镜像，改这里要同步改它）。
pc_entry_unlimited() { # $1=module $2=idx $3=school|holiday
	local _v _q
	_v=$(pc_uget "@$1[$2].$(pc_suffix "$3")_unlimited")
	[ "$_v" = "1" ] && { echo 1; return 0; }
	[ -n "$_v" ] && { echo 0; return 0; }          # 显式写了 0 → 按有限额处理
	# _unlimited 没设：看额度/共享池来决定。凡是「没有任何额度来源」都算不限（fail-open）——
	# 否则“新条目还没配额度”“老配置漏了额度”“挂了池但池没额度”都会被静默当成 0 分钟 = 全天全禁。
	_q=$(pc_uget "@$1[$2].$(pc_suffix "$3")_quota")
	[ -n "$_q" ] && { echo 0; return 0; }
	# 没填自己的额度：挂了池且池确实有额度 → 限制由池负责，算“有限额”
	# 「池是否提供额度」只有一份判据（见 pc_pool_provided_quota）
	[ -n "$(pc_pool_provided_quota "$1" "$2" "$3")" ] && { echo 0; return 0; }
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

# 该条目今天从共享池拿到的额度（空 = 池没提供额度）。
# 「池是否提供额度」这个判据 shell 侧只此一处（ui.lua 有镜像）—— pc_entry_unlimited / entry_effective /
# pc_effective_quota 都读它，别再各自内联 `pc_pool_quota && [ -n ... ]`。
pc_pool_provided_quota() { # $1=module $2=idx $3=school|holiday
	local _p
	_p=$(pc_entry_pool "$1" "$2" "$3")
	[ -n "$_p" ] && pc_pool_quota "$_p" "$3"
}

# 条目今天「生效的原始额度」——shell 侧的池优先取值只此一份：池提供了额度 → 用池的额度，
# 否则用条目自己的。只输出额度值本身（不夹带池名，避免空格分隔的隐式协议）。
# 空 = 没有额度来源，它代表"不限"还是"全禁"由调用方按语义决定。
# 注意：ui.lua 渲染列表时需要同一份判定，但 Lua 不能调 shell 函数，那边有一份**镜像**
# （luasrc/model/cbi/parentcontrol/ui.lua 的 qmin/pool_quota）—— 改这里必须同步改它。
pc_effective_quota() { # $1=module $2=idx $3=school|holiday
	local _pq
	_pq=$(pc_pool_provided_quota "$1" "$2" "$3")
	if [ -n "$_pq" ]; then
		echo "$_pq"
	else
		pc_entry_quota "$1" "$2" "$3"
	fi
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

# 局域网 on-link IPv6 前缀（一行一个 "<prefix>/<len>"，F3）。
# 数据源只能是内核路由表：v6 的 GUA 是 ISP 动态委派（UCI 里根本没有）、ULA 在 UCI 里
# 是 /48 聚合（比 br-lan 实际的 /64 宽，拿去放行会比 v4 还宽）—— F3 ADR-2。
# 只取「直连（on-link）」路由：直连 = 「这个网段就在这块网卡上」，正是「家里」的定义。
# loopback 节产出为空是正确结果：其路由行首全是 unreachable；::1 不出主机栈、不经过
# PREROUTING，无需 v4 127.0.0.0/8 那样的机械移植（F3 ADR-6）。
pc_lan_nets6() {
	local _s _dev _pfx _rest
	uci -q show network 2>/dev/null \
		| sed -n "s/^network\.\([A-Za-z0-9_-]*\)\.proto='static'$/\1/p" \
		| while read -r _s; do
			_dev=$(uci -q get "network.$_s.device")
			[ -n "$_dev" ] || _dev=$(uci -q get "network.$_s.ifname")
			[ -n "$_dev" ] || continue
			ip -6 route show dev "$_dev" 2>/dev/null
		done \
		| while read -r _pfx _rest; do
			# 带 " via " 的转发路由不是直连（哪怕行首是合法前缀——如下游路由器经
			# br-lan 通告的 "<prefix> via fe80::1 dev br-lan"），必须排除，否则
			# 会把别家的网段也当「家里」放行（F3 词表/ADR-3）。
			#（read 吃掉了第 1 个字段后的分隔空格，所以行首就是 via 本身）
			case "$_rest" in "via "*|*" via "*) continue ;; esac
			# 零长前缀（::/0、0:0:…:0/0 等）必须排除：进链会生成 "-d ::/0 -j RETURN"
			# = 放行一切，IPv6 封锁静默失效。行首白名单挡不住数字形式的全零前缀
			#（它完全匹配上面的格式），故在此单独拒掉一切以 "/0" 结尾的字段
			#（F3 阶段 5 SF-1 / ADR-3 增补）。
			case "$_pfx" in */0) continue ;; esac
			printf '%s\n' "$_pfx"
		done \
		| grep -E '^([0-9A-Fa-f]*:)+[0-9A-Fa-f:]*/[0-9]+$' \
		| sort -u
}

# shell 侧唯一的额度归一器（ui.lua 有一份必须同步的镜像 qmin）：非纯数字（空/"abc"/"-1"/"+5"/" 5"/"00"）一律归 0，纯数字原样输出。
# 这是老版本（c4fe179..a1ae0e9）就在用的口径，迁移端也读它 —— 迁移与运行必须用
# 同一套解析，否则同一个脏值会在两边得出不同结论（B1′/S1′ 的教训）。
# 注意新语义：0 = 一分钟都不给；「到底受不受额度限制」由 pc_entry_unlimited 决定。
pc_quota_positive() {
	case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac
}

# ============================================================================
# apps 行解析（第 8 轮 D14/ADR-018）：apps 是「封锁名称行表」的唯一数据源，
# 每行 = `名称|域名列表`（名称不得含 | 与换行；域名列表可用逗号/空格/换行分隔）。
# 解析只此一份：init.d 的 entry_domains 与下面的迁移共用，别处不得再写第二份拆分。
# 输出：逐行 `名称<TAB>域名列表`；`|` 缺失的行按「纯名称」处理（域名列表为空）；空行跳过。
# ============================================================================
pc_apps_rows() { # $1=apps 多行文本
	printf '%s\n' "$1" | awk -F'|' '
		{
			name = $1
			gsub(/[\r\t\n]/, " ", name); gsub(/ +/, " ", name)
			sub(/^ /, "", name); sub(/ $/, "", name)
			d = ""
			for (i = 2; i <= NF; i++) d = (d == "") ? $i : d "|" $i
			gsub(/[\r\t\n]/, " ", d); gsub(/,/, " ", d)
			gsub(/ +/, " ", d); sub(/^ /, "", d); sub(/ $/, "", d)
			# A30/D23：丢弃条件 = 名称与域名**都**空（与 pc-ui.js 的 sync() 同口径）。
			# `|a.com`（名称空、域名非空）是**有效行**：名称空时用域名列表首项兜底显示名，
			# 该行域名照常进入封锁目标/解析（不得静默丢弃）。
			if (name == "" && d == "") next
			if (name == "") { n = d; sub(/[ |].*$/, "", n); name = n }
			print name "\t" d
		}'
}

# ============================================================================
# 配置迁移（安装/升级时调用一次，幂等）：
#   1) 补 basic 默认值；2) 老 word(关键词) → domains；3) 统一为「可用时段 + 额度」模型
# 只改 uci，不 commit（由调用方决定）。
# ============================================================================
pc_migrate_config() {
	local _k _i _m _w _d _f _has_sd _has_hd _sfx _md _ws _we _on _had_dual _unl _dt _eq _a _r _out _n _ai_ep _ai_md _ai_key _ai_v _ai_del _ai_secs _cl_m _cl_ip _cl_c
	# 0) 迁移会删老字段、并可能改变封锁行为，不可逆 —— 先留一份带时间戳的备份。
	#    （README 里承诺了这件事，就必须真的做；$PC_CONF_DIR 下没有配置文件时自动跳过。
	#      PC_CONF_DIR / BACKUP_DIR 是可覆盖钩子（默认值 = 生产路径），供白盒测试把
	#      备份分支指到临时目录。）
	if [ -f "$PC_CONF_DIR/$PC_CONF" ]; then
		mkdir -p "$BACKUP_DIR" 2>/dev/null
		cp -a "$PC_CONF_DIR/$PC_CONF" "$BACKUP_DIR/$PC_CONF.$(date +%Y%m%d%H%M%S).bak" 2>/dev/null
	fi
	# 1) 默认值
	for _k in usage_keep usage_min_kb; do
		[ -n "$(pc_uget "@basic[0].$_k")" ] && continue
		case "$_k" in
		usage_keep)                 pc_uset "$PC_CONF.@basic[0].$_k=90" ;;
		usage_min_kb)               pc_uset "$PC_CONF.@basic[0].$_k=8" ;;
		esac
	done

	# 2) 老配置里只填了 word 的，搬到 domains（否则升级后匹配串为空，静默失效）
	for _i in $(pc_ids_all weburl); do
		_w=$(pc_uget "@weburl[$_i].word")
		_d=$(pc_uget "@weburl[$_i].domains")
		if [ -n "$_w" ] && [ -z "$_d" ]; then
			pc_uset "$PC_CONF.@weburl[$_i].domains=$_w"
		fi
		# 老 word 一律删除：否则改了域名后，旧关键词仍会生成幽灵匹配规则
		[ -n "$_w" ] && pc_udelete "$PC_CONF.@weburl[$_i].word"
	done

	# 2b) apps 归一化（第 8 轮 D14/ADR-018）：apps 成为「封锁名称行表」的唯一数据源，
	#     一行 = 一台设备 + N 行 `名称|域名列表`。四种形态：
	#       ① R6 形态（有 remarks/domains、无 apps）→ 一行 apps（名称 = remarks，空则首域名），
	#          域名 = 原 domains 内容，随后**删除 domains**（防双源幽灵匹配，与 word 同理）
	#       ② ≤1.8.2 老 apps（纯名称、整个值不含 `|`）→ 每个名称一行，域名 = 该条目原 domains
	#       ③ 已是新形态（apps 含 `|`）→ 一个字段都不动（幂等）
	#       ④ 都没有 → 不动
	#     写进 apps 的域名列表必须是**单行**（换行在 apps 里是行分隔符，会把域名变成幽灵名称行），
	#     所以先把 domains 的逗号/换行压成空格再拼。
	for _i in $(pc_ids_all weburl); do
		_a=$(pc_uget "@weburl[$_i].apps")
		case "$_a" in *\|*) continue ;; esac
		_d=$(pc_uget "@weburl[$_i].domains")
		_d=$(printf '%s' "$_d" | tr ',\r\n' '   ' | awk '{ $1 = $1; print }')
		_r=$(pc_uget "@weburl[$_i].remarks")
		_r=$(printf '%s' "$_r" | tr '|\r\n\t' '    ' | awk '{ $1 = $1; print }')
		if [ -n "$_a" ]; then
			# ② 老 apps：纯名称列表（换行/逗号/空格分隔）→ 每名称一行，域名取该条目 domains 并集
			_out=""
			for _n in $(printf '%s' "$_a" | tr ',\r\n' '   '); do
				_out="${_out}${_n}|${_d}
"
			done
			[ -n "$_out" ] || continue
			pc_uset "$PC_CONF.@weburl[$_i].apps=$_out"
		elif [ -n "$_d" ]; then
			# ① R6 形态：名称为空时用首个域名兜底
			[ -n "$_r" ] || { set -- $_d; _r=$1; }
			pc_uset "$PC_CONF.@weburl[$_i].apps=${_r}|${_d}"
		else
			continue
		fi
		pc_udelete "$PC_CONF.@weburl[$_i].domains"
		_pclog "migrate: weburl[$_i] apps 归一化（domains 已并入 apps 行并删除）"
	done

	# 2c) AI 段身份统一为命名节 `ai`（第 9 轮 A29/D21 修订，取代第 8 轮的「盲保下标 0」）：
	#     目标：最多 1 个 ai 段，段名 == ai（命名节），且用户既有值**不丢**。
	#     算法对「@ai[N] 下标是否计入命名节」这一未证实语义**不敏感**（本机无 uci/Lua，
	#     真机语义未证实；`pc_ids_all` 的下标在命名节与匿名节混排时可能撞号，故不能用它判数量）：
	#       * 段数用 `pc_uci_scan` 的**节行**直接计数（不依赖下标语义）。
	#       * 段数 0 → 不动（不凭空造段，交给安装自愈 / 设置页 0 段自愈；沿用第 8 轮 W95⑧）。
	#       * 段数 1 且为命名节 ai → 已收敛，**一个字节都不改**（保证 `uci show` 逐字节幂等）。
	#       * 否则按下述语义无关算法收敛：
	#         ① 先按命名节读三字段（`parentcontrol.ai.<opt>`，无歧义）；
	#         ⑥ 再把各 ai 段的非空值按序并入（仅补命名节里为空的字段）—— 老匿名值不丢，
	#            命名节已有的值优先；只补空位 ⇒ @ai[N] 语义无论是否计入命名节都无害；
	#         ② 删除命名节 `parentcontrol.ai`（按名删，与下标语义无关）；
	#         ③ 此时剩余 ai 段必定全是匿名节（下标空间无歧义）⇒ `pc_ids_all ai` 取下标、
	#            **倒序**全部删除（每删一个后 @ai[N] 下标会前移，故倒序），逐个留 _pclog；
	#         ④ `uci -q set parentcontrol.ai=ai` 重建命名节，再把①/⑥拿到的非空字段写回。
	_ai_secs=$(pc_uci_scan | awk -F'|' -v t="ai" '$1 == t && $3 == "" { n++ } END { print n + 0 }')
	if [ "$_ai_secs" = "0" ]; then
		: # 无 ai 段：交给安装自愈 / 设置页自愈
	elif [ "$_ai_secs" = "1" ] && [ "$(pc_uget ai)" = "ai" ]; then
		: # 已收敛：唯一 ai 段且为命名节
	else
		_ai_ep=$(pc_uget "ai.endpoint")
		_ai_md=$(pc_uget "ai.model")
		_ai_key=$(pc_uget "ai.apikey")
		for _i in $(pc_ids_all ai); do
			_ai_v=$(pc_uget "@ai[$_i].endpoint")
			[ -z "$_ai_ep" ] && [ -n "$_ai_v" ] && _ai_ep="$_ai_v"
			_ai_v=$(pc_uget "@ai[$_i].model")
			[ -z "$_ai_md" ] && [ -n "$_ai_v" ] && _ai_md="$_ai_v"
			_ai_v=$(pc_uget "@ai[$_i].apikey")
			[ -z "$_ai_key" ] && [ -n "$_ai_v" ] && _ai_key="$_ai_v"
		done
		# 类型守卫：按名删节前先确认该节确实是 ai 类型 —— 模板里若恰好有「异类型但名为 ai」
		# 的节（如 config weburl 'ai'），直接 uci -q delete 会误删。命名节不存在时
		# pc_uget ai 为空 ⇒ 本就不需要删，跳过即可。
		if [ "$(pc_uget ai)" = "ai" ]; then pc_udelete "$PC_CONF.ai"; fi
		_ai_del=""
		for _i in $(pc_ids_all ai); do
			_ai_del="$_i $_ai_del"
		done
		for _i in $_ai_del; do
			pc_udelete "$PC_CONF.@ai[$_i]"
			_pclog "migrate: 删除匿名 config ai 段（@ai[$_i]）—— AI 段身份统一为命名节 ai"
		done
		pc_uset "$PC_CONF.ai=ai"
		[ -n "$_ai_ep" ]  && pc_uset "$PC_CONF.ai.endpoint=$_ai_ep"
		[ -n "$_ai_md" ]  && pc_uset "$PC_CONF.ai.model=$_ai_md"
		[ -n "$_ai_key" ] && pc_uset "$PC_CONF.ai.apikey=$_ai_key"
	fi

	# 2d) clients 归一化（第 11k 轮 A87/A92）：老 mac/ip 单值 → clients 一行。
	#     目标格式见 A87-1（一行一台设备，`<MAC>|<IP>`，两侧皆可空）。
	#       * mac/ip 皆空 → 一个字节都不动（幂等）
	#       * clients 非空 → 只删老字段（双源防幽灵，不覆盖用户已填的表）
	#       * 否则 → 把 `mac|ip` 写进 clients 后再删老字段
	for _m in $PC_MODULES; do
		for _i in $(pc_ids_all "$_m"); do
			_cl_m=$(pc_uget "@$_m[$_i].mac")
			_cl_ip=$(pc_uget "@$_m[$_i].ip")
			[ -z "$_cl_m$_cl_ip" ] && continue
			_cl_c=$(pc_uget "@$_m[$_i].clients")
			if [ -z "$_cl_c" ]; then
				pc_uset "$PC_CONF.@$_m[$_i].clients=${_cl_m}|${_cl_ip}"
				_pclog "migrate: $_m[$_i] mac/ip → clients 一行"
			fi
			pc_udelete "$PC_CONF.@$_m[$_i].mac"
			pc_udelete "$PC_CONF.@$_m[$_i].ip"
		done
	done

	# 3) 统一为「可用时段 + 额度」模型。老配置有两代：
	#      a) 双档案时代：<sfx>_mode ∈ off|time|quota|block（另有 <sfx>_start/<sfx>_end）
	#      b) 更早的「按星期」时代：week + timestart/timeend（由 week 决定哪个档案生效）
	#    映射（既定方案）：
	#      time  → 不限额度 + 09:00-21:00（老语义是"封某一段"，新模型只有"可用时段"，
	#              无法无损换算；给 WhatsApp 工作时段、并在日志里留痕）
	#      quota → 额度字段**原样保留**（不动它本身、也不额外加时段：老 quota 本来全天
	#              24h 可用，加 09:00-21:00 会把存量用户静默收紧成每天 12 小时）。
	#              但「不限额度」开关必须按老判据重写：老运行时是「归一后有效额度 > 0 才算
	#              有限额」，所以有效额度 ≤ 0（空/0/负数/非数字）一律**强制**写成 unlimited=1
	#      block → 额度 0（0 = 一分钟都不给）
	#      off   → 不限额度（不写时段 = 全天可用）
	#      week  → 该档案在老模型里生效 = 当年有时段限制 → 不限额度 + 09:00-21:00
	#              没生效 → 不限额度（不写时段）
	#    幂等的关键：**已是新模型的条目一个字段都不动**（见 _had_dual 判定）；只有还带着
	#    老 mode（或处在「按星期」时代）的条目才被翻译，而这一类必须**强制写** —— 否则
	#    老配置里那个无意义的 unlimited=0 会把「不限」翻译成新语义的全天全禁（B1″）。
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
					pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
					_ws=09:00:00; _we=21:00:00
					_pclog "migrate: $_m[$_i] ${_sfx}: 老「时段」→ 不限额度 + 09:00-21:00" ;;
				block)
					pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=0"
					pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_quota=0"
					_pclog "migrate: $_m[$_i] ${_sfx}: 老「全天禁止」→ 额度 0" ;;
				quota)
					# 依据：额度模型是 8ab43a2 引入的，**从那一刻到 a0c7936 之前的每一个版本**，
					# 运行时判据都是「归一后的有效额度 > 0 才算有限额」（build_quota_blocks 里那句
					# `[ "$1" -gt 0 ] || continue`）。所以在这段历史里额度为空/0/负数/非数字
					# **都是"不限"**。这里把"老=不限"显式写成 unlimited=1。
					# （注意：更早的版本根本没有额度/unlimited 模型，所以不要说"一直如此"。）
					#
					# 已知的不可判别之处（不要再试图用标记去猜）：我的中间开发版 a0c7936 曾短暂把
					# 「额度 0/空」定义成"全天禁止"，那种配置与老配置**形状完全一样**，没有任何字段
					# 能区分（试过用 week 当标记：无 week 会被误判成全禁、有 week 会被误判成不限，
					# 两个方向都是 bug，已放弃）。这里统一按**额度模型早期的老判据**解释：
					# 该判据从额度模型引入（8ab43a2）起一直沿用到 a0c7936 之前。受影响的只有
					# "用过那个中间开发版、并把额度填 0 表示全天禁止"的极窄情况，迁移会为这类
					# 条目打日志，README 也写明了怎么复核。
					# 注意 entry_effective 是池优先：判定必须跟着它走。
					_unl=0
					[ "$(pc_uget "@$_m[$_i].${_sfx}_unlimited")" = "1" ] && _unl=1
					if [ "$_unl" = 0 ]; then
						if [ "$_sfx" = "sd" ]; then _dt=school; else _dt=holiday; fi
						# 池优先的有效额度在 shell 侧只有一份实现（common.sh 的 pc_effective_quota，
						# ui.lua 有必须同步的镜像）
						_eq=$(pc_effective_quota "$_m" "$_i" "$_dt")
						if [ "$(pc_quota_positive "$_eq")" -gt 0 ] 2>/dev/null; then
							pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=0"
						else
							pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
							_pclog "migrate: $_m[$_i] ${_sfx}: 老额度非正/非法 → 不限（额度模型 8ab43a2 引入、a0c7936 之前的老判据）。若你本来要的是「全天禁止」，请在界面上把额度填 0 并取消勾选「不限额度」"
						fi
					fi ;;
				off)
					pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1" ;;
				'')
					# 只有真的处在「按星期」时代的老条目才推窗口；已经是新模型的条目
					# 完全不动（这样"只配了某一边档案"的条目不会被造出另一边）
					if [ "$_had_dual" = 0 ]; then
						if [ "$_sfx" = "sd" ]; then _on=$_has_sd; else _on=$_has_hd; fi
						pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_unlimited=1"
						if [ -n "$_w" ] && [ "$_on" = 1 ]; then
							_ws=09:00:00; _we=21:00:00
							_pclog "migrate: $_m[$_i] ${_sfx}: 老「按星期 + 时段」→ 不限额度 + 09:00-21:00"
						fi
					fi ;;
				esac
				# 只在确定存在"老时段限制"时才补窗口；其余一律不写时段（= 全天可用），
				# 避免把本来 24h 可用的条目静默收紧。这里只写 qstart/qend 这两个"新模式字段"，
				# 语义字段（unlimited/quota）一律由上面的分支按老判据（8ab43a2..a0c7936 之前）决定。
				if [ -n "$_ws" ]; then
					pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_qstart=$_ws"
					pc_uset "$PC_CONF.@$_m[$_i].${_sfx}_qend=$_we"
				fi
				pc_udelete "$PC_CONF.@$_m[$_i].${_sfx}_mode"
				pc_udelete "$PC_CONF.@$_m[$_i].${_sfx}_start"
				pc_udelete "$PC_CONF.@$_m[$_i].${_sfx}_end"
			done
			pc_udelete "$PC_CONF.@$_m[$_i].week"
			pc_udelete "$PC_CONF.@$_m[$_i].timestart"
			pc_udelete "$PC_CONF.@$_m[$_i].timeend"
		done
	done
}

# 迁移期的日志：uci-defaults 环境没有 elog（那是 init.d 的），这里自带兜底格式
_pclog() {
	mkdir -p /tmp/log 2>/dev/null
	echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "${LOG_FILE:-/tmp/log/parentcontrol.log}"
}

# ============================================================================
# HTTP 客户端探测（可选依赖：curl / uclient-fetch / wget；AI 辅助解析与节假日
# 下载共用，D9：全仓库唯一的 curl→uclient-fetch→wget 阶梯就在下面这一个函数里）。
#
# 只做运行时探测，不写进 LUCI_DEPENDS。约定：
#   * 成功 = HTTP 2xx，响应体写 <outfile>，返回 0；
#   * 失败 = 返回非 0，并把可读原因（≤2KB）写 <outfile>；
#   * 鉴权：若设置了 PC_AI_KEY_FILE，读其内容作为 Bearer token（不进命令行/ps）；
#   * 超时：PC_HTTP_TIMEOUT（秒，默认 15；兼容旧名 PC_AI_TIMEOUT）。
# 用法：pc_http <GET|POST> <url> <outfile> [infile|-] [header]...
#   * GET 忽略 infile（占位传 "-"）；POST 需要 infile，"-" 解释为 /dev/null 空请求体；
#   * 其余参数逐个作为附加请求头。
# ============================================================================

_pc_ai_key() {
	[ -n "$PC_AI_KEY_FILE" ] && [ -f "$PC_AI_KEY_FILE" ] && tr -d '\r\n' < "$PC_AI_KEY_FILE"
}

_pc_http_timeout() {
	# F-R2-1：匹配与回显必须用**同一个**取过默认值的变量 —— 曾经 case 匹配
	# ${PC_HTTP_TIMEOUT:-${PC_AI_TIMEOUT:-15}} 而 *) 分支回显未取默认的
	# $PC_HTTP_TIMEOUT 原变量，生产环境（两变量都未设）回显空串，
	# curl --max-time "" 秒挂，所有 pc_http 调用（AI + fetch_url）全灭。
	local _v
	_v="${PC_HTTP_TIMEOUT:-${PC_AI_TIMEOUT:-15}}"
	case "$_v" in
		''|*[!0-9]*) echo 15 ;;
		*) echo "$_v" ;;
	esac
}

# 把可读失败原因写进 outfile（截断到 2KB）并返回非 0。
_pc_ai_fail() {
	local _o
	_o="$1"; shift
	printf '%s\n' "$*" 2>/dev/null | head -c 2048 > "$_o"
	return 1
}

# D10/F-12：从客户端 stderr 与响应体开头嗅探 HTTP 4xx/5xx 状态。
# 背景：curl -f 自带可靠判定，但 busybox-wget / uclient-fetch（尤其老版本）在
# 4xx/5xx 上可能 exit 0 并把错误体写进 outfile —— 不嗅探就会把鉴权失败等
# HTTP 错误当成「成功响应」，页面只能报「响应不是 JSON」（原因失真，复审 F-12）。
# 命中返回可读原因（"HTTP <状态>" 或明示「无法判定」）；未命中输出空串。
# 真机上各客户端的确切报错形态由阶段 6 黑盒 B63 收口（design.md R11）；这里是唯一修点。
_pc_http_fail_status() { # <客户端名> <stderr文本> <outfile>
	local _cl _txt _hit
	_cl="$1"; _txt="$2"
	if [ -f "$3" ]; then
		_txt="$_txt
$(head -c 256 "$3" 2>/dev/null | tr '\r' '\n')"
	fi
	_txt=$(printf '%s' "$_txt" | tr '\r' '\n')
	# 只取状态码（"HTTP/1.1 401"）：不要在字符类里写 \n（POSIX 括号表达式里反斜杠不转义，
	# BSD grep 会把它当字面 backslash/n，GNU grep 才当换行 —— 两边行为不一致）。
	_hit=$(printf '%s\n' "$_txt" | grep -aoE 'HTTP/1\.[01][[:space:]]+[45][0-9][0-9]' | head -n 1)
	if [ -n "$_hit" ]; then
		printf 'HTTP %s' "$(printf '%s' "$_hit" | sed -E 's#^HTTP/1\.[01][[:space:]]+##')"
	elif printf '%s\n' "$_txt" | grep -aq 'server returned error'; then
		printf '%s' "HTTP 状态无法判定（客户端 $_cl）"
	fi
}

pc_http() { # <GET|POST> <url> <outfile> [infile|-] [header]...
	local _m _u _o _i _t _k _err _r _st _cl _h _n
	_m="$1"; _u="$2"; _o="$3"; _i=""
	if [ "$#" -ge 4 ]; then _i="$4"; shift 4; else shift 3; fi
	_t=$(_pc_http_timeout); _k=$(_pc_ai_key); _err="${_o}.err"
	# "$@" 此时 = 调用方附加请求头（每个一个参数，裸 "Name: value" 串）。鉴权头
	# （PC_AI_KEY_FILE 单点注入）与 POST 的 Content-Type 在这里前置补齐。
	if [ -n "$_k" ]; then set -- "Authorization: Bearer $_k" "$@"; fi
	if [ "$_m" = "POST" ]; then
		set -- "Content-Type: application/json" "$@"
		if [ -z "$_i" ] || [ "$_i" = "-" ]; then _i="/dev/null"; fi
		[ -f "$_i" ] || { _pc_ai_fail "$_o" "请求体临时文件不存在：$_i"; return 1; }
	fi
	if command -v curl >/dev/null 2>&1; then
		_cl="curl"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		_cl="uclient-fetch"
	elif command -v wget >/dev/null 2>&1; then
		_cl="wget"
	else
		_pc_ai_fail "$_o" "路由器缺少 HTTP 客户端，请安装 curl 或 uclient-fetch（访问 https 还需 libustream-ssl 与 ca-bundle）"
		return 1
	fi
	# F-R2-2：头串必须用客户端认的 flag 形态传 —— curl 用 `-H <h>`，uclient-fetch 与
	# busybox-wget 用 `--header=<h>`（长选项只认 = 形态）。绝不能把头串作裸位置参数
	# 传给客户端：那会落在 URL 位置，curl 把它当第二个 URL 且 exit 0 静默假成功，
	# Bearer/Content-Type 从未真正发出（复审实弹抓包复现过）。
	# 实现：for 词表在循环开始前展开完毕，循环内 set -- 只往尾部追加包装副本，
	# 最后把前段的裸头串 shift 掉 —— "$@" 就地变成包装后的 argv。
	_n=$#
	for _h in "$@"; do
		if [ "$_cl" = "curl" ]; then
			set -- "$@" "-H" "$_h"
		else
			set -- "$@" "--header=$_h"
		fi
	done
	shift "$_n"
	if [ "$_cl" = "curl" ]; then
		# curl -f：4xx/5xx 自带可靠失败判定（三客户端里唯一，见 D10）
		if [ "$_m" = "POST" ]; then
			curl -fsS --max-time "$_t" --data-binary "@$_i" "$@" "$_u" > "$_o" 2>"$_err"
		else
			curl -fsS --max-time "$_t" "$@" "$_u" > "$_o" 2>"$_err"
		fi
		if [ $? -eq 0 ]; then rm -f "$_err"; return 0; fi
		_r=$(head -c 1024 "$_err" 2>/dev/null | tr '\n' ' '); rm -f "$_err"
		_pc_ai_fail "$_o" "curl 请求失败：${_r:-HTTP 错误或网络不可达}"
	elif [ "$_cl" = "uclient-fetch" ]; then
		if [ "$_m" = "POST" ]; then
			uclient-fetch -q -T "$_t" -O "$_o" --post-file="$_i" "$@" "$_u" >/dev/null 2>"$_err"
		else
			uclient-fetch -q -T "$_t" -O "$_o" "$@" "$_u" >/dev/null 2>"$_err"
		fi
		if [ $? -eq 0 ]; then
			# D10：uclient-fetch 老版本可能 exit 0 + 4xx 错误体 —— 嗅探状态行，不得 fail-open
			_st=$(_pc_http_fail_status uclient-fetch "$(cat "$_err" 2>/dev/null)" "$_o")
			rm -f "$_err"
			[ -n "$_st" ] || return 0
			_pc_ai_fail "$_o" "uclient-fetch 请求失败：$_st"
			return 1
		fi
		_r=$(head -c 1024 "$_err" 2>/dev/null | tr '\n' ' '); rm -f "$_err"
		_pc_ai_fail "$_o" "uclient-fetch 请求失败：${_r:-HTTP 错误或网络不可达}"
	else # wget（_cl 探测已保证非 curl/uclient-fetch 必为 wget）
		if [ "$_m" = "POST" ]; then
			wget -q -T "$_t" -O "$_o" --post-file="$_i" "$@" "$_u" >/dev/null 2>"$_err"
		else
			wget -q -T "$_t" -O "$_o" "$@" "$_u" >/dev/null 2>"$_err"
		fi
		if [ $? -eq 0 ]; then
			# D10：wget 分支同上（busybox-wget 无 --fail，用等价状态行判定）
			_st=$(_pc_http_fail_status wget "$(cat "$_err" 2>/dev/null)" "$_o")
			rm -f "$_err"
			[ -n "$_st" ] || return 0
			_pc_ai_fail "$_o" "wget 请求失败：$_st"
			return 1
		fi
		_r=$(head -c 1024 "$_err" 2>/dev/null | tr '\n' ' '); rm -f "$_err"
		_pc_ai_fail "$_o" "wget 请求失败：${_r:-HTTP 错误或网络不可达}"
	fi
}
