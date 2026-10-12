-- 使用统计（看板）页：只读展示，逻辑在 statsdata.lua，渲染在 view/parentcontrol/stats.htm
-- 这里只留 Map 元信息（标题/说明）与整页模板：整页不再套 cbi/map，
-- 所以既没有匿名 basic TypedSection，也没有 DummyValue（看板不需要表单，自然没有「保存」按钮）。
local a

a = Map("parentcontrol", translate("使用统计"),
	translate("每个条目只按「它自己规则命中的流量」计时。这里汇总今天与最近 30 天的用量，并做条目/设备维度分析。"))
a.template = "parentcontrol/stats"

return a
