#!/bin/sh
# init.d 白盒测试：用状态化假 iptables 跑真实 build_all / tick / 采样，
# 对生成的规则逐条断言。运行： sh test/init_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
t_setup

# ---------------- 配置构造 ----------------
write_basic() { # $1=enabled
	cat >> "$T_TMP/cfg.uci" <<EOF
config basic
	option enabled '$1'
	option algos 'kmp'
	option control_mode '${2:-0}'
	option ip_mask '${3:-24}'
	option ip_refresh '30'
	option usage_min_kb '32'
	option reset_school '12:00'
	option reset_holiday '12:00'
EOF
}
cfg_begin() { : > "$T_TMP/cfg.uci"; write_basic "${1:-1}" "${2:-0}" "${3:-24}"; }
cfg_section() { cat >> "$T_TMP/cfg.uci"; }
cfg_apply() { cfg_reset; cfg_load parentcontrol "$T_TMP/cfg.uci"; }
fresh() {
	rm -f "$FAKE_IPT_STATE_DIR"/v4.json "$FAKE_IPT_STATE_DIR"/v6.json
	rm -rf "$USAGE_DIR" "$STATE_DIR" "$IPDIR"
	mkdir -p "$USAGE_DIR" "$STATE_DIR" "$IPDIR"
}
flat() { tr '\n' ' ' | sed 's/ $//'; }
# 链里「无条件 DROP」条数 = 不带 -m time 的 DROP 规则（额度耗尽那种整条封）
uncond_drop() { ipt_rules "$1" "$2" "$3" | awk '/-j DROP/ && !/-m time/ {n++} END{print n+0}'; }
# 链里出现的「时段外区间」去重个数
win_ranges() { ipt_rules "$1" "$2" "$3" | grep -o -- '--timestart [0-9:]* --timestop [0-9:]*' | sort -u | wc -l | tr -d ' '; }

# 解析 fixture：example.com 与其 www 变体
put_resolve <<'EOF'
4 example.com 1.2.3.4
4 www.example.com 1.2.3.4
6 example.com 2402:4e00:1410::1
6 www.example.com 2402:4e00:1410::1
EOF
put_holiday 2026 '{"year":2026,"days":[{"name":"元旦","date":"2026-01-01","isOffDay":true}]}'
FAKE_DATE_YMD=2026-06-08   # 周一、无假日 → 平日
FAKE_DATE_DOW=1
FAKE_DATE_HM=13:00         # 已过 12:00 重置点

WEBURL_ENTRY='config weburl
	option enable '"'"'1'"'"'
	option mac '"'"'00:00:5e:00:53:01'"'"'
	option domains '"'"'example.com'"'"''    # shellcheck disable=SC2034

# ============================================================
echo '== 关闭开关 → 不建任何规则 =='
fresh
cfg_begin 0
cfg_apply
( start ) >/dev/null 2>&1 || true
t_eq '关闭时无 filter 链' '' "$(ipt_chains v4 filter | grep PARENTCONTROL || true)"
t_eq '关闭时无 mangle 链' '' "$(ipt_chains v4 mangle | grep PARENTCONTROL || true)"

# ============================================================
# 统一模型：每个档案 = 可用时段（默认全天）+ 额度（或勾「不限额度」）
#   封 = 不在可用时段内  或  额度耗尽
#   时段由内核 -m time 精确到秒执行；额度那份封禁由 tick 每分钟重建
echo '== 统一模型：可用时段 09:00-21:00 → 生成"时段外"规则（3 段）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
	option sd_qstart '09:00:00'
	option sd_qend '21:00:00'
EOF
cfg_apply
run_build
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA)
# 「时段外」= 本地 00:00:00-08:59:59（跨 UTC 零点 → 切 2 段）+ 21:00:01-23:59:59
# 一律正向区间：本机 iptables 明确拒绝「! -m time」（unexpected ! flag before --match）
t_has '本地 00:00-08:59:59 的前半段' "$(printf '%s' "$Q" | flat)" \
	'-m time --timestart 16:00:00 --timestop 23:59:59'
t_has '同一段跨 UTC 零点的后半段' "$(printf '%s' "$Q" | flat)" \
	'-m time --timestart 00:00:00 --timestop 00:59:59'
t_has '本地 21:00:01-23:59:59' "$(printf '%s' "$Q" | flat)" \
	'-m time --timestart 13:00:01 --timestop 15:59:59'
t_eq '时段外的区间恰好 3 段（去重）' 3 "$(win_ranges v4 mangle PARENTCONTROL_QUOTA)"
t_eq '未耗尽：没有任何无条件封' 0 "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)"
t_has '时段规则带设备条件（不是无差别封）' "$(printf '%s' "$Q" | flat)" '-m mac --mac-source 00:00:5e:00:53:01'

echo '== 统一模型：额度耗尽 → 整条无条件封（比时段更强，无需时间条件）=='
pc_usage_add weburl_0 30
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)
t_has '耗尽 → 无条件 DROP 目标 IP' "$Q" '-d 1.2.3.0/24 -j DROP'
t_has '耗尽 → DNS/SNI 串也封' "$Q" '--string example.com'
t_eq '耗尽 → 出现了无条件封' 1 "$([ "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)" -gt 0 ] && echo 1 || echo 0)"

echo '== 统一模型：勾「不限额度」→ 只看时段 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_unlimited '1'
	option sd_qstart '09:00:00'
	option sd_qend '21:00:00'
EOF
cfg_apply
run_build
pc_usage_add weburl_0 99999
build_quota_blocks
t_eq '不限额度 → 仍只有 3 段时段外区间' 3 "$(win_ranges v4 mangle PARENTCONTROL_QUOTA)"
t_eq '不限额度 → 额度再大也不封（无无条件封）' 0 "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)"
t_eq '不限额度但仍计数（统计/池要用）' ok "$(ipt_exists v4 mangle PCA_weburl_0 && echo ok)"

echo '== 可用时段=全天（默认）→ 不产生任何时段规则 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
	option sd_qstart '00:00:00'
	option sd_qend '23:59:59'
EOF
cfg_apply
run_build
t_eq '全天 + 未耗尽 → QUOTA 链全空' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
pc_usage_add weburl_0 30
build_quota_blocks
t_eq '全天 + 耗尽 → 所有 DROP 都是无条件的' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | grep -c -- '-j DROP')" "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)"
t_eq '全天 + 耗尽 → 不含 -m time' 0 "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | grep -c -- '-m time')"

echo '== 额度 0 = 全天禁止（不需要第三种模式：0 >= 0 恒成立）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '0'
	option sd_qstart '00:00:00'
	option sd_qend '23:59:59'
	option sd_unlimited '0'
EOF
cfg_apply
run_build
t_eq '额度 0 → 出现无条件封' ok "$([ "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)" -gt 0 ] && echo ok || echo no)"
t_has '额度 0 → 封的是该条目目标' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)" '-d 1.2.3.0/24 -j DROP'
t_eq '额度 0 + 时段全天 → 一条时段规则都没有（全靠额度 0 全封）' 0 "$(win_ranges v4 mangle PARENTCONTROL_QUOTA)"
t_eq '额度 0 → 仍照常计数（便于看板显示）' ok "$(ipt_exists v4 mangle PCA_weburl_0 && echo ok)"

echo '== 额度 0 + 勾了不限额度 → 反过来只判时段（复选框优先）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '0'
	option sd_qstart '09:00:00'
	option sd_qend '21:00:00'
	option sd_unlimited '1'
EOF
cfg_apply
run_build
t_eq '勾了不限 → 没有无条件封' 0 "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)"
t_eq '勾了不限 → 只剩时段外 3 段' 3 "$(win_ranges v4 mangle PARENTCONTROL_QUOTA)"

echo '== 完全不限制 = ☑不限额度 + 时段全天 → 只计数、不封锁 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_unlimited '1'
	option hd_unlimited '1'
	option sd_qstart '00:00:00'
	option sd_qend '23:59:59'
	option hd_qstart '00:00:00'
	option hd_qend '23:59:59'
EOF
cfg_apply
run_build
t_eq '完全不限制 → QUOTA 链空（不封锁）' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
t_eq '完全不限制 → 仍然计数（看板要看得到用量）' ok "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | grep -q PCA_weburl_0 && echo ok)"

echo '== 网址目标：计数链（IP + DNS/SNI 串）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
run_build
A4=$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)
t_has '计数规则跳 PCA_weburl_0' "$A4" '-m mac --mac-source 00:00:5e:00:53:01 -d 1.2.3.0/24 -j PCA_weburl_0'
t_has 'IPv6 计数规则' "$(ipt_rules v6 mangle PARENTCONTROL_ACCT | flat)" '-d 2402:4e00:1410:0::/64 -j PCA_weburl_0'
t_has 'DNS(53) 字符串命中也计入额度' "$A4" '-p UDP --dport 53 -m string --algo kmp --string example.com -j PCA_weburl_0'
t_has 'SNI(80,443) 字符串命中也计入额度' "$A4" '-p TCP -m multiport --dports 80,443 -m string --algo kmp --string example.com -j PCA_weburl_0'
t_eq '计数链同一目标只出一条（single 不双计）' 1 \
	"$(ipt_rules v4 mangle PARENTCONTROL_ACCT | grep -c -- '-d 1.2.3.0/24 -j PCA_weburl_0')"
t_eq 'PCA 空链已建' ok "$(ipt_exists v4 mangle PCA_weburl_0 && echo ok)"
t_eq 'PREROUTING 顺序 QUOTA→ACCT' \
	'PARENTCONTROL_QUOTA PARENTCONTROL_ACCT' \
	"$(ipt_jump v4 mangle PREROUTING | flat)"
t_eq '只挂这两条（老的 WEBURL/IP 链已废弃）' 2 "$(ipt_jump v4 mangle PREROUTING | wc -l | tr -d ' ')"

echo '== 协议条目：端口条件走进统一链 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config protocol
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option proto 'tcp'
	option portd '80,443'
	option sd_mode 'quota'
	option sd_quota '10'
EOF
cfg_section <<'EOF'
config protocol
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option proto 'udp'
	option portd '53'
	option sd_mode 'quota'
	option sd_quota '10'
EOF
cfg_apply
run_build
A=$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)
t_has '多端口用 multiport --dports' "$A" '-p tcp -m multiport --dports 80,443'
t_has '单端口用 --dport' "$A" '-p udp --dport 53'
t_eq '未耗尽 → QUOTA 空' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
pc_usage_add protocol_0 10
build_quota_blocks
t_has '该端口耗尽 → 封在 QUOTA 链' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)" '-p tcp -m multiport --dports 80,443'
t_eq '只封了 1 条（另一个端口不牵连）' 1 "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)"

echo '== 额度没填（未勾不限）→ 视为不限（fail-open，防静默全禁；全禁请显式填 0）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_qstart '00:00:00'
	option sd_qend '23:59:59'
EOF
cfg_apply
run_build
t_eq '没填额度 + 未勾不限 → 不封（fail-open）' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"

echo '== 额度没填 + 勾了不限 → 永不封（迁移会把这种老条目补成显式不限）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_unlimited '1'
EOF
cfg_apply
run_build
pc_usage_add weburl_0 9999
build_quota_blocks
t_eq '不限额度 → 永不封' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"

echo '== 时间/协议条目的额度模式（补盲区：此前只测 weburl）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option sd_mode 'quota'
	option sd_quota '10'
config protocol
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option proto 'tcp'
	option portd '80'
	option sd_mode 'quota'
	option sd_quota '10'
EOF
cfg_apply
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1
run_build
A=$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)
t_has '时间条目计数在 mangle ACCT' "$A" '-m mac --mac-source aa:bb:cc:dd:ee:ff -j PCA_time_0'
t_has '协议条目计数在 mangle ACCT' "$A" '-m mac --mac-source aa:bb:cc:dd:ee:ff -p tcp --dport 80 -j PCA_protocol_0'
t_eq 'filter 表不该出现计数链' '' "$(ipt_rules v4 filter PARENTCONTROL_ACCT | flat)"
t_eq '未耗尽 → QUOTA 空' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
pc_usage_add time_0 10
pc_usage_add protocol_0 10
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)
t_has '时间条目用满 → mangle QUOTA DROP' "$Q" '-m mac --mac-source aa:bb:cc:dd:ee:ff -j DROP'
t_has '协议条目用满 → mangle QUOTA DROP' "$Q" '-m mac --mac-source aa:bb:cc:dd:ee:ff -p tcp --dport 80 -j DROP'
FAKE_DATE_YMD=2026-06-08

# ============================================================
echo '== 共享池 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config quota
	option name 'kid1'
	option sd_quota '60'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_pool 'kid1'
config weburl
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_pool 'kid1'
EOF
cfg_apply
run_build
pc_usage_add weburl_0 40
pc_usage_add weburl_1 19
build_quota_blocks
t_eq '池内合计 59/60 → 两者都放行' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
pc_usage_add weburl_1 1
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)
t_has '池内合计 60/60 → 成员0 被封' "$Q" '-m mac --mac-source 00:00:5e:00:53:01 -d 1.2.3.0/24 -j DROP'
t_has '池内合计 60/60 → 成员1 被封' "$Q" '-m mac --mac-source aa:bb:cc:dd:ee:ff -d 1.2.3.0/24 -j DROP'

echo '== entry_effective 的分支键必须是「池里确实有额度」，不是「挂了池」=='
# 回归背景：曾把分支键写成 `[ -n "$_pool" ]`，于是"挂了池但池没额度"的条目会改用
# pool_usage、丢掉池名、额度归一也跟着变，封锁判定与看板一起错。两种池都要钉住。
fresh
cfg_begin 1
cfg_section <<'EOF'
config quota
	option name 'nq'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_quota '30'
	option sd_pool 'nq'
config weburl
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option domains 'example.com'
	option sd_quota '40'
	option sd_pool 'nq'
EOF
cfg_apply
pc_usage_add weburl_0 30
# 关键：第二个成员也要**有限额**，否则它算"不限额度"、会被 pool_usage 跳过，
# 池内合计就仍等于 weburl_0 自己的 30，这条断言就分辨不出分支键。
pc_usage_add weburl_1 20
t_eq '池内合计(50) 确实不等于条目自己(30)，下面这条才有鉴别力' '50' "$(pool_usage nq school)"
t_eq '挂「没填额度」的池 → 用条目自己的额度/用量（30 30 nq，不是池内合计）' '30 30 nq' "$(entry_effective weburl 0 school)"

fresh
cfg_begin 1
cfg_section <<'EOF'
config quota
	option name 'wq'
	option sd_quota '60'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_quota '30'
	option sd_pool 'wq'
config weburl
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option domains 'example.com'
	option sd_pool 'wq'
EOF
cfg_apply
pc_usage_add weburl_0 30
pc_usage_add weburl_1 20
t_eq '挂「有额度」的池 → 用池的额度/池内合计（60 50 wq）' '60 50 wq' "$(entry_effective weburl 0 school)"

echo '== 第三态：池额度是 0（"池提供了额度"但归一是 0）→ 仍算池提供，用池的额度/池内合计 =='
# 用来钉住判据形态：如果把"池是否提供额度"漂成 `pc_quota_positive(...) > 0`，
# 池额度 0/abc 这类就会走错分支（这里是 0 → 会变成用条目自己的额度/用量）。
fresh
cfg_begin 1
cfg_section <<'EOF'
config quota
	option name 'zq'
	option sd_quota '0'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_quota '30'
	option sd_pool 'zq'
config weburl
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option domains 'example.com'
	option sd_quota '40'
	option sd_pool 'zq'
EOF
cfg_apply
pc_usage_add weburl_0 30
pc_usage_add weburl_1 20
t_eq '池额度 0 → 走池分支（0 50 zq，不是 30 30 zq）' '0 50 zq' "$(entry_effective weburl 0 school)"

echo '== 防自锁：到局域网/路由器自身的流量必须放行 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '10'
EOF
cfg_apply
cat > "$T_TMP/net.uci" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.0.2.1'
	option netmask '255.255.255.0'
EOF
cfg_load network "$T_TMP/net.uci"
run_build
pc_usage_add time_0 10
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA)
t_has '放行到局域网(含路由器)的流量' "$Q" '-d 192.0.2.1/255.255.255.0 -j RETURN'
t_has '仍然封锁无设备条件的条目' "$Q" '-j DROP'
# RETURN 必须在 DROP 之前
t_eq 'RETURN 排在 DROP 之前' RETURN "$(printf '%s\n' "$Q" | grep -m1 -- '-j' | awk '{print $NF}')"

echo '== 防自锁：拿不到局域网网段时，跳过无设备条件的封锁 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option sd_mode 'quota'
	option sd_quota '10'
EOF
cfg_apply
run_build
pc_usage_add time_0 10
build_quota_blocks
t_eq '无网段 → 不封锁（防自锁）' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
t_has '日志有告警' "$(cat "$LOG_FILE" 2>/dev/null)" '跳过封锁以防自锁'

# ============================================================
echo '== 日子类型切换 → 用节假日档案（两套档案各自独立的额度）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '60'
	option sd_qstart '09:00:00'
	option sd_qend '21:00:00'
	option hd_mode 'quota'
	option hd_quota '15'
	option hd_qstart '10:00:00'
	option hd_qend '20:00:00'
EOF
cfg_apply
FAKE_DATE_YMD=2026-06-06 FAKE_DATE_DOW=6   # 周六 → 节假日
run_build
t_has '节假日：计数链有规则' "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)" '-j PCA_weburl_0'
t_eq '节假日：也有时段规则' 1 "$([ "$(win_ranges v4 mangle PARENTCONTROL_QUOTA)" -gt 0 ] && echo 1 || echo 0)"
pc_usage_add weburl_0 15
build_quota_blocks
t_eq '节假日额度 15 用完 → 封' 1 "$([ "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)" -gt 0 ] && echo 1 || echo 0)"
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1   # 周一 → 平日
run_build
pc_usage_add weburl_0 15
build_quota_blocks
t_eq '平日额度 60：用了 15 没超 → 不封' 0 "$(uncond_drop v4 mangle PARENTCONTROL_QUOTA)"

# ============================================================
echo '== 用量采样：字节增量与阈值 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
FAKE_DATE_HM=13:00
run_build
# run_build 内部（build_acct_rules）自己会先采样一次，base 文件已经存在了。
# 想验「首次采样」这条路，必须先把 base 清掉，否则走的是增量分支。
rm -f "$STATE_DIR"/base.*
t_eq '首次采样：无流量不计数' 0 "$(sample_counters; pc_usage_get weburl_0)"
ipt_setcounters v4 mangle PARENTCONTROL_ACCT PCA_weburl_0 40960   # +40KB ≥ 32KB
sample_counters
t_eq '增量 ≥ 阈值 → +1 分钟' 1 "$(pc_usage_get weburl_0)"

echo '== 首次采样也该计入（不能丢开机后那一段）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
FAKE_DATE_HM=13:00
run_build
rm -f "$STATE_DIR"/base.*   # 必须真的没有 base 文件，才是在验首次采样
ipt_setcounters v4 mangle PARENTCONTROL_ACCT PCA_weburl_0 40960
t_eq '首次采样（无 base）即计入' 1 "$(sample_counters; pc_usage_get weburl_0)"
ipt_setcounters v4 mangle PARENTCONTROL_ACCT PCA_weburl_0 41984   # +1KB < 32KB
sample_counters
t_eq '增量 < 阈值 → 不计' 1 "$(pc_usage_get weburl_0)"
ipt_setcounters v4 mangle PARENTCONTROL_ACCT PCA_weburl_0 41984   # 无增量
sample_counters
t_eq '无增量 → 不计' 1 "$(pc_usage_get weburl_0)"
ipt_setcounters v4 mangle PARENTCONTROL_ACCT PCA_weburl_0 40000   # 规则重建 → 计数回落且新值 ≥ 阈值
sample_counters
t_eq '计数器回落(重建) → 按新值计 1 分钟' 2 "$(pc_usage_get weburl_0)"

echo '== 采样阈值可配 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
# usage_min_kb=0 → 任何流量都算
cfg_set 'parentcontrol.@basic[0].usage_min_kb' '0'
run_build
sample_counters
ipt_setcounters v4 mangle PARENTCONTROL_ACCT '*' 1
sample_counters
t_eq '阈值 0：1 字节也算' 1 "$(pc_usage_get weburl_0)"

# ============================================================
echo '== 域名解析：只增不减 + 条目删除清理 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'time'
	option sd_start '00:00'
	option sd_end '00:00'
EOF
cfg_apply
refresh_ips
t_has '解析出 IPv4 /24' "$(cat "$IPDIR/weburl_0")" '1.2.3.0/24'
t_has '解析出 IPv6 /64' "$(cat "$IPDIR/weburl_0")" '2402:4e00:1410:0::/64'
put_resolve <<'EOF'
4 example.com 9.9.9.9
4 www.example.com 9.9.9.9
EOF
refresh_ips
F=$(cat "$IPDIR/weburl_0")
t_has 'CDN 换段后旧段仍保留' "$F" '1.2.3.0/24'
t_has '新段被加入' "$F" '9.9.9.0/24'
# 删除条目后刷新 → 文件清理
: > "$T_TMP/empty.uci"
cfg_reset
cfg_load parentcontrol "$T_TMP/empty.uci"
t_eq '条目删除后 ip 文件被清理' 'gone' "$(refresh_ips; [ -e "$IPDIR/weburl_0" ] && echo here || echo gone)"

# ============================================================
echo '== 重建自愈：模拟 fw4 reload 清空全部链 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
run_build
rm -f "$FAKE_IPT_STATE_DIR"/v4.json "$FAKE_IPT_STATE_DIR"/v6.json   # fw4 把表清空
refresh_ip_body >/dev/null 2>&1
t_eq '重建后 TAGQ 链回来' ok "$(ipt_exists v4 mangle PARENTCONTROL_QUOTA && echo ok)"
t_eq '重建后 ACCT 链回来' ok "$(ipt_exists v4 mangle PARENTCONTROL_ACCT && echo ok)"
t_eq '重建后 PREROUTING 跳转回来' 'PARENTCONTROL_QUOTA PARENTCONTROL_ACCT' \
	"$(ipt_jump v4 mangle PREROUTING | flat)"
t_eq '重建后计数规则仍在' ok "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | grep -q PCA_weburl_0 && echo ok)"

# ============================================================
echo '== 载荷：crontab =='
fresh
cfg_begin 1
cfg_apply
: > "$FAKE_CRONTAB"
cron_sync 1
CR=$(cat "$FAKE_CRONTAB")
t_has 'tick 每分钟' "$CR" '* * * * * /etc/init.d/parentcontrol tick'
t_has 'refresh_ip 每 30 分钟' "$CR" '*/30 * * * * /etc/init.d/parentcontrol refresh_ip'
cron_sync 1
t_eq '重复写入不产生重复项' 2 "$(grep -c parentcontrol "$FAKE_CRONTAB")"
cfg_set 'parentcontrol.@basic[0].ip_refresh' '0'
cron_sync 1
t_eq 'ip_refresh=0 → 只留 tick' 1 "$(grep -c parentcontrol "$FAKE_CRONTAB")"
cron_sync 0
t_eq 'stop 清空 crontab' '' "$(cat "$FAKE_CRONTAB")"

# ============================================================
echo '== 拆除：del_rule 不留残渣 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option sd_mode 'time'
	option sd_start '00:00'
	option sd_end '00:00'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
run_build
del_rule
t_eq 'filter 无 PARENTCONTROL 链' '' "$(ipt_chains v4 filter | grep PARENTCONTROL || true)"
t_eq 'mangle 无 PARENTCONTROL 链' '' "$(ipt_chains v4 mangle | grep PARENTCONTROL || true)"
t_eq 'PREROUTING 无残留跳转' '' "$(ipt_jump v4 mangle PREROUTING | grep PARENTCONTROL || true)"
t_eq 'v6 同样干净' '' "$(ipt_all v6 | grep PARENTCONTROL || true)"

# ============================================================
echo '== stats_tsv（看板数据源）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option remarks '测试设备'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1 FAKE_DATE_HM=13:00
run_build
pc_usage_add weburl_0 7
S=$(stats_tsv)
t_has 'meta 行（日期/类型/阈值/保留天/当前时间）' "$S" 'meta	2026-06-08	school	32	90'
t_has 'entry 行（key/备注/mac）' "$S" 'weburl_0	weburl	0	测试设备	00:00:5e:00:53:01'
# 防线：额度/已用必须是真实解析出来的值（曾经因为一个恒假的 if，这里恒为 0 → 看板全错）
t_has 'entry 行带真实额度与已用（额度 30 / 已用 7）' "$S" '00:00:5e:00:53:01	30	7'
t_has 'hist 行' "$S" 'hist	20260608	7'
t_has 'histkey 行' "$S" 'histkey	20260608	weburl_0	7'
t_eq '无额度条目时不产生 entry 行' 0 "$(cfg_reset; cfg_load parentcontrol "$T_TMP/empty.uci" 2>/dev/null; stats_tsv 2>/dev/null | grep -c '^entry')"

# ============================================================
echo '== reset_quota：清零今天用量 + 记重置日志 + 立刻解封 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1 FAKE_DATE_HM=13:00
run_build
pc_usage_add weburl_0 20
t_eq '重置前已用 20' 20 "$(pc_usage_get weburl_0)"
reset_quota weburl_0
t_eq '重置后已用 0' 0 "$(pc_usage_get weburl_0)"
t_eq '重置日志 1 行' 1 "$(wc -l < "$RESET_LOG" | tr -d ' ')"
t_has '日志含 key 与重置前用量' "$(cat "$RESET_LOG")" 'weburl_0	20'
t_eq '非法 key 被拒（不写日志）' 1 "$(reset_quota 'x;rm -rf /' >/dev/null 2>&1; wc -l < "$RESET_LOG" | tr -d ' ')"
# 耗尽 → 封锁；重置后应立刻解封
pc_usage_add weburl_0 30
build_quota_blocks
t_has '耗尽 → QUOTA 有 DROP' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)" '-j DROP'
reset_quota weburl_0
t_eq '重置后立刻解封（QUOTA 空）' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
# 池重置
cfg_section <<'EOF'
config quota
	option name 'kid1'
	option sd_quota '60'
config weburl
	option enable '1'
	option remarks 'B'
	option mac '00:00:5e:00:53:02'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_pool 'kid1'
EOF
cfg_apply
run_build
pc_usage_add weburl_1 5
reset_quota pool:kid1
t_eq '池重置：成员用量清零' 0 "$(pc_usage_get weburl_1)"

# ============================================================
echo '== 节假日抓取 =='
fresh
: > "$HOLIDAY_LOCAL/2026.json"
printf '{"year":2026,"days":[{"name":"bundled","date":"2026-01-01","isOffDay":true}]}\n' > "$HOLIDAY_LOCAL/2026.json"
: > "$FAKE_WGET_LOG"
rm -f "$HOLIDAY_CACHE"/*.json "$HOLIDAY_CACHE"/*.stamp
FAKE_WGET_MODE=ok
FAKE_DATE_YMD=2026-06-08
refresh_holiday novet
t_eq 'novet：拷 bundle、不联网' '' "$(cat "$FAKE_WGET_LOG")"
t_eq 'novet：bundle 已就位' ok "$([ -f "$HOLIDAY_CACHE/2026.json" ] && echo ok)"
refresh_holiday
t_has '联网拉次年' "$(cat "$FAKE_WGET_LOG")" '/2027.json'
t_hasnt '当年数据 7 天内有效 → 不重拉' "$(cat "$FAKE_WGET_LOG")" '/2026.json'
: > "$FAKE_WGET_LOG"
refresh_holiday
t_eq '一天内节流：不再重复联网' '' "$(cat "$FAKE_WGET_LOG")"
# 缓存缺失 → 先用包内 bundle 兜底，不联网
rm -f "$HOLIDAY_CACHE/2026.json"
: > "$FAKE_WGET_LOG"
refresh_holiday
t_eq '缓存缺失时先用 bundle 兜底（不联网）' '' "$(cat "$FAKE_WGET_LOG")"
t_eq 'bundle 已补回缓存' ok "$([ -f "$HOLIDAY_CACHE/2026.json" ] && echo ok)"
# 连 bundle 都没有 → 才联网
rm -f "$HOLIDAY_LOCAL/2026.json" "$HOLIDAY_CACHE/2026.json" "$HOLIDAY_CACHE/2026.stamp"
: > "$FAKE_WGET_LOG"
refresh_holiday
t_has 'bundle 也缺 → 联网拉取当年' "$(cat "$FAKE_WGET_LOG")" '/2026.json'
printf '{"year":2026,"days":[{"name":"bundled","date":"2026-01-01","isOffDay":true}]}\n' > "$HOLIDAY_LOCAL/2026.json"
FAKE_WGET_MODE=fail
rm -f "$HOLIDAY_CACHE"/*.stamp
refresh_holiday
t_eq '抓取失败不改动已有文件' ok \
	"$([ -f "$HOLIDAY_CACHE/2026.json" ] && echo ok)"
FAKE_WGET_MODE=ok

# ============================================================
echo '== 用量看板 TSV =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
	option sd_quota '30'
EOF
cfg_apply
FAKE_DATE_YMD=2026-06-08
FAKE_DATE_HM=13:00
pc_usage_add weburl_0 12
# 列表页数据源：stats_tsv brief（只出 meta + entry 两行，不跑历史/计数器）
TSV=$(stats_tsv brief)
t_has 'brief: meta 行含日期与类型' "$TSV" 'meta	2026-06-08	school	32	90'
t_has 'brief: entry 行含 key/时段/额度/已用' "$TSV" 'weburl_0	weburl	0'
t_hasnt 'brief: 不输出 hist 行' "$TSV" 'hist	'
t_hasnt 'brief: 不输出 reset 行' "$TSV" 'reset	'
# 看板数据源：完整 stats_tsv（含历史汇总）
TSV=$(stats_tsv)
t_has 'full: hist 行' "$TSV" 'hist	20260608	12'
t_has 'full: histkey 行' "$TSV" 'histkey	20260608	weburl_0	12'

t_summary
