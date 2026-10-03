local disp = require "luci.dispatcher"
local ui = require "luci.model.cbi.parentcontrol.ui"

local a, t, e
a = Map("parentcontrol", translate("家长控制"),
	translate("时间限制：按 MAC/IP 限制机器是否联网，含 IPv4 与 IPv6。</br>\
列表只显示摘要，点每行的 <b>编辑</b> 进去设置「平日 / 节假日」两套档案（关闭 / 每日额度）。额度模式下可再限定「可用时段」，只有时段内能用，时段外的流量不计入额度。"))

a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(DummyValue, "parentcontrol_status", translate("当前状态"))
e.template = "parentcontrol/parentcontrol"
e.value = translate("获取数据中…")

e = t:option(Flag, "enabled", translate("开启"))
e.rmempty = false

t = a:section(TypedSection, "time", translate("时间限制列表"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true
t.extedit = disp.build_url("admin", "control", "parentcontrol", "time_edit") .. "/%s"

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

t:option(Value, 'remarks', translate('备注'))

e = t:option(DummyValue, "mac", translate("设备"))
e.cfgvalue = ui.mac
e.rmempty = true

e = t:option(DummyValue, "ip", translate("静态IP"))
e.rmempty = true

e = t:option(DummyValue, "_profiles", translate("档案"))
e.cfgvalue = ui.profiles
e.rmempty = true

e = t:option(DummyValue, "_used", translate("今日额度"))
e.cfgvalue = function(self, section) return ui.used(self, section, "time") end
e.rmempty = true

e = t:option(DummyValue, "_reset", translate("重置"))
e.template = "parentcontrol/resetbtn"
e.cfgvalue = function(self, section) return ui.quota_key(self, section, "time") end
e.rmempty = true

return a
