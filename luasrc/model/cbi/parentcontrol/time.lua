local disp = require "luci.dispatcher"
local ui = require "luci.model.cbi.parentcontrol.ui"

local a, t, e
a = Map("parentcontrol", translate("Parent Control"),
	translate("时间限制：按 MAC/IP 限制机器是否联网，含 IPv4 与 IPv6。</br>\
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
	translate("强力管控：被管控机器将无法连接软路由后台。"))
e.rmempty = false
e:value("0", "普通管控")
e:value("1", "强力管控")
e.default = "0"

t = a:section(TypedSection, "time", translate("时间限制列表"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true
t.extedit = disp.build_url("admin", "control", "parentcontrol", "time_edit") .. "/%s"

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

t:option(Value, 'remarks', translate('备注'))

e = t:option(DummyValue, "mac", translate("MAC"))
e.rmempty = true

e = t:option(DummyValue, "ip", translate("静态IP"))
e.rmempty = true

e = t:option(DummyValue, "_profiles", translate("档案"))
e.cfgvalue = ui.profiles
e.rmempty = true

e = t:option(DummyValue, "_used", translate("今日额度"))
e.cfgvalue = function(self, section) return ui.used(self, section, "time") end
e.rmempty = true

return a
