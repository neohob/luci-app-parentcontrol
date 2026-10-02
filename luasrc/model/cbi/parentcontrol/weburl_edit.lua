-- 网址条目的详细设置页（从列表页的「编辑」按钮进入，section id 在 arg[1]）
local o = require "luci.sys"
local disp = require "luci.dispatcher"
local parts = require "luci.model.cbi.parentcontrol.parts"

if not arg[1] then
	luci.http.redirect(disp.build_url("admin", "control", "parentcontrol", "weburl"))
	return
end

local a, t, e
a = Map("parentcontrol", translate("编辑网址条目"),
	translate("平日 / 节假日 两套档案各自二选一：<b>时段</b>（只在此时段内封锁，起控=停控 或留空 = 全天封）或 <b>每日额度</b>（每天 N 分钟，用完封到当天重置点；可填共享组名并入额度池）。"))
a.redirect = disp.build_url("admin", "control", "parentcontrol", "weburl")

if not a:get(arg[1]) then
	luci.http.redirect(a.redirect)
	return
end

t = a:section(NamedSection, arg[1], "weburl")
t.addremove = false

t:option(Value, "remarks", translate("备注"))

e = t:option(Value, "mac", translate("MAC地址"))
e.rmempty = true
o.net.mac_hints(function(mac, name) e:value(mac, "%s (%s)" % {mac, name}) end)

e = t:option(Value, "ip", translate("静态IP/主机名"),
	translate("与 MAC 任一命中即生效，防止客户端改 MAC。留空不启用。"))
e.rmempty = true

e = t:option(Value, "domains", translate("关键词/域名<font color=\"green\">(逗号分隔)</font>"),
	translate("填域名（apex 覆盖子域），或直接填 CIDR。"))
e.rmempty = true

parts.add_profile(t, "sd", translate("平日模式"))
parts.add_profile(t, "hd", translate("节假日模式"))

return a
