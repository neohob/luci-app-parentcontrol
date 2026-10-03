-- 时间（机器）条目的详细设置页（section id 在 arg[1]）
local o = require "luci.sys"
local disp = require "luci.dispatcher"
local parts = require "luci.model.cbi.parentcontrol.parts"

if not arg[1] then
	luci.http.redirect(disp.build_url("admin", "control", "parentcontrol", "time"))
	return
end

local a, t, e
a = Map("parentcontrol", translate("编辑时间条目"),
	translate("平日 / 节假日 两套档案各自选「关闭」或「每日额度」。</br>选了「每日额度」后：<b>可用时段</b>内才能使用（默认全天 00:00:00-23:59:59；不跨日，起必须早于止），时段外的流量直接被丢弃、<b>不计入额度</b>；时段内累计用满额度也会被封。</br>勾 <b>不限额度</b> 就只受时段限制（额度框会消失）。额度按自然日、每天 0 点重置，可填共享组名并入额度池。"))
a.redirect = disp.build_url("admin", "control", "parentcontrol", "time")
a.template = "parentcontrol/edit"

if not a:get(arg[1]) then
	luci.http.redirect(a.redirect)
	return
end

t = a:section(NamedSection, arg[1], "time")
t.addremove = false

t:option(Value, "remarks", translate("备注"))

e = t:option(Value, "mac", translate("MAC地址<font color=\"green\">(留空为全部客户端)</font>"))
e.rmempty = true
o.net.mac_hints(function(mac, name) e:value(mac, "%s (%s)" % {mac, name}) end)

e = t:option(Value, "ip", translate("静态IP/主机名"),
	translate("与 MAC 任一命中即生效，防止客户端改 MAC。留空不启用。"))
e.rmempty = true

parts.add_profile(t, "sd", translate("平日"))
parts.add_profile(t, "hd", translate("节假日"))

return a
