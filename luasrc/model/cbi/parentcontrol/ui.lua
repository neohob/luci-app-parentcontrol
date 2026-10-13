-- 列表页的只读展示助手：档案摘要、今日额度。
-- 注意：本文件是被 require 的子模块，LuCI 注入的全局（translate 等）在这里不可用，
-- 必须显式 require。
local i18n = require "luci.i18n"
local devnames = require "luci.model.cbi.parentcontrol.devnames"
local tsv = require "luci.model.cbi.parentcontrol.tsv"
local hosts = require "luci.model.cbi.parentcontrol.hosts"

local M = {}

-- 每请求缓存一次 stats_tsv brief（列表页只要 meta + entry 两行，不跑历史/计数器）。
-- 解析一律走 tsv.lua：列定义只有那一份，避免改列后这里静默读错。
local _usage
function M.usage_map()
	if not _usage then _usage = tsv.read(true) end
	return _usage
end

-- 某个模块的 section-name → 序号（与 shell 侧 @type[i] 的顺序一致）
local _idx = {}
function M.section_indexes(map, typ)
	if _idx[typ] then return _idx[typ] end
	local t, i = {}, 0
	map.uci:foreach("parentcontrol", typ, function(s)
		t[s[".name"]] = i
		i = i + 1
	end)
	_idx[typ] = t
	return t
end

local function get(map, section, key)
	return map:get(section, key)
end

-- ============================================================================
-- 封锁名称行表（第 8 轮 R9/R11/D17/ADR-018）：Lua 侧解析与展示的唯一实现。
-- 数据格式与 shell 侧 pc_apps_rows 同源：每行 `名称|域名列表`；缺 `|` 的行按纯名称处理；
-- 空行跳过。名称不得含 `|` 与换行（写入时由前端保证）。
-- ============================================================================
local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- HTML 转义（列表页「封锁条目」列要求：pcdata 转义后再拼 <br>，名称里的 < & " 不能破坏页面）
local function escape(s)
	s = tostring(s or "")
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub('"', "&quot;")
	return s
end

function M.apps_rows(text)
	local rows = {}
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		if line:match("%S") then
			local name, dom = line:match("^([^|]*)|(.*)$")
			if name then
				rows[#rows + 1] = { name = trim(name), domains = trim(dom) }
			else
				rows[#rows + 1] = { name = trim(line), domains = "" }
			end
		end
	end
	return rows
end

-- 行的显示名（A30：名称空时用域名列表首项兜底）。四处只保证「有效性判据」一致
-- （名称与域名都空才丢弃）；首项切分在中英标点/竖线上可能不同，且只影响展示名，
-- 不影响封锁目标集与解析。
-- 注意：不要用本函数改编辑页输入框的值（apps_rows.htm 走 M.apps_rows，名称必须原样、可为空）。
local function disp_name(r)
	if r.name ~= "" then return r.name end
	return r.domains:match("^[^%s,;、，；]+") or ""
end

-- 行表里的名称列表（保持行序；两者都空的行才跳过）
function M.app_names(text)
	local out = {}
	for _, r in ipairs(M.apps_rows(text)) do
		local n = disp_name(r)
		if n ~= "" then out[#out + 1] = n end
	end
	return out
end

-- 列表页「封锁条目」列：每个名称先 HTML 转义、再用 <br> 连接（转义在前、拼接在后）
function M.apps_html(text)
	local out = {}
	for _, r in ipairs(M.apps_rows(text)) do
		local n = disp_name(r)
		if n ~= "" then out[#out + 1] = escape(n) end
	end
	return table.concat(out, "<br>")
end

-- 条目的名单模式：缺失/非 white 一律按 black（与 shell 侧 _quota_emit_rules 同一判据）
function M.mode(map, section)
	if tostring(map:get(section, "mode") or "") == "white" then return "white" end
	return "black"
end

-- 与后端 pc_quota_positive 同口径的归一：纯数字 → 该数；非纯数字 → 0（新语义 0 = 全禁）；
-- 空/没填 → nil（表示"没有这个额度来源"，由调用方继续往下判）
local function qmin(v)
	if v == nil or v == "" then return nil end
	if v:match("^%d+$") then return tonumber(v) end
	return 0
end

-- 共享池的该档案额度（与后端 pc_pool_quota 同口径）：返回 nil / "" = 池没填额度 = 不限额
local function pool_quota(map, pool, sfx)
	if not pool or pool == "" then return nil end
	local found
	map.uci:foreach("parentcontrol", "quota", function(s)
		if not found and s.name == pool then
			local v = s[sfx .. "_quota"]
			if v == nil or v == "" then v = s.quota end
			found = v
		end
	end)
	return found
end

-- 档案摘要：平日 / 节假日 各自的「可用时段 + 额度」。
-- 判定必须与后端 pc_entry_unlimited 同源，否则会出现「界面说不限、其实全天全禁」这种反向矛盾。
-- 显示上尽量短：全天时段不写、秒不写、两档案一样时只写一次（原来两句拼在一起又长又乱）。
function M.profiles(self, section)
	local map = self.map
	local function one(sfx)
		local q = get(map, section, sfx .. "_quota")
		local p = get(map, section, sfx .. "_pool")
		local unl = get(map, section, sfx .. "_unlimited")
		local pqn = qmin(pool_quota(map, p, sfx))   -- nil = 池没额度（含根本没挂池）
		local qn = qmin(q)                          -- nil = 没自填额度
		local st
		-- 顺序与后端 pc_entry_unlimited + entry_effective 一致：
		-- 勾不限 → 不限；池有额度 → 池优先；自填额度；显式关不限且无来源 → 0 分钟；挂池无额度 → 不限
		if unl == "1" then
			st = i18n.translate("不限")
		elseif pqn then
			st = pqn .. i18n.translate("分钟")
		elseif qn then
			st = qn .. i18n.translate("分钟")
		elseif unl == "0" then
			st = "0" .. i18n.translate("分钟")
		elseif p and p ~= "" then
			st = i18n.translate("不限")
		else
			st = i18n.translate("不限")
		end
		-- 时段：全天（或没填）不显示，否则显示 09:00-21:00
		local ws = get(map, section, sfx .. "_qstart")
		local we = get(map, section, sfx .. "_qend")
		if ws and we and ws ~= "" and we ~= "" and not (ws == "00:00:00" and we == "23:59:59") then
			st = st .. "(" .. ws:sub(1, 5) .. "-" .. we:sub(1, 5) .. ")"
		end
		if p and p ~= "" then st = st .. " @" .. p end
		return st
	end
	local sd, hd = one("sd"), one("hd")
	if sd == hd then
		return i18n.translate("两档案相同") .. "：" .. sd
	end
	return i18n.translate("平日") .. " " .. sd .. " · " .. i18n.translate("节假日") .. " " .. hd
end

-- 列表里的「设备」列：MAC（已知设备名）；没填 MAC 就是全部客户端；填了静态IP 也一并显示。
-- 第 8 轮（R10/D18）：绑定设备不在网时加一个 ⚠（只看不改 —— 绝不自动修改用户配置）。
function M.mac(self, section)
	local mac = self.map:get(section, "mac") or ""
	local ip = self.map:get(section, "ip") or ""
	local out = {}
	if mac ~= "" then
		local n = devnames.name(mac)
		out[#out + 1] = n and (mac .. " （" .. n .. "）") or mac
	end
	if ip ~= "" then out[#out + 1] = ip end
	if #out == 0 then return i18n.translate("全部客户端") end
	local s = table.concat(out, " / ")
	if mac ~= "" and hosts.online(mac) == false then s = s .. " ⚠" end
	return s
end

-- 绑定已失效（绑了 MAC 但该 MAC 不在网）的已启用条目数 —— 列表页页顶汇总提示用。
-- 判定与编辑页「绑定状态」同源（hosts.lua）：不自动改配置，只提示。
function M.offline_bindings(map)
	local n = 0
	map.uci:foreach("parentcontrol", "weburl", function(s)
		if s.enable == "1" and s.mac and s.mac ~= "" and hosts.online(s.mac) == false then
			n = n + 1
		end
	end)
	return n
end

-- 列表页「重置」按钮的 key：统一模型下没有模式了，任何条目都能重置当天用量，
-- 所以恒返回 "<模块>_<下标>"（重置不限额度的条目也无害）。
function M.quota_key(self, section, typ)
	local idx = M.section_indexes(self.map, typ)[section]
	if idx == nil then return "" end
	return typ .. "_" .. idx
end

-- 今日额度：不限额度 → 「不限」；否则「已用 / 额度 分钟」（额度 0 = 全禁，显示成 已用/0）。
function M.used(self, section, typ)
	local u = M.usage_map()
	local i = M.section_indexes(self.map, typ)[section]
	local rec = i and u.by_key[typ .. "_" .. i]
	if not rec then return "-" end
	if rec.unlimited then return i18n.translate("不限") end
	if rec.quota > 0 then
		return string.format("%d / %d %s", rec.used, rec.quota, i18n.translate("分钟"))
	end
	-- 额度 0 = 全天全禁（一分钟都不给），照实显示成 已用/0
	return string.format("%d / 0 %s", rec.used, i18n.translate("分钟"))
end

return M
