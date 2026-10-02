local parts = require "luci.model.cbi.parentcontrol.parts"

local a, t, e

a = Map("parentcontrol", translate("使用限额"),
	translate("额度按<b>自然日</b>结算，不结转。每天在「发放时刻」发放当天额度，<b>发放时刻之前按“没额度”封住</b>（例如 12:00 → 0 点到 12 点不能用）。</br>\
时间段/日期来自节假日数据 + 下方寒暑假区间；无当年数据时退化为“周一至五=平日、周末=节假日”。"))

a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(Flag, "enabled", translate("开启"))
e.rmempty = false

e = t:option(Value, "reset_school", translate("平日额度发放时刻"),
	translate("HH:MM（北京时间）。之前当天额度未发放，按“没额度”封住。"))
e.placeholder = '12:00'
e.default = '12:00'
e.validate = parts.validate_time
e.rmempty = true

e = t:option(Value, "reset_holiday", translate("节假日额度发放时刻"),
	translate("HH:MM（北京时间）。"))
e.placeholder = '12:00'
e.default = '12:00'
e.validate = parts.validate_time
e.rmempty = true

e = t:option(Value, "usage_keep", translate("用量历史保留天数"))
e.datatype = "uinteger"
e.default = "90"
e.rmempty = true

e = t:option(DummyValue, "pc_usage_link", translate("用量看板"),
	translate("详细统计、最近 30 天趋势与条目/设备分析已移到「使用统计」页。"))
e.template = "parentcontrol/pcusagelink"

t = a:section(TypedSection, "quota", translate("共享额度池"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true

t:option(Value, "name", translate("组名"),
	translate("条目在额度模式里填这个组名即并入。"))

e = t:option(Value, "sd_quota", translate("平日(分钟)"))
e.datatype = "uinteger"
e.rmempty = true

e = t:option(Value, "hd_quota", translate("节假日(分钟)"))
e.datatype = "uinteger"
e.rmempty = true

t = a:section(TypedSection, "vacation", translate("寒暑假区间"))
t.template = "cbi/tblsection"
t.anonymous = true
t.addremove = true

t:option(Value, "name", translate("名称"))

e = t:option(Value, "start", translate("开始"))
e.placeholder = '07-01 或 2026-01-20'
e.rmempty = true

e = t:option(Value, "end", translate("结束"))
e.placeholder = '08-31 或 2026-02-16'
e.rmempty = true

return a
