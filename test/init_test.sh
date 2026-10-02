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
echo '== 机器(time) 时段模式 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option sd_mode 'time'
	option sd_start '08:00'
	option sd_end '18:00'
	option hd_mode 'off'
EOF
cfg_apply
run_build
R=$(ipt_rules v4 filter PARENTCONTROL_TIME | flat)
t_has '时段规则带 -m time 窗口与 REJECT' "$R" \
	'-m mac --mac-source 00:00:5e:00:53:01 -m time --timestart 00:00 --timestop 10:00 -j REJECT'
t_eq '普通管控只挂 FORWARD' '' "$(ipt_rules v4 filter INPUT | flat)"
t_eq '模式=off 的档案不生成规则（TAGP 空）' '' "$(ipt_rules v4 filter PARENTCONTROL_PROTOCOL | flat)"

echo '== 机器 时段：起控=停控 = 全天封（无时间条件）=='
fresh
cfg_begin 1
cfg_section <<'EOF'
config time
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option sd_mode 'time'
	option sd_start '00:00'
	option sd_end '00:00'
	option hd_mode 'off'
EOF
cfg_apply
run_build
R=$(ipt_rules v4 filter PARENTCONTROL_TIME | flat)
t_has '全天封 = 无 -m time' "$R" '-m mac --mac-source aa:bb:cc:dd:ee:ff -j REJECT'
t_hasnt '全天封不含 -m time' "$R" '-m time'

echo '== 机器 强力管控 → 同时挂 INPUT =='
fresh
cfg_begin 1 1
cfg_section <<'EOF'
config time
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option sd_mode 'time'
	option sd_start '00:00'
	option sd_end '00:00'
EOF
cfg_apply
run_build
t_has '强力管控挂 INPUT' "$(ipt_rules v4 filter INPUT | flat)" '-j PARENTCONTROL_TIME'

# ============================================================
echo '== 协议 时段模式 + 端口 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config protocol
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option proto 'tcp'
	option portd '80,443'
	option sd_mode 'time'
	option sd_start '09:00'
	option sd_end '17:00'
EOF
cfg_section <<'EOF'
config protocol
	option enable '1'
	option mac 'aa:bb:cc:dd:ee:ff'
	option proto 'udp'
	option portd '53'
	option sd_mode 'time'
	option sd_start '09:00'
	option sd_end '17:00'
EOF
cfg_apply
run_build
R=$(ipt_rules v4 filter PARENTCONTROL_PROTOCOL | flat)
t_has '多端口用 multiport --dports' "$R" '-p tcp -m multiport --dports 80,443'
t_has '单端口用 --dport' "$R" '-p udp --dport 53'

# ============================================================
echo '== 网址 时段模式：IP 链 + 字符串链 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'time'
	option sd_start '08:00'
	option sd_end '18:00'
EOF
cfg_apply
run_build
V4I=$(ipt_rules v4 mangle PARENTCONTROL_IP | flat)
V6I=$(ipt_rules v6 mangle PARENTCONTROL_IP | flat)
t_has 'IPv4 封 /24' "$V4I" '-m mac --mac-source 00:00:5e:00:53:01 -m time --timestart 00:00 --timestop 10:00 -d 1.2.3.0/24 -j DROP'
t_has 'IPv6 封 /64' "$V6I" '-d 2402:4e00:1410:0::/64 -j DROP'
t_has '字符串串在 WEBURL 链' "$(ipt_rules v4 mangle PARENTCONTROL_WEBURL | flat)" '--string example.com'
t_has 'DNS(udp53) 规则' "$(ipt_rules v4 mangle PARENTCONTROL_WEBURL | flat)" '-p UDP --dport 53'
t_has 'SNI(tcp80,443) 规则' "$(ipt_rules v4 mangle PARENTCONTROL_WEBURL | flat)" '-p TCP -m multiport --dports 80,443'
t_has 'TAGI 已挂 PREROUTING' "$(ipt_jump v4 mangle PREROUTING | flat)" 'PARENTCONTROL_IP'
t_has 'TAGW 已挂 PREROUTING' "$(ipt_jump v4 mangle PREROUTING | flat)" 'PARENTCONTROL_WEBURL'

# ============================================================
echo '== 网址 额度模式：计数链 + 未耗尽不封 =='
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
t_eq '未耗尽 → QUOTA 链为空' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
t_eq '额度模式不再产生时段封规则' '' "$(ipt_rules v4 mangle PARENTCONTROL_IP | flat)"
t_eq 'PREROUTING 顺序 QUOTA→WEBURL→IP→ACCT' \
	'PARENTCONTROL_QUOTA PARENTCONTROL_WEBURL PARENTCONTROL_IP PARENTCONTROL_ACCT' \
	"$(ipt_jump v4 mangle PREROUTING | flat)"

echo '== 额度三态：未发放(R 之前) → 封 =='
FAKE_DATE_HM=09:00
build_quota_blocks
Q=$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)
t_has 'R 之前封目标 IP' "$Q" '-m mac --mac-source 00:00:5e:00:53:01 -d 1.2.3.0/24 -j DROP'
t_has 'R 之前也封 DNS/SNI 串' "$Q" '--string example.com'
FAKE_DATE_HM=12:00
build_quota_blocks
t_eq '恰好到 R → 放行' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"

echo '== 额度三态：耗尽 → 封 =='
FAKE_DATE_HM=13:00
pc_usage_add weburl_0 29
build_quota_blocks
t_eq '未用完(29/30) → 放行' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"
pc_usage_add weburl_0 1
build_quota_blocks
t_has '用完(30/30) → 封' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)" '-d 1.2.3.0/24 -j DROP'

echo '== 额度=0/空 → 不限 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'quota'
EOF
cfg_apply
run_build
pc_usage_add weburl_0 9999
build_quota_blocks
t_eq '无额度 → 永不封' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"

# ============================================================
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

echo '== 池只统计“额度模式”的成员 =='
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
	option sd_mode 'time'
	option sd_pool 'kid1'
EOF
cfg_apply
run_build
pc_usage_add weburl_1 999    # 时段模式成员，不应计入池
pc_usage_add weburl_0 10
build_quota_blocks
t_eq '时段成员的用量不计入池' '' "$(ipt_rules v4 mangle PARENTCONTROL_QUOTA | flat)"

# ============================================================
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
echo '== 日子类型切换 → 用节假日档案 =='
fresh
cfg_begin 1
cfg_section <<'EOF'
config weburl
	option enable '1'
	option mac '00:00:5e:00:53:01'
	option domains 'example.com'
	option sd_mode 'time'
	option sd_start '08:00'
	option sd_end '18:00'
	option hd_mode 'quota'
	option hd_quota '15'
EOF
cfg_apply
FAKE_DATE_YMD=2026-06-06 FAKE_DATE_DOW=6   # 周六 → 节假日
run_build
t_eq '节假日走额度：时段 IP 链为空' '' "$(ipt_rules v4 mangle PARENTCONTROL_IP | flat)"
t_has '节假日走额度：计数链有规则' "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)" '-j PCA_weburl_0'
FAKE_DATE_YMD=2026-06-08 FAKE_DATE_DOW=1   # 周一 → 平日
run_build
t_has '平日走时段：IP 链有规则' "$(ipt_rules v4 mangle PARENTCONTROL_IP | flat)" '-d 1.2.3.0/24 -j DROP'
t_eq '平日不再计数' '' "$(ipt_rules v4 mangle PARENTCONTROL_ACCT | flat)"

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
t_eq '重建后 TAGI 链回来' ok "$(ipt_exists v4 mangle PARENTCONTROL_IP && echo ok)"
t_eq '重建后 TAGQ 链回来' ok "$(ipt_exists v4 mangle PARENTCONTROL_QUOTA && echo ok)"
t_eq '重建后 ACCT 链回来' ok "$(ipt_exists v4 mangle PARENTCONTROL_ACCT && echo ok)"
t_eq '重建后 PREROUTING 跳转回来' 'PARENTCONTROL_QUOTA PARENTCONTROL_WEBURL PARENTCONTROL_IP PARENTCONTROL_ACCT' \
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
t_has 'meta 行' "$S" 'meta	2026-06-08	school	12:00	1'
t_has 'entry 行（key/备注/mac/模式/额度/已用）' "$S" 'entry	weburl_0	weburl	0	测试设备	00:00:5e:00:53:01	quota	30	7'
t_has 'hist 行' "$S" 'hist	20260608	7'
t_has 'histkey 行' "$S" 'histkey	20260608	weburl_0	7'
t_eq '无额度条目时不产生 entry 行' 0 "$(cfg_reset; cfg_load parentcontrol "$T_TMP/empty.uci" 2>/dev/null; stats_tsv 2>/dev/null | grep -c '^entry')"

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
TSV=$(usage_tsv)
t_has 'day 行含日期与类型' "$TSV" 'day	2026-06-08	school	12:00	1'
t_has 'item 行含已用/额度' "$TSV" 'item	weburl[0]	12	30'
t_has 'history 行' "$TSV" 'history	20260608	12'

t_summary
