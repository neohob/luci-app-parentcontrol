-- stats_tsv 的唯一解析器 —— 列定义（契约）只在这里写一次。
-- 列表页(ui.lua)与看板(statsdata.lua)都必须走这里：两边各按下标解析过一次，
-- 结果就是 shell 侧改了列之后其中一个漏改、整列静默显示错值（显示 "-" 或错位的数字）。
local sys = require "luci.sys"
local util = require "luci.util"

local M = {}

local function num(s, def)
	local n = tonumber(s)
	if n == nil then return def or 0 end
	return n
end

-- 列定义（与 root/etc/init.d/parentcontrol 的 stats_tsv printf 一一对应）：
--   meta    <date> <daytype> <min_kb> <keep> <now>
--   entry   <key> <module> <idx> <备注> <mac> <额度> <已用> <池> <本分钟KB> <不限额度>
--   pool    <name> <quota> <used> <members,>
--   hist    <YYYYMMDD> <minutes>
--   histkey <YYYYMMDD> <key> <minutes>
--   reset   <YYYYMMDD> <HH:MM:SS> <key> <重置前已用分钟>
function M.parse(raw)
	local d = {
		meta = {}, entries = {}, by_key = {}, pools = {},
		hist = {}, hist_key = {}, resets = {},
	}
	for _, line in ipairs(util.split(raw or "", "\n")) do
		if line ~= "" then
			local f = util.split(line, "\t")
			local k = f[1]
			if k == "meta" then
				d.meta = {
					date = f[2], daytype = f[3], min_kb = num(f[4], 8),
					keep = num(f[5], 90), now = f[6] or "",
				}
			elseif k == "entry" then
				local e = {
					key = f[2], module = f[3], idx = f[4], name = f[5] or "", mac = f[6] or "",
					quota = num(f[7]), used = num(f[8]), pool = f[9] or "",
					live_kb = num(f[10]), unlimited = (f[11] == "1"),
				}
				d.entries[#d.entries + 1] = e
				if e.key then d.by_key[e.key] = e end
			elseif k == "pool" then
				-- 池额度空串 = 没填 = 不限（注意 entry 行不同：额度 0 是显式的“一分钟都不给”）
				d.pools[#d.pools + 1] = {
					name = f[2], quota = num(f[3]), used = num(f[4]), members = f[5] or "",
					unlimited = (f[3] == nil or f[3] == ""),
				}
			elseif k == "hist" then
				d.hist[f[2]] = num(f[3])
			elseif k == "histkey" then
				local dt = f[2]
				d.hist_key[dt] = d.hist_key[dt] or {}
				d.hist_key[dt][f[3]] = num(f[4])
			elseif k == "reset" then
				d.resets[#d.resets + 1] = {
					date = f[2], time = f[3], key = f[4], before = num(f[5]),
				}
			end
		end
	end
	return d
end

-- 跑 shell 并解析。brief=true 只取 meta+entry（列表页够用，跳过历史/池/计数器）。
function M.read(brief)
	local cmd = "/etc/init.d/parentcontrol stats_tsv"
		.. (brief and " brief" or "") .. " 2>/dev/null"
	return M.parse(sys.exec(cmd) or "")
end

return M
