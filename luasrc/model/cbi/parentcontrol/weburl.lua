local disp = require "luci.dispatcher"
local ui = require "luci.model.cbi.parentcontrol.ui"

local a, t, e
a = Map("parentcontrol", translate("家长控制"),
	translate("网址过滤：按域名/CIDR 管控，支持 IPv4 与 IPv6。</br>\
列表只显示摘要，点每行的 <b>编辑</b> 进去给「平日 / 节假日」两套档案各自设「可用时段」+「每日额度」。只有时段内能用，时段外的流量不计入额度；额度 <b>0</b> = 一分钟都不给（全禁）。"))

a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(DummyValue, "parentcontrol_status", translate("当前状态"))
e.template = "parentcontrol/parentcontrol"
e.value = translate("获取数据中…")

e = t:option(Flag, "enabled", translate("开启"))
e.rmempty = false

e = t:option(ListValue, "algos", translate("过滤力度"))
e:value("bm", "一般过滤")
e:value("kmp", "强效过滤")
e.default = "kmp"

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
e.default = "8"
e.datatype = "uinteger"
e.rmempty = true

t = a:section(TypedSection, "weburl", translate("网址过滤列表"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true
t.extedit = disp.build_url("admin", "control", "parentcontrol", "weburl_edit") .. "/%s"

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

t:option(Value, 'remarks', translate('备注'))

e = t:option(DummyValue, "mac", translate("设备"))
e.cfgvalue = ui.mac
e.rmempty = true

e = t:option(DummyValue, "ip", translate("静态IP"))
e.rmempty = true

e = t:option(DummyValue, "domains", translate("域名/IP"))
e.rmempty = true

e = t:option(DummyValue, "_profiles", translate("档案"))
e.cfgvalue = ui.profiles
e.rmempty = true

e = t:option(DummyValue, "_used", translate("今日额度"))
e.cfgvalue = function(self, section) return ui.used(self, section, "weburl") end
e.rmempty = true

e = t:option(DummyValue, "_reset", translate("重置"))
e.template = "parentcontrol/resetbtn"
e.cfgvalue = function(self, section) return ui.quota_key(self, section, "weburl") end
e.rmempty = true

return a
