-- 协议条目的详细设置页（section id 在 arg[1]）
local o = require "luci.sys"
local disp = require "luci.dispatcher"
local parts = require "luci.model.cbi.parentcontrol.parts"

if not arg[1] then
	luci.http.redirect(disp.build_url("admin", "control", "parentcontrol", "protocol"))
	return
end

local a, t, e
a = Map("parentcontrol", translate("编辑协议条目"),
	translate("端口可写范围（5000:5100）或多段（5100,5110,5001:5002）。</br>\
平日 / 节假日 两套档案各自二选一：<b>时段</b>（只在此时段内禁止，起控=停控 或留空 = 全天禁止）或 <b>每日额度</b>（每天 N 分钟该端口的可用时间，用完封到当天重置点；可填共享组名并入额度池）。"))
a.redirect = disp.build_url("admin", "control", "parentcontrol", "protocol")

if not a:get(arg[1]) then
	luci.http.redirect(a.redirect)
	return
end

t = a:section(NamedSection, arg[1], "protocol")
t.addremove = false

t:option(Value, "remarks", translate("备注"))

e = t:option(Value, "mac", translate("MAC地址<font color=\"green\">(留空为全部客户端)</font>"))
e.placeholder = translate("全部客户端")
e.rmempty = true
o.net.mac_hints(function(mac, name) e:value(mac, "%s (%s)" % {mac, name}) end)

e = t:option(Value, "ip", translate("静态IP/主机名"),
	translate("与 MAC 任一命中即生效，防止客户端改 MAC。留空不启用。"))
e.rmempty = true

e = t:option(ListValue, "proto", translate("端口协议"))
e.rmempty = false
e.default = 'tcp'
e:value("tcp", translate("TCP"))
e:value("udp", translate("UDP"))
e:value("icmp", translate("ICMP"))

e = t:option(Value, "ports", translate("源端口"))
e.rmempty = true

e = t:option(Value, "portd", translate("目的端口"))
e:value("", translate("ICMP"))
e:value("80", "TCP-HTTP")
e:value("443", "TCP-HTTPS")
e:value("22", "TCP-SSH")
e:value("1723", "TCP-PPTP")
e:value("25", "TCP-SMTP")
e:value("110", "TCP-POP3")
e:value("21", "TCP-FTP21")
e:value("23", "TCP-TELNET")
e:value("53", "TCP-DNS53")
e:value("20", "UDP-FTP20")
e:value("1701", "UDP-L2TP")
e:value("69", "UDP-TFTP")
e:value("500", "UDP-IPSEC")
e:value("53", "UDP-DNS53")
e:value("161", "UDP-SNMP")
e.rmempty = true

parts.add_profile(t, "sd", translate("平日模式"))
parts.add_profile(t, "hd", translate("节假日模式"))

return a
