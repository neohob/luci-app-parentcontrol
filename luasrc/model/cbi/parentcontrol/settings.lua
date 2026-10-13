local a, t, e

a = Map("parentcontrol", translate("设置"),
	translate("额度按<b>自然日</b>结算、<b>每天 0 点自然重置</b>，不结转。</br>\
具体限制在「网址过滤」条目行的「编辑」页里配：先选<b>可用时段</b>（默认全天，不跨日、起必须早于止），时段外一律不可用且不计入额度；再设<b>每日额度</b>，或勾「不限额度」只受时段限制。</br>\
时间段/日期来自节假日数据 + 下方寒暑假区间；无当年数据时退化为“周一至五=平日、周末=节假日”。"))

a.template = "parentcontrol/settings"

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

-- AI 辅助解析：把「应用/游戏/网站名称」翻译成真实域名（在「编辑条目」页逐行点按钮触发）。
-- 第 8 轮 D15（R8）：固定单节；第 9 轮 D22（A31）：**渲染期不写盘**。
--   · NamedSection 绑死段名 ai：段被手工删掉时字段照常渲染，保存即重建该段；
--   · 0 段自愈只在 **Map 自己的 cursor**（`a.uci`）里补一个内存段，交给 LuCI 正常保存时提交；
--     绝不在渲染期 commit —— 打开（GET）设置页不得改写 /etc/config/parentcontrol。
do
	if not a.uci:get("parentcontrol", "ai") then
		a.uci:section("parentcontrol", "ai", "ai", {})
	end
end
t = a:section(NamedSection, "ai", "ai", translate("AI 辅助解析"))
t.addremove = false

e = t:option(Value, "endpoint", translate("AI endpoint"),
	translate("OpenAI 兼容接口基址，例如 http://192.168.1.10:11434/v1；只填基址，不要带 /models 或 /chat/completions。留空 = 不使用 AI 解析。"))
e.placeholder = "http://192.168.1.10:11434/v1"
e.rmempty = true

e = t:option(Value, "apikey", translate("API Key"),
	translate("可选。留空表示该接口不需要鉴权。"))
e.password = true
e.rmempty = true

e = t:option(Value, "model", translate("模型名称"),
	translate("点下方「获取模型列表」从 endpoint 拉取候选，或手动填写模型 id。"))
e.rmempty = true

e = t:option(DummyValue, "pc_ai_models", translate("模型列表"),
	translate("从上面的 endpoint 拉取可用模型，填充「模型名称」的候选。"))
e.template = "parentcontrol/ai_models"

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
e.placeholder = translate('07-01 或 2026-01-20')
e.rmempty = true

e = t:option(Value, "end", translate("结束"))
e.placeholder = translate('08-31 或 2026-02-16')
e.rmempty = true

return a
