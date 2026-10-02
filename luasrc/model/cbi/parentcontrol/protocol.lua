local o = require "luci.sys"
local fs = require "nixio.fs"
local ipc = require "luci.ip"
local net = require "luci.model.network".init()
local sys = require "luci.sys"

local parts = require "luci.model.cbi.parentcontrol.parts"

local a, t, e
a = Map("parentcontrol", translate("Parent Control"),
	translate("<b><font color=\"green\">协议过滤：控制指定 MAC/IP 机器是否使用指定端口/协议，含 IPv4 与 IPv6。</font></b></br>\
端口可写范围（5000:5100）或多段（5100,5110,5001:5002）。</br>\
每条目分「平日」「节假日」两套档案，各选 关闭 / 时段 / 每日额度 之一：</br>\
· <b>时段</b>：只在此时段内禁止（起控=停控 或留空 = 全天禁止）。</br>\
· <b>每日额度</b>：每天给 N 分钟该端口的可用时间，用完后封到当天重置点；可填「共享组」并入共享额度池。</br>\
不指定 MAC/IP 表示限制所有机器。"))

a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(DummyValue, "parentcontrol_status", translate("当前状态"))
e.template = "parentcontrol/parentcontrol"
e.value = translate("Collecting data...")

e = t:option(Flag, "enabled", translate("开启"))
e.rmempty = false

e = t:option(ListValue, "control_mode", translate("管控强度"),
	translate("普通管控：管控国内端口，出国插件的国外端口无法管控。"))
e.rmempty = false
e:value("0", "普通管控")
e.default = "0"

t = a:section(TypedSection, "protocol", translate("协议过滤列表"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true

t:option(Value, 'remarks', translate('备注'))

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

e = t:option(Value, "mac", translate("MAC地址<font color=\"green\">(留空为全部客户端)</font>"))
e.placeholder = "ALL"
e.rmempty = true
o.net.mac_hints(function(t, a) e:value(t, "%s (%s)" % {t, a}) end)

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

parts.add_profile(t, "sd", translate("平日"), translate("平日模式"))
parts.add_profile(t, "hd", translate("节假日"), translate("节假日模式"))

return a
