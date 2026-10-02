local disp = require "luci.dispatcher"
local ui = require "luci.model.cbi.parentcontrol.ui"

local a, t, e
a = Map("parentcontrol", translate("Parent Control"),
	translate("协议过滤：按 MAC/IP 控制指定端口/协议，含 IPv4 与 IPv6。</br>\
列表只显示摘要，点每行的 <b>编辑</b> 进去设置「平日 / 节假日」两套档案（关闭 / 时段 / 每日额度）。"))

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
t.extedit = disp.build_url("admin", "control", "parentcontrol", "protocol_edit") .. "/%s"

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

t:option(Value, 'remarks', translate('备注'))

e = t:option(DummyValue, "mac", translate("MAC"))
e.rmempty = true

e = t:option(DummyValue, "ip", translate("静态IP"))
e.rmempty = true

e = t:option(DummyValue, "proto", translate("协议"))
e.rmempty = true

e = t:option(DummyValue, "portd", translate("目的端口"))
e.rmempty = true

e = t:option(DummyValue, "_profiles", translate("档案"))
e.cfgvalue = ui.profiles
e.rmempty = true

e = t:option(DummyValue, "_used", translate("今日额度"))
e.cfgvalue = function(self, section) return ui.used(self, section, "protocol") end
e.rmempty = true

return a
