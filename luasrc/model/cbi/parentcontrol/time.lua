local o = require "luci.sys"
local fs = require "nixio.fs"
local ipc = require "luci.ip"
local net = require "luci.model.network".init()
local sys = require "luci.sys"

local function validate_time(self, value, section)
	local hh, mm = string.match(value, "^(%d?%d):(%d%d)$")
	hh = tonumber(hh); mm = tonumber(mm)
	if hh and mm and hh <= 23 and mm <= 59 then
		return value
	else
		return nil, "时间格式必须为 HH:MM 或者留空"
	end
end

-- 平日/节假日两套档案：模式三选一（关闭/时段/额度），按模式显隐参数
local function add_profile(t, sfx, label)
	local m = t:option(ListValue, sfx .. "_mode", translate(label .. "模式"))
	m:value("off", translate("关闭"))
	m:value("time", translate("时段"))
	m:value("quota", translate("每日额度"))
	m.default = "time"
	m.rmempty = true

	local s = t:option(Value, sfx .. "_start", translate("起控"))
	s.placeholder = '00:00'; s.default = '00:00'; s.validate = validate_time
	s:depends(sfx .. "_mode", "time")
	s.rmempty = true

	local e = t:option(Value, sfx .. "_end", translate("停控"))
	e.placeholder = '00:00'; e.default = '00:00'; e.validate = validate_time
	e:depends(sfx .. "_mode", "time")
	e.rmempty = true

	local q = t:option(Value, sfx .. "_quota", translate("每日分钟"))
	q.datatype = "uinteger"
	q:depends(sfx .. "_mode", "quota")
	q.rmempty = true

	local p = t:option(Value, sfx .. "_pool", translate("共享组"))
	p.placeholder = translate("留空=独立额度")
	p:depends(sfx .. "_mode", "quota")
	p.rmempty = true
end

local a, t, e
a = Map("parentcontrol", translate("Parent Control"),
	translate("<b><font color=\"green\">时间限制：限制指定 MAC/IP 机器是否联网，含 IPv4 与 IPv6。</font></b></br>\
每条目分「平日」「节假日」两套档案，各选 关闭 / 时段 / 每日额度 之一：</br>\
· <b>时段</b>：只在此时段内禁止上网（起控=停控 或留空 = 全天禁止）。</br>\
· <b>每日额度</b>：每天给 N 分钟上网时间，用完后封到当天重置点；可填「共享组」并入共享额度池。</br>\
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
	translate("强力管控：被管控机器将无法连接软路由后台。"))
e.rmempty = false
e:value("0", "普通管控")
e:value("1", "强力管控")
e.default = "0"

t = a:section(TypedSection, "time", translate("时间限制列表"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true

t:option(Value, 'remarks', translate('备注'))

e = t:option(Flag, "enable", translate("开启"))
e.rmempty = false
e.default = '1'

e = t:option(Value, "mac", translate("MAC地址<font color=\"green\">(留空为全部客户端)</font>"))
e.rmempty = true
o.net.mac_hints(function(t, a) e:value(t, "%s (%s)" % {t, a}) end)

e = t:option(Value, "ip", translate("静态IP/主机名"),
	translate("与 MAC 任一命中即生效，防止客户端改 MAC。留空不启用。"))
e.rmempty = true

add_profile(t, "sd", translate("平日"))
add_profile(t, "hd", translate("节假日"))

return a
