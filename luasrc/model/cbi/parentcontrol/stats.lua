-- 使用统计（看板）页：只读展示，逻辑在 statsdata.lua，渲染在 view/parentcontrol/stats.htm
local a, t, e
a = Map("parentcontrol", translate("使用统计"),
	translate("每个条目只按「它自己规则命中的流量」计时。这里汇总今天与最近 30 天的用量，并做条目/设备维度分析。"))
a.template = "parentcontrol/index"

t = a:section(TypedSection, "basic", translate(""))
t.anonymous = true

e = t:option(DummyValue, "pc_stats", translate("用量统计"))
e.template = "parentcontrol/stats"

return a
