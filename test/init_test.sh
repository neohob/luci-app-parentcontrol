#!/bin/sh
# init.d 冒烟测试：用桩命令跑规则构建，验证不会崩、且按预期生成 DROP。
# 运行： sh test/init_test.sh
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"

cat > "$BIN/iptables-legacy" <<'EOF'
#!/bin/sh
echo "ipt:$*" >> "$IPT_LOG"
case "$*" in
*" -L "*) ;;
esac
exit 0
EOF
cp "$BIN/iptables-legacy" "$BIN/ip6tables-legacy"
cat > "$BIN/resolveip" <<'EOF'
#!/bin/sh
case "$1" in
-4) echo "1.2.3.4" ;;
-6) echo "2402:4e00:1410:0:0:0:0:1" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 1\n' > "$BIN/nft"
printf '#!/bin/sh\nexit 1\n' > "$BIN/wget"
printf '#!/bin/sh\n[ "$1" = "-l" ] && exit 0\ncat >/dev/null 2>&1\nexit 0\n' > "$BIN/crontab"
printf '#!/bin/sh\nexit 0\n' > "$BIN/conntrack"
chmod +x "$BIN"/*

# uci 桩
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
uci_get() {
	case "$1" in
	'parentcontrol.@basic[0].enabled')      echo 1 ;;
	'parentcontrol.@basic[0].algos')        echo kmp ;;
	'parentcontrol.@basic[0].ip_mask')      echo 24 ;;
	'parentcontrol.@basic[0].usage_min_kb') echo 32 ;;
	'parentcontrol.@basic[0].reset_school')  echo 12:00 ;;
	'parentcontrol.@basic[0].reset_holiday') echo 12:00 ;;
	'parentcontrol.@weburl[0].enable')   echo 1 ;;
	'parentcontrol.@weburl[0].sd_mode')  echo quota ;;
	'parentcontrol.@weburl[0].sd_quota') echo 5 ;;
	'parentcontrol.@weburl[0].mac')      echo '00:00:5e:00:53:01' ;;
	'parentcontrol.@weburl[0].ip')       echo '' ;;
	'parentcontrol.@weburl[0].domains')  echo example.com ;;
	'parentcontrol.@protocol[0].proto')  echo tcp ;;
	'parentcontrol.@protocol[0].portd')  echo 80 ;;
	'parentcontrol.@protocol[0].ports')  echo '' ;;
	*) return 1 ;;
	esac
}
uci_show() {
	echo "parentcontrol.@weburl[0].enable='1'"
	echo "parentcontrol.@weburl[0].sd_mode='quota'"
	echo "parentcontrol.@weburl[0].sd_quota='5'"
	echo "parentcontrol.@weburl[0].mac='00:00:5e:00:53:01'"
	echo "parentcontrol.@weburl[0].domains='example.com'"
}
[ "$1" = "-q" ] && shift
case "$1" in
get)  uci_get "$2" ;;
show) uci_show ;;
*)    exit 0 ;;
esac
EOF
chmod +x "$BIN/uci"

export IPT_LOG="$TMP/ipt.log"; : > "$IPT_LOG"
export IPDIR="$TMP/ips" USAGE_DIR="$TMP/usage" HOLIDAY_CACHE="$TMP/holiday"
export HOLIDAY_LOCAL="$TMP/holiday-local" STATE_DIR="$TMP/state"
export LOG_FILE="$TMP/log" LOCK="$TMP/lock" TICK_LOCK="$TMP/tlock"
export PC_LIB="$ROOT/root/usr/lib/parentcontrol/common.sh"
mkdir -p "$IPDIR" "$USAGE_DIR" "$HOLIDAY_CACHE" "$STATE_DIR"

. "$ROOT/root/etc/init.d/parentcontrol"

fails=0
eq() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s want=[%s] got=[%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s missing [%s] in [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }

eq 'pc_entry_eff_mode' quota "$(pc_entry_eff_mode weburl 0 school)"
eq 'proto_cond' '-p tcp --dport 80' "$(proto_cond 0)"
eq 'devcount mac' '-m mac --mac-source 00:00:5e:00:53:01' "$(devcount weburl 0)"

RES=$(resolve_entry weburl 0)
has 'resolve ipv4 /24' "$RES" '1.2.3.0/24'
has 'resolve ipv6 /64' "$RES" '2402:4e00:1410:0::/64'

# 写入用量使额度耗尽（quota=5），build_quota_blocks 应封
pc_usage_add weburl_0 5
: > "$IPT_LOG"
build_quota_blocks
has 'quota exhausted -> DROP' "$(cat "$IPT_LOG")" 'PARENTCONTROL_QUOTA'
has 'quota exhausted -> DROP rule' "$(cat "$IPT_LOG")" '-j DROP'

eq 'active_acct_keys' 'weburl_0' "$(active_acct_keys)"

# TSV 看板：行格式 item<TAB><条目><TAB>已用<TAB>额度
J=$(usage_tsv)
has 'usage_tsv day'  "$J" 'day'
has 'usage_tsv item' "$J" 'weburl[0]'
echo "$J" | awk -F'\t' '$1=="item"{print $3}' | grep -qx 5 && ok_line='item used=5' || ok_line='item used!=5'
eq 'usage_tsv item used' 'item used=5' "$ok_line"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
