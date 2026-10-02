local o = require "luci.sys"
local fs = require "nixio.fs"
local ipc = require "luci.ip"
local net = require "luci.model.network".init()
local sys = require "luci.sys"

local parts = require "luci.model.cbi.parentcontrol.parts"

local a, t, e
a = Map("parentcontrol", translate("Parent Control"),
	translate("<b><font color=\"green\">网址过滤：按域名/CIDR 管控，支持 IPv4 与 IPv6。</font></b></br>\
每条目分「平日」「节假日」两套档案，各选 关闭 / 时段 / 每日额度 之一：</br>\
· <b>时段</b>：只在此时段内封锁（起控=停控 或留空 = 全天封）。</br>\
· <b>每日额度</b>：每天给 N 分钟，用完后封到当天重置点；可填「共享组」把多个条目并进同一个额度池。</br>\
不指定 MAC/IP 表示限制所有机器。"))

a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(DummyValue, "parentcontrol_status", translate("当前状态"))
e.template = "parentcontrol/parentcontrol"
e.value = translate("Collecting data...")

e = t:option(Flag, "enabled", translate("开启"))
e.rmempty = false

e = t:option(ListValue, "algos", translate("过滤力度"))
e:value("bm", "一般过滤")
e:value("kmp", "强效过滤")
e.default = "kmp"

e = t:option(ListValue, "control_mode", translate("管控强度"),
	translate("普通管控：管控国内网站，出国插件的国外网站无法管控"))
e.rmempty = false
e:value("0", "普通管控")
e.default = "0"

e = t:option(Value, "ip_refresh", translate("IP封锁自动更新间隔(分钟)"),
	translate("定时重新解析域名刷新 IP，0=关闭。"))
e.default = "30"
e.datatype = "uinteger"
e.rmempty = true

e = t:option(ListValue, "ip_mask", translate("IP封锁粒度"),
	translate("/24 可兜住 CDN 换节点，推荐。"))
e:value("24", "整个 /24 网段（推荐）")
e:value("32", "仅精确 IP")
e.default = "24"
e.rmempty = true

e = t:option(Value, "usage_min_kb", translate("用量判定阈值(KB/分钟)"),
	translate("一分钟内至少这么多流量才算“在用”，滤掉后台心跳；0=任何流量都算。"))
e.default = "32"
e.datatype = "uinteger"
e.rmempty = true

t = a:section(TypedSection, "weburl", translate("网址过滤列表"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true

t:option(Value, 'remarks', translate('备注'))

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

e = t:option(Value, "mac", translate("MAC地址"))
e.rmempty = true
o.net.mac_hints(function(t, a) e:value(t, "%s (%s)" % {t, a}) end)

e = t:option(Value, "ip", translate("静态IP/主机名"),
	translate("与 MAC 任一命中即生效，防止客户端改 MAC。留空不启用。"))
e.rmempty = true

e = t:option(Value, "domains", translate("关键词/域名<font color=\"green\">(逗号分隔)</font>"),
	translate("填域名（apex 覆盖子域），或直接填 CIDR。"))
e.rmempty = true

parts.add_profile(t, "sd", translate("平日模式"))
parts.add_profile(t, "hd", translate("节假日模式"))

return a
