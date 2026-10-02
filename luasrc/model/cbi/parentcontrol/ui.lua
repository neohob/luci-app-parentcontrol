-- 列表页的只读展示助手：档案摘要、今日额度。
-- 注意：本文件是被 require 的子模块，LuCI 注入的全局（translate 等）在这里不可用，
-- 必须显式 require。
local i18n = require "luci.i18n"
local sys = require "luci.sys"
local util = require "luci.util"
local devnames = require "luci.model.cbi.parentcontrol.devnames"

local M = {}

-- 每请求缓存一次 stats_tsv brief 的结果（列表页只要 meta + entry 两行，不跑历史/计数器）
local _usage
function M.usage_map()
	if _usage then return _usage end
	_usage = {}
	local out = sys.exec("/etc/init.d/parentcontrol stats_tsv brief 2>/dev/null") or ""
	for _, line in ipairs(util.split(out, "\n")) do
		local f = util.split(line, "\t")
		if f[1] == "meta" then
			_usage.day = { day = f[2], type = f[3], reset = f[4], issued = (f[5] == "1") }
		elseif f[1] == "entry" then
			-- entry: key module idx 备注 mac 模式 额度 已用 池 本分钟KB
			_usage[f[2]] = {
				mode = f[6] or "", quota = tonumber(f[7]) or 0, used = tonumber(f[8]) or 0,
			}
		end
	end
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
		local mode = get(map, section, sfx .. "_mode") or "time"
		if mode == "off" then
			return label .. " " .. i18n.translate("关闭")
		elseif mode == "quota" then
			local q = get(map, section, sfx .. "_quota")
			local p = get(map, section, sfx .. "_pool")
			local st = label .. " " .. (q and (q .. i18n.translate("分钟")) or i18n.translate("不限"))
			if p and p ~= "" then st = st .. " @" .. p end
			return st
		else
			local s = get(map, section, sfx .. "_start") or "00:00"
			local e = get(map, section, sfx .. "_end") or "00:00"
			if s == e then return label .. " " .. i18n.translate("全天封") end
			return label .. " " .. s .. "-" .. e
		end
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

-- 今天该条目是不是「每日额度」模式：是则返回 "<模块>_<下标>"，否则返回 ""
function M.quota_key(self, section, typ)
	local sfx = ((M.usage_map().day or {}).type == "holiday") and "hd" or "sd"
	local mode = self.map:get(section, sfx .. "_mode") or "time"
	if mode ~= "quota" then return "" end
	local idx = M.section_indexes(self.map, typ)[section]
	if idx == nil then return "" end
	return typ .. "_" .. idx
end

-- 今日额度（只对处于额度模式的条目有值；池成员显示池的合计）
function M.used(self, section, typ)
	local u = M.usage_map()
	local i = M.section_indexes(self.map, typ)[section]
	local rec = i and u[typ .. "_" .. i]
	if not rec or rec.mode ~= "quota" then return "-" end
	if rec.quota > 0 then
		return string.format("%d / %d %s", rec.used, rec.quota, i18n.translate("分钟"))
	end
	return string.format("%d %s", rec.used, i18n.translate("分钟"))
end

return M
