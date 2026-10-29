module("luci.controller.parentcontrol", package.seeall)

local util = require "luci.util"
local translate = require("luci.i18n").translate

function index()
    if not nixio.fs.access("/etc/config/parentcontrol") then return end

        entry({"admin", "control"}, firstchild(), "管控", 44).dependent = false
	local e = entry({"admin","control","parentcontrol"},firstchild(),_("家长控制"),2)
	e.dependent=false
	e.acl_depends = { "luci-app-parentcontrol" }
	entry({"admin", "control", "parentcontrol","weburl"}, cbi("parentcontrol/weburl"), _("网址过滤"), 20).leaf = true
	entry({"admin", "control", "parentcontrol","settings"}, cbi("parentcontrol/settings"), translate("设置"), 40).leaf = true
	entry({"admin", "control", "parentcontrol","stats"}, cbi("parentcontrol/stats"), _("使用统计"), 45).leaf = true
	-- 各模块的「详细设置」独立页（列表行用 extedit 跳过来，section id 在 arg[1]）
	entry({"admin", "control", "parentcontrol","weburl_edit"}, cbi("parentcontrol/weburl_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","status"}, call("status")).leaf = true
	entry({"admin", "control", "parentcontrol","reset_quota"}, call("reset_quota")).leaf = true
	-- 仅 POST（test_post_security 拒绝非 POST）：AI 模型列表 / AI 域名解析
	entry({"admin", "control", "parentcontrol","ai_models"}, call("ai_models")).leaf = true
	entry({"admin", "control", "parentcontrol","ai_parse"}, call("ai_parse")).leaf = true
	-- round75：未归类目标的 AI 推测 / 一键归入条目（都只接受 POST + CSRF）
	entry({"admin", "control", "parentcontrol","unclassified_infer"}, call("unclassified_infer")).leaf = true
	entry({"admin", "control", "parentcontrol","unclassified_apply"}, call("unclassified_apply")).leaf = true
end

function status()
    local e = {}
    -- 所有链都在 mangle 表（统一模型：QUOTA 封锁 + ACCT 计数）。
    -- 只判断「链是否存在」，不要求有匹配规则：开启状态下即使列表全空也应显示运行中。
    e.status = luci.sys.call("iptables -t mangle -S 2>/dev/null | grep -q PARENTCONTROL || iptables -S 2>/dev/null | grep -q PARENTCONTROL") == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

-- 重置某条目/池今天的额度。key 必须严格匹配白名单（防 shell 注入）。
function reset_quota()
    -- 改状态的操作必须 POST + CSRF token：GET 会被跨站顶层导航触发
    -- （Lax cookie 会带上），导致额度被清零并写日志。
    if not require("luci.dispatcher").test_post_security() then return end
    local key = luci.http.formvalue("key") or ""
    local ok = false
    if key:match("^[a-z][a-z0-9_]*_[0-9]+$") or key:match("^pool:[A-Za-z0-9_.%-]+$") then
        ok = (luci.sys.call("/etc/init.d/parentcontrol reset_quota " .. key .. " >/dev/null 2>&1") == 0)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = ok, key = key })
end

-- AI：从 {endpoint}/models 拉取模型候选。POST + CSRF（同 reset_quota 范式）。
function ai_models()
    if not require("luci.dispatcher").test_post_security() then return end
    local ai = require "luci.model.cbi.parentcontrol.ai"
    local endpoint = luci.http.formvalue("endpoint") or ""
    local apikey = luci.http.formvalue("apikey") or ""
    local res = ai.models(endpoint, apikey)
    luci.http.prepare_content("application/json")
    luci.http.write_json(res)
end

-- AI：把「应用/游戏/网站名称」解析成真实域名。POST + CSRF。
function ai_parse()
    if not require("luci.dispatcher").test_post_security() then return end
    local ai = require "luci.model.cbi.parentcontrol.ai"
    local text = luci.http.formvalue("text") or ""
    local truncated = false
    if #text > 2048 then
        text = text:sub(1, 2048)
        truncated = true
    end
    local res = ai.parse(text)
    if truncated then res.truncated = true end
    luci.http.prepare_content("application/json")
    luci.http.write_json(res)
end

-- ======================================================================
-- round75（R75-C/R75-D）：未归类目标的「AI 推测」与「一键归入条目」
-- 两个端点都是 POST + CSRF（test_post_security），GET 一律不发、不写。
-- ======================================================================

-- 该条目已配的「封锁名称」清单（只有名称文字，不含域名）。
-- 与 common.sh 的 pc_apps_rows 同口径取 `|` 前部分，空则回退域名首项。
local function apps_names(text)
	local out = {}
	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local name, rest = line:match("^([^|]*)|(.*)$")
		if name == nil then name, rest = line, "" end
		name = name:gsub("%c", " "):gsub(" +", " "):gsub("^ ", ""):gsub(" $", "")
		if name == "" then
			for tok in rest:gmatch("[^,%s]+") do name = tok break end
		end
		if name and name ~= "" then out[#out + 1] = name end
	end
	return out
end

-- 推测未归类目标是什么服务。**只在用户点按钮时触发**（页面加载不调用）。
function unclassified_infer()
	if not require("luci.dispatcher").test_post_security() then return end
	luci.http.prepare_content("application/json")

	local ai  = require "luci.model.cbi.parentcontrol.ai"
	local key = luci.http.formvalue("key") or ""
	if not key:match("^weburl_%d+$") then
		luci.http.write_json({ ok = false, error = translate("条目编号不合法") })
		return
	end

	local oktsv, tsv = pcall(require, "luci.model.cbi.parentcontrol.tsv")
	if not oktsv then
		luci.http.write_json({ ok = false, error = translate("统计模块不可用") })
		return
	end
	local d = tsv.read(false)

	-- 未归类目标 = app_map[key] 里映射到 0（未归类）的目标。
	local tgts = {}
	for tgt, nr in pairs((d.app_map or {})[key] or {}) do
		if (tonumber(nr) or 0) == 0 and tgt ~= "" then tgts[#tgts + 1] = tgt end
	end

	-- 组织名必须走 `stats_tsv asn`（tsv.read_asn）：默认 stats_tsv **不输出 asn 行**，
	-- 直接读 d.asn 永远是空表 ⇒ org 全空 ⇒ ai.infer 会把所有目标都过滤掉、一个字节都不发、
	-- 按钮永远「没有推测出可信结果」。read_asn 会先吃缓存，只对未缓存的公网目标查 Team Cymru
	-- （私网/保留地址由 shell 侧 pc_asn_queryable 挡掉，不产生任何外发查询）。
	local asnmap = {}
	if #tgts > 0 and tsv.read_asn then
		local okasn, m = pcall(tsv.read_asn, tgts)
		if okasn and type(m) == "table" then asnmap = m end
	end
	local items = {}
	for _, tgt in ipairs(tgts) do
		local a = asnmap[tgt]
		items[#items + 1] = { target = tgt, org = (type(a) == "table" and a.org) or "" }
	end

	-- 该条目的 apps 原文 → 名称清单（不含域名）。
	local apps = ""
	pcall(function()
		local uci = require("luci.model.uci").cursor()
		local idx = tonumber(key:match("^weburl_(%d+)$"))
		local i = 0
		uci:foreach("parentcontrol", "weburl", function(s)
			if i == idx then apps = s["apps"] or "" end
			i = i + 1
		end)
	end)

	local res = ai.infer({ items = items, names = apps_names(apps) })
	-- body（请求体原文）只用于测试断言，不下发到浏览器。
	res.body = nil
	luci.http.write_json(res)
end

-- 一键归入条目：名称已存在 ⇒ 追加到该名称行末尾；不存在 ⇒ 末尾新增一行。
function unclassified_apply()
	if not require("luci.dispatcher").test_post_security() then return end
	luci.http.prepare_content("application/json")

	local ai = require "luci.model.cbi.parentcontrol.ai"
	local res = ai.apply_entry({
		key    = luci.http.formvalue("key") or "",
		target = luci.http.formvalue("target") or "",
		name   = luci.http.formvalue("name") or "",
		-- reload = stop; start（真机 15–26 秒）⇒ 后台起，立刻返回 JSON。
		reload = function()
			luci.sys.call("( /etc/init.d/parentcontrol reload >/dev/null 2>&1 & ) ")
		end,
	})
	luci.http.write_json(res)
end
