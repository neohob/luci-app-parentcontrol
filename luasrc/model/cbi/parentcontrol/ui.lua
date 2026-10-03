-- 列表页的只读展示助手：档案摘要、今日额度。
-- 注意：本文件是被 require 的子模块，LuCI 注入的全局（translate 等）在这里不可用，
-- 必须显式 require。
local i18n = require "luci.i18n"
local devnames = require "luci.model.cbi.parentcontrol.devnames"
local tsv = require "luci.model.cbi.parentcontrol.tsv"

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

-- 档案摘要：平日 / 节假日 各自的模式
function M.profiles(self, section)
	local map = self.map
	local function one(sfx, label)
		local q = get(map, section, sfx .. "_quota")
		local p = get(map, section, sfx .. "_pool")
		local st
		if get(map, section, sfx .. "_unlimited") == "1" then
			st = label .. " " .. i18n.translate("不限额度")
		elseif q and q ~= "" then
			st = label .. " " .. q .. i18n.translate("分钟")
		elseif not (p and p ~= "") then
			st = label .. " " .. i18n.translate("不限")
		else
			-- 自己没填额度但挂了共享池：限制由池负责（与后端 pc_entry_unlimited 同一口径），
			-- 这里不能写「不限」，否则和实际的池限流互相矛盾。池名在下面统一补 @池名。
			st = label
		end
		-- 时段不是全天时附上，列表里一眼看出"只在几点到几点能用"
		local ws = get(map, section, sfx .. "_qstart")
		local we = get(map, section, sfx .. "_qend")
		if ws and we and ws ~= "" and we ~= "" and not (ws == "00:00:00" and we == "23:59:59") then
			st = st .. " " .. ws .. "-" .. we
		end
		if p and p ~= "" then st = st .. " @" .. p end
		return st
	end
	return one("sd", i18n.translate("平日")) .. "；" .. one("hd", i18n.translate("节假日"))
end

-- 列表里的「设备」列：MAC（已知设备名）；没填 MAC 就是全部客户端；填了静态IP 也一并显示
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
	return table.concat(out, " / ")
end

-- 列表页「重置」按钮的 key：统一模型下没有模式了，任何条目都能重置当天用量，
-- 所以恒返回 "<模块>_<下标>"（重置不限额度的条目也无害）。
function M.quota_key(self, section, typ)
	local idx = M.section_indexes(self.map, typ)[section]
	if idx == nil then return "" end
	return typ .. "_" .. idx
end

-- 今日额度（只对处于额度模式的条目有值；池成员显示池的合计）
-- 今日额度：不限额度 → 「不限」；否则「已用 / 额度 分钟」（额度 0 = 全禁，显示成 0/0）。
function M.used(self, section, typ)
	local u = M.usage_map()
	local i = M.section_indexes(self.map, typ)[section]
	local rec = i and u.by_key[typ .. "_" .. i]
	if not rec then return "-" end
	if rec.unlimited then return i18n.translate("不限") end
	if rec.quota > 0 then
		return string.format("%d / %d %s", rec.used, rec.quota, i18n.translate("分钟"))
	end
	return string.format("%d %s", rec.used, i18n.translate("分钟"))
end

return M
