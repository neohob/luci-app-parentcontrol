<h1 align="center">
  <br>luci-app-parentcontrol<br>
</h1>

<p align="center">
<a href="https://openwrt.org"><img alt="OpenWrt" src="https://img.shields.io/badge/OpenWrt-%E2%89%A519.07-ff0000?logo=openwrt&logoColor=white"></a>
<a href="https://www.google.com/chrome/"><img alt="Chrome" src="https://img.shields.io/badge/Chrome-%E2%89%A5111-4285F3?logo=googlechrome&logoColor=white"></a>
<a href="https://www.apple.com/safari/"><img alt="Safari" src="https://img.shields.io/badge/Safari-%E2%89%A516.4-000000?logo=safari&logoColor=white"></a>
<a href="https://www.mozilla.org/firefox/"><img alt="Firefox" src="https://img.shields.io/badge/Firefox-%E2%89%A5128-FF7138?logo=firefoxbrowser&logoColor=white"></a>
</p>

家长控制，可以按时间控制机器、按端口/协议过滤、按网址（关键词）过滤。


**上游原版在开启软件加速的 IPv4/IPv6 双栈环境下，「网址过滤」按 MAC 拦某个网站是完全不生效的**
（而且是静默失效：界面正常、iptables 不报错）。本 fork 把它修好了，并补上了按 IP/CIDR 的封锁能力。

在此之上还加了：**每日累计使用额度**（用完即封）、**平日/节假日双档案**、**共享额度池**、
**法定节假日自动识别 + 寒暑假手动区间**，以及**静态 IP 防改 MAC**。


## 本 fork 的改动

### 1. 修复四处上游缺陷

1. `local Z1,Z2,...,Z7=0,...` 是 bash 语法，ash(busybox) 会报 `bad variable name` 并**中止整个脚本**，
   导致 time 之后 protocol/weburl 两组规则根本没被设置，还留下一个锁文件。
2. `del_rule` 里的 `$i -F $TAG` / `$TAGP` / `$TAGW` 是 `$ip` 的笔误，旧规则不会被清掉，规则不断堆叠。
3. `start()` 缺少陈旧锁判断：脚本一旦被中断，锁文件残留，此后每次 `start()` 都 exit 1，
   界面显示未运行却不报错。
4. `/etc/hotplug.d/iface/97-parentcontrol` 里 `[ "$(`uci -q get ...`)" == 1 ]` 把 `$( )` 和反引号套在一起，
   外层会把内层命令的**输出**当成命令执行（报 `1: not found`），条件恒为假 —— 脚本永远 exit 0，
   接口事件后从不重装规则。

### 2. 挂载点改到 mangle PREROUTING

原版挂在 `OUTPUT` 链，而 `-m mac --mac-source` 在 OUTPUT 里**永远不成立**
（路由器本机发出的报文没有源 MAC），所以「按 MAC 限制某台设备访问某网址」从来就没生效过。

改挂 mangle 表的 PREROUTING —— 只有这个位置同时能看到客户端源 MAC 和明文负载，
并且位于 flowtable 快转决策和其它组件 DNAT 之前。

### 3. 有受管设备时停用 flow offloading

这是最关键、也最难查的一条。

fw4 会往 `forward` 链装一条 `meta l4proto { tcp, udp } flow add @ft`，把已建立的连接丢进
流卸载表；之后这条连接的报文在内核 ingress 快路径直接转发，**整个 netfilter 栈（含
mangle PREROUTING）都不再经过**，挂在 PREROUTING 上的规则自然也就失效了。

一开始想只把受管设备排除出去，写成 `ether saddr != <MAC> flow add @ft`，但**这个条件盖不住入方向**：

- 出方向（客户端 → 外网）：源 MAC 是客户端，能排除；
- 入方向（回包）：源 MAC 是上游网关，目的 MAC 此时还是路由器自己的
  （LAN 侧的以太头是在 forward 钩子之后才写的）——
  于是**回包一进来就把整条流加进卸载表，之后双向都绕过 netfilter**。

而且流一旦被卸载，**不会因为后来把规则拿掉就退出**（`nft delete flowtable` 会报
`Resource busy`，清不掉），会一直漏到自然过期。表现出来就是「关掉列表再打开，封不住；
设备息屏重连之后又好了」。

所以本 fork 的做法是：**只要列表里还有受管设备（不管有没有勾选），就整条拿掉那条
`flow add` 规则，不让任何流被卸载**；并且用 `conntrack` 显式清掉受管设备现有的连接，
让它们必须重新握手、从而被 IP 封锁拦住。停用插件时会自动恢复原样。

代价：只要列表里有受管设备，**全部设备的流卸载都是关闭的**（多走一遍 netfilter，x86
平台上通常无感）；列表清空或停用插件后自动恢复。

> 需要 `conntrack` 工具（`opkg install conntrack`）才能立即清掉旧连接；
> 没装也能跑，只是残留连接要等它自己过期。

### 4. 新增按 IP/CIDR 封锁 + 域名解析自动更新

**为什么必须有它：** 在上面那类设备上，**IPv4 转发报文的负载落在 skb 的 page frags 里，
`-m string` 看不到它**。实测：一个带唯一标记的明文 HTTP GET，转发路径上数到 18 个包经过
`mangle PREROUTING`，标记匹配 **0** 个（关掉 GRO 也一样）。所以「按关键词匹配 TLS SNI」
对 **IPv4 转发流量完全无效**。

（IPv6 相反 —— 走隧道、解封装会把负载线性化，所以 IPv6 那边 SNI 是能匹配到的。）

**结论：IPv4 转发流量只能按目标 IP（报文头）来封，头信息任何情况下都可见。** 于是：

- 新增 `PARENTCONTROL_IP` 链（IPv4/IPv6 各一条，挂在 mangle PREROUTING）
- 网址过滤行的「关键词/域名」列写域名即可：它既当子串去匹配明文 DNS 查询和 TLS SNI
  （apex 域名天然覆盖子域），也会被解析成 IP 一起封锁
- IPv4 默认封解析结果所在的整个 `/24`（`basic.ip_mask` 可改成 `32` 只封精确 IP）
- IPv6 按 `/64` 封（同一 CDN 换地址基本在同一 /64 内）
- 域名解析同时取 apex 和 `www.` 两个变体（A 记录常在 apex、AAAA 常在 www 上）
- 这一列里**含 `/` 的项直接当 CIDR 封锁**，不做解析（覆盖不到时的应急口子）
- 解析结果累积在 `/etc/parentcontrol/ip.list`，**只增不减** —— 这样 CDN 换节点后老节点
  依然被挡住，而客户端 DNS 缓存里的旧节点也不会漏
- 由 cron 按 `basic.ip_refresh`（默认 30 分钟，`0`=关闭）调用 `refresh_ip` 子命令定时刷新；
  crontab 条目由插件自己维护（start 写入、stop 移除）

### 5. 状态判定

- 「开启」开关勾着就显示运行中 —— 网址过滤列表全空只意味着没有规则去匹配，不等于没运行
- 状态接口原来只查 `filter` 表，而网址过滤链在 `mangle` 表，所以「只开网址过滤」会误报
  未运行；现在两个表都查，且只判断链是否存在

## 已知限制

- 不填域名时靠关键词猜（`关键词` → `关键词.com` / `www.关键词.com` / `关键词.cn`），
  只能覆盖主域名；要覆盖 CDN 图片/视频域名请显式填子域。
- IP 封锁是「当前解析结果 + 历史累积」。CDN 若换到全新的段，需要等下一次刷新，
  或直接把该段当作 CIDR 填进列表。
- **每日额度的计时只能靠目标 IP**：IPv4 转发报文负载内核看不到（见上），
  所以网址类额度的计时单位和它的封锁一样依赖域名解析结果；CDN 换到全新段时，
  封锁与计时会同时短暂漏掉，直到下一次刷新。机器类、协议类额度没有这个问题
  （按 MAC / 端口计数，报文头永远可见）。
- **寒暑假没有全国数据源**：各省市分别公布，格式不统一。本 fork 只能让你手动填区间
  （暑假可用 `MM-DD` 每年重复，寒假用 `YYYY-MM-DD` 指定年份）。法定节假日/调休会自动从
  [NateScarlet/holiday-cn](https://github.com/NateScarlet/holiday-cn) 拉取。
- 额度按**自然日**结算、不结转；每天在设定的「发放时刻」发放当天额度，
  **发放时刻之前按“没额度”封住**（默认 12:00 → 0 点到 12 点不能用；填 `00:00` 即整日可用）。
- 「用量阈值(KB/分钟)」用于滤掉后台心跳：一分钟内目标流量低于该值就不计这一分钟。
  设 `0` 则任何流量都算（后台推送也会耗额度，不推荐）。
- QUIC(HTTP/3) 的 SNI 本身是加密的，任何 `-m string` 方案都拦不到；好在浏览器会自动回落 TCP。
- 客户端若使用自带 HTTPDNS 的 App（IP 不来自系统 DNS），解析式封锁/计时覆盖不到它的 IP。
- 改动条目增删/排序后，按索引记录的当日计数可能串台（现有 `tblsection` 匿名索引的老毛病）；
  跨天自愈，影响很小。

## 新功能：每日额度 + 平日/节假日

每条目有两份档案：**平日** 与 **节假日**，各自三选一：

| 模式 | 含义 |
|------|------|
| 关闭 | 该档案不生效 |
| 时段 | 只在「起控~停控」之间封锁（起控=停控 或留空 = 全天封） |
| 每日额度 | 每天给 N 分钟，用完后封到当天重置点；可填「共享组」并入共享额度池 |

- **日子类型**：法定假日 ∪ 周末 ∪ 寒暑假区间 → 节假日；法定调休上班日 → 平日；
  两个数据都没有时退化为「周一至五=平日、周末=节假日」。
- **额度三态**（按自然日、不结转）：① 发放时刻前 未发放 → 封；② 已发放未用完 → 放行；
  ③ 用完 → 封。用完**立即切断**。
- **共享额度池**：在「使用限额」页建组（组自带平日/节假日两份额度），条目在额度模式里
  填同一个组名即并入，组内条目流量加总、共用额度，组耗尽则所有成员一起封。
- **用量看板**：状态页显示今天每台设备/每个池的已用与剩余，以及最近 7 天历史。
- **防改 MAC**：条目除了 MAC 还能填一个静态 IP / 主机名，**任一命中即生效**。

所有时间判断（日子类型、重置点、额度）一律按**北京时间（UTC+8）**计算，与路由器系统时区无关。
数据来自 [NateScarlet/holiday-cn](https://github.com/NateScarlet/holiday-cn)（jsDelivr 主、raw 备，
包内自带离线兜底）。
