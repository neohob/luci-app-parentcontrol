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
--   appmap  <key> <行序号> <target>
--           —— 目标 → 名称行号（0 = 未归类）。第 1 轮引入、round66 L-7 删掉过（当时 Lua 侧
--              不需要它），**round74（R74-C）重新解析**：「（未归类）」行要展开到具体目标，
--              所需的目标集合只存在于这一行里（`.map` 只由 shell 读，Lua 拿不到）。
--   diagdaytgt <YYYYMMDD> <key> <target> <minutes>
--           —— 同上，按天×目标的分钟（R74-C 一起恢复解析）。
--   asn     <target> <asn> <org>
--           —— R74-A：Team Cymru 机械 ASN。**只在 `stats_tsv asn <target>…`（用户点开明细）
--              时输出**，默认 stats_tsv 的首屏输出里一行都没有（D1：不在 tick/首屏路径查询）。
--              org 可为空串（没查到 / IPv6 未查询）；asn 空串即「无归属信息」。
--   appname <key> <行序号> <名称>
--           —— 一个条目里「封锁名称行」的显示名（行序号从 1 起，与 apps 行序/`pc_apps_rows`
--              一致；名称空的行已由 shell 回退成该行域名首项）。缺行（老 shell）=「无名称维度」。
--   diagntoday  <key> <行序号> <minutes>
--           —— D9/D1-v2（第 2 轮）：**今天**该名称行的分钟数。由采样侧「按名称按 tick
--              记一次」写成（同一 tick 内同一名称只 +1，不再把名下多个目标的分钟相加）。
--              行序号 0 = 未归类。缺行（老 shell / 升级前的日文件）= 该天名称列显示 `-`。
--   diagdayname <YYYYMMDD> <key> <行序号> <minutes>
--           —— 同上口径的历史日分钟（30 天窗口）。缺行同样是 `-`，不是 0。
function M.parse(raw)
	local d = {
		meta = {}, entries = {}, by_key = {}, pools = {},
		hist = {}, hist_key = {}, resets = {},
		-- 第 8 轮（R13/D19）：诊断明细三行
		diag = {}, diag_tgt = {}, diag_day = {},
		-- P-C/D2：名称子行的文案（缺行 = 无名称维度，D7 完全回退）
		app_names = {},
		-- D9/D1-v2（第 2 轮）：名称维度的分钟（今天 / 历史日），采样侧写的 n 行
		diag_n_today = {}, diag_day_name = {},
		-- R74-C：目标 → 名称行号（0 = 未归类）与按天×目标的分钟（「（未归类）」明细用）
		app_map = {}, diag_day_tgt = {},
		-- R74-A：<target> → { asn = "20940", org = "AKAMAI-ASN1, NL" }（只在点开明细时才有）
		asn = {},
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
			elseif k == "appname" then
				local ky = f[2]
				if ky then
					d.app_names[ky] = d.app_names[ky] or {}
					d.app_names[ky][num(f[3])] = f[4] or ""
				end
			elseif k == "diagntoday" then
				local ky = f[2]
				if ky then
					d.diag_n_today[ky] = d.diag_n_today[ky] or {}
					d.diag_n_today[ky][num(f[3])] = num(f[4])
				end
			elseif k == "diagdayname" then
				local ky = f[3]
				local dt = f[2]
				if dt and ky then
					d.diag_day_name[dt] = d.diag_day_name[dt] or {}
					local per = d.diag_day_name[dt][ky]
					if not per then per = {}; d.diag_day_name[dt][ky] = per end
					per[num(f[4])] = num(f[5])
				end
			elseif k == "appmap" then
				-- R74-C：<key> <行序号> <target> ⇒ d.app_map[key][target] = nr
				local ky = f[2]
				if ky and f[4] then
					d.app_map[ky] = d.app_map[ky] or {}
					d.app_map[ky][f[4]] = num(f[3])
				end
			elseif k == "diagdaytgt" then
				-- R74-C：<YYYYMMDD> <key> <target> <分钟> ⇒ d.diag_day_tgt[dt][key.."|"..target]
				local dt = f[2]
				if dt and f[3] and f[4] then
					d.diag_day_tgt[dt] = d.diag_day_tgt[dt] or {}
					d.diag_day_tgt[dt][f[3] .. "|" .. f[4]] = num(f[5])
				end
			elseif k == "asn" then
				-- R74-A：<target> <asn> <org>（org 可为空串；asn 空串 = 无归属信息）
				if f[2] then d.asn[f[2]] = { asn = f[3] or "", org = f[4] or "" } end
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

-- R74-A：只查这几个目标的 ASN（用户点开「（未归类）」明细时才调用）。
-- 返回 <target> → { asn, org }；查询失败/IPv6/未查到都是空串，**绝不在 Lua 侧臆造**。
function M.read_asn(targets)
	local list = targets or {}
	if #list == 0 then return {} end
	local q = {}
	for _, t in ipairs(list) do
		-- 目标串来自本地映射文件，仍按不可信处理：单引号吃掉外层引号、去掉换行。
		local s = tostring(t):gsub("[\r\n]", ""):gsub("'", "")
		if s ~= "" then q[#q + 1] = "'" .. s .. "'" end
	end
	if #q == 0 then return {} end
	local d = M.parse(sys.exec("/etc/init.d/parentcontrol stats_tsv asn "
		.. table.concat(q, " ") .. " 2>/dev/null") or "")
	return d.asn or {}
end

return M
