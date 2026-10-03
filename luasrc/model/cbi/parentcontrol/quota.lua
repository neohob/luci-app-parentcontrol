local a, t, e

a = Map("parentcontrol", translate("使用限额"),
	translate("额度按<b>自然日</b>结算、<b>每天 0 点自然重置</b>，不结转。</br>\
具体限制在「网址过滤」条目行的「编辑」页里配：先选<b>可用时段</b>（默认全天，不跨日、起必须早于止），时段外一律不可用且不计入额度；再设<b>每日额度</b>，或勾「不限额度」只受时段限制。</br>\
时间段/日期来自节假日数据 + 下方寒暑假区间；无当年数据时退化为“周一至五=平日、周末=节假日”。"))

a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(Flag, "enabled", translate("开启"))
e.rmempty = false

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
	translate("条目在档案里填这个组名即并入（也可以自己不填额度、完全交给池）。"))

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
