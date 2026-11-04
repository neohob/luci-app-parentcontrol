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

-- R77-A（round77）：请求超时做成设置项。默认 60 秒 —— 一次推测要把该条目所有未归类目标
-- 打包发一个请求（round75 的 ai.infer），15 秒在真机上经常不够（`curl: (28) ... 15001
-- milliseconds`）。注意：common.sh 是禁改文件，但 ai.lua 通过 `PC_AI_TIMEOUT=<秒>` 环境变量
-- 前缀把值传给 shell 的 `_pc_http_timeout()`，所以这里只存 uci 值即可。
-- 留空 = 用默认值（60）；非数字/越界的值在 ai.lua 里一律回落默认值（不会拼进命令行）。
-- R77-E（round77b）：语义从「超时判定」改成「兜底上限」—— 流式之后判结束靠的是
-- 「流自己结束」与「连续 N 秒没有输出」，总时长只防对端无限挂。
e = t:option(Value, "timeout", translate("总时长上限（秒）"),
	translate("可选，默认 900。范围 30–1800。这是硬上限：到点就断，与当时有没有在收数据无关 —— 一直在输出、但总时长到了也会被截断（实测总时长上限设成 5 秒时，持续有输出的流照样在 5 秒被截断）。它防的是对端无限期占着一个连接。"))
e.placeholder = "900"
e.datatype = "or(\"\", range(30,1800))"
e.rmempty = true

e = t:option(Value, "stall", translate("停滞判定（秒）"),
	translate("可选，默认 60。范围 10–300。判据是平均速率：连续这么久速率低于 1 字节/秒就中断。注意这只是判定窗口 —— curl 只在自身分块时才检查速率，所以实际的掐断时刻可能晚于这个值（实测设 2 秒时约 8 秒才断）。窗口内有零星字节也算「慢」，不等同于「完全没有输出」。另外停滞窗口与总时长上限会重叠：总时长设 30 秒而停滞设 22 秒以上时，静默流几乎总是先撞总时长墙（掐断时刻约晚 stall+6 秒），此时被掐断的原因是「总时长到了」，页面会据实写清期间数据是否已停止。"))
e.placeholder = "60"
e.datatype = "or(\"\", range(10,300))"
e.rmempty = true

-- round78：目标反解（L1 PTR + L2 被动 DNS）。默认**开** —— 它只产生证据，不发任何东西出去；
-- 真正外发仍然只在用户点「推测本行目标」时发生。关掉后：采集进程会停、dnsmap 不再增长、
-- 页面不再显示「反解：」小字（旧数据允许留在磁盘上，不主动删）。
e = t:option(Flag, "dnsrev", translate("目标反解（被动 DNS）"),
	translate("读取本机的 DNS 查询记录，给「未归类」的目标网段找线索（反查主机名、被动解析到的域名）。这些只是线索，可能是 CDN 边缘节点或托管平台，不一定就是那个目标对应的应用 —— 最终判断仍由 AI 做。数据只在本机保存（不写 /etc/config），只有当你点击「推测本行目标」时才会把这些域名随请求一起发给 AI。"))
e.default = "1"
e.rmempty = false

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
