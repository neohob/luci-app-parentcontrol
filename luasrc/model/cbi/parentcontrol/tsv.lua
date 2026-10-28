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
--   entry   <key> <module> <idx> <备注> <MAC 列表> <额度> <已用> <池> <本分钟KB> <不限额度>
--           （第 11k 轮 A94：第 5 字段从单个 mac 变为**逗号连接的 MAC 列表**（行序、去重、
--            空则空串）；它仍只是**一个** TSV 字段 —— 不含 Tab/换行，列数不变）
--   name    <key> <显示名> <on|off|gone>（完整模式才有：on/off/gone 的权威展示名单，A50/D34）
--   pool    <name> <quota> <used> <members,>
--   hist    <YYYYMMDD> <minutes>
--   histkey <YYYYMMDD> <key> <minutes>
--   reset   <YYYYMMDD> <HH:MM:SS> <key> <重置前已用分钟>
--   diag    <entry_key> <name> <mac> <ip> <hostname> <online> <today_minutes> <first> <last>
--   diagtgt <entry_key> <target> <today_minutes>
--   diagday <YYYYMMDD> <entry_key> <mac> <minutes>
--   diagdaytgt <YYYYMMDD> <entry_key> <target> <minutes>
--   appname <key> <行序号> <名称>
--           —— 一个条目里「封锁名称行」的显示名（行序号从 1 起，与 apps 行序/`pc_apps_rows`
--              一致；名称空的行已由 shell 回退成该行域名首项）。缺行（老 shell）=「无名称维度」。
--   appmap  <key> <行序号> <target>
--           —— 目标归属：行序号 0 = 未归类（目标不属于任何名称行，如换了 IP 的残留）；
--              同一目标只出现一次（多行命中时先出现的行胜）。缺行 = 无映射（D7 完全回退）。
function M.parse(raw)
	local d = {
		meta = {}, entries = {}, by_key = {}, pools = {},
		hist = {}, hist_key = {}, resets = {},
		-- 第 8 轮（R13/D19）：诊断明细三行
		diag = {}, diag_tgt = {}, diag_day = {},
		-- P-C/D2：目标 → 封锁名称行（旁路映射，老 shell 缺行 ⇒ 空表 ⇒ 行为完全回退 D7）
		app_names = {}, app_map = {}, diag_day_tgt = {},
		-- A50/D34：name 行的权威名单（key → { label, state }）。缺行（老 shell）时
		-- 保持空表 —— 下游回退「条目 #N」，永不裸 key，向后兼容。
		names = {},
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
			elseif k == "name" and f[2] then
				-- A50/D34 权威名单行：state ∈ {on, off, gone}；label 可为空串
				-- （无备注且无 apps 名），下游回退链对空串再退「条目 #N」。
				d.names[f[2]] = { label = f[3] or "", state = f[4] or "" }
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
			elseif k == "diag" then
				-- 缺字段一律容错：数值缺省 0、文本缺省空串（老日志/截断行不得让整页崩）
				d.diag[#d.diag + 1] = {
					key = f[2] or "", name = f[3] or "", mac = f[4] or "",
					ip = f[5] or "", hostname = f[6] or "",
					online = (f[7] == "1"), minutes = num(f[8]),
					first = f[9] or "", last = f[10] or "",
				}
			elseif k == "diagtgt" then
				d.diag_tgt[#d.diag_tgt + 1] = {
					key = f[2] or "", target = f[3] or "", minutes = num(f[4]),
				}
			elseif k == "diagday" then
				local dt = f[2]
				if dt then
					d.diag_day[dt] = d.diag_day[dt] or {}
					d.diag_day[dt][(f[3] or "") .. "|" .. (f[4] or "")] = num(f[5])
				end
			elseif k == "diagdaytgt" then
				local dt = f[2]
				local ky = f[3]
				if dt and ky then
					d.diag_day_tgt[dt] = d.diag_day_tgt[dt] or {}
					local per = d.diag_day_tgt[dt][ky]
					if not per then per = {}; d.diag_day_tgt[dt][ky] = per end
					per[f[4] or ""] = num(f[5])
				end
			elseif k == "appname" then
				local ky = f[2]
				if ky then
					d.app_names[ky] = d.app_names[ky] or {}
					d.app_names[ky][num(f[3])] = f[4] or ""
				end
			elseif k == "appmap" then
				local ky = f[2]
				if ky and f[4] and f[4] ~= "" then
					d.app_map[ky] = d.app_map[ky] or {}
					d.app_map[ky][f[4]] = num(f[3])
				end
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
