-- 使用统计：读 shell 的 stats_tsv（解析走 tsv.lua），做分析，供看板模板渲染。
-- 本文件是被 require 的子模块 —— 不能用 LuCI 注入的全局（translate 等），必须显式 require。
local i18n = require "luci.i18n"
local tsv = require "luci.model.cbi.parentcontrol.tsv"
local devnames = require "luci.model.cbi.parentcontrol.devnames"

local M = {}

function M.device_name(mac)
	return devnames.name(mac)
end

-- 日期递减：交给 os.time（取中午，避开夏令时边界），别再手写日历
local function prev_day(ymd)
	local y, m, d = ymd:match("^(%d%d%d%d)(%d%d)(%d%d)$")
	if not y then return nil end
	local t = os.time({
		year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12,
	})
	if not t then return nil end
	return os.date("%Y%m%d", t - 86400)
end

local function weekday_cn(ymd)
	local y, m, d = ymd:match("^(%d%d%d%d)(%d%d)(%d%d)$")
	if not y then return "" end
	local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
	local w = tonumber(os.date("%w", t))          -- 0=周日
	local cn = { "周日", "周一", "周二", "周三", "周四", "周五", "周六" }
	return cn[w + 1] or ""
end

-- 只用于显示：YYYYMMDD → YYYY-MM-DD（date 字段仍是历史文件键与排序键，两者并存）
local function date_iso(ymd)
	if not ymd then return "" end
	return (ymd:gsub("^(%d%d%d%d)(%d%d)(%d%d)$", "%1-%2-%3"))
end

-- 采集 + 分析
function M.collect()
	local d = tsv.read(false)
	d.reset_by_day = {}
	d.units, d.key_totals, d.dev_totals, d.days = {}, {}, {}, {}

	-- ---------- 分析 ----------
	local meta = d.meta
	local info = i18n.translate

	-- 1) 额度条目：剩余 / 百分比 / 状态 / 预测
	for _, e in ipairs(d.entries) do
		e.device = M.device_name(e.mac)
		e.label = (e.name ~= "" and e.name or (e.module .. "[" .. e.idx .. "]"))
		if e.device ~= "" then e.label2 = e.device end
		if not e.unlimited then
			e.remain = math.max(0, e.quota - e.used)
			e.pct = (e.quota > 0) and math.min(100, math.floor(e.used * 100 / e.quota)) or 0
			if e.used >= e.quota then
				e.status = info("已耗尽")
			else
				e.status = info("放行中")
			end
			-- 预测：额度按自然日（每天 0 点重置），用「当天已过分钟」线性外推
			local nh, nm = (meta.now or "00:00"):match("^(%d?%d):(%d%d)$")
			local elapsed = nh and (tonumber(nh) * 60 + tonumber(nm)) or 0
			if elapsed > 5 and e.used > 0 then
				e.projected = math.floor(e.used * 1440 / elapsed)
			end
		else
			-- 勾了「不限额度」：只判时段，额度不构成限制
			e.remain, e.pct, e.status = nil, 0, info("不限额度")
		end
	end

	-- 2) 「统计单元」：池算一次，私有额度按条目算一次（避免池成员重复计入合计）
	local pooled = {}
	for _, p in ipairs(d.pools) do
		pooled[p.name] = true
		local members = {}
		for m in (p.members or ""):gmatch("[^,]+") do members[#members + 1] = m end
		local pu = {
			name = p.name, kind = "pool", quota = p.quota, used = p.used,
			members = members, unlimited = p.unlimited,
		}
		if p.unlimited then
			-- 池没填额度 = 不限额（成员各自不受池约束，与后端 pc_entry_unlimited 同一口径）
			pu.pct, pu.remain, pu.status = 0, nil, info("不限额度")
		else
			pu.pct = (p.quota > 0) and math.min(100, math.floor(p.used * 100 / p.quota)) or 0
			pu.remain = math.max(0, p.quota - p.used)
			pu.status = (p.used >= p.quota) and info("已耗尽") or info("放行中")
		end
		d.units[#d.units + 1] = pu
	end
	for _, e in ipairs(d.entries) do
		if not (e.pool ~= "" and pooled[e.pool]) then
			d.units[#d.units + 1] = {
				name = e.label, device = e.device, kind = "entry", quota = e.quota,
				used = e.used, pct = e.pct, remain = e.remain, status = e.status,
				projected = e.projected, live_kb = e.live_kb, key = e.key,
				unlimited = e.unlimited,
			}
		end
	end

	-- 3) 最近 30 天窗口（补零），基于 meta.date 往前推
	local dates = {}
	local cur = meta.date and meta.date:gsub("-", "") or nil
	if cur then
		for _ = 1, 30 do
			dates[#dates + 1] = cur
			cur = prev_day(cur)
		end
	end
	table.sort(dates)

	-- shell 侧只按行数截取重置日志，30 天窗口由这里定义：
	-- 窗口外的重置不参与任何统计，也不出现在「重置记录」里。
	local inwin = {}
	for _, dt in ipairs(dates) do inwin[dt] = true end
	local rday, rrows = {}, {}
	for _, r in ipairs(d.resets) do
		if inwin[r.date] then
			rday[r.date] = (rday[r.date] or 0) + r.before
			rrows[#rrows + 1] = r
		end
	end
	d.reset_by_day, d.resets = rday, rrows

	-- 今日口径：当前用量 + 今日被重置掉的量（只加一次）
	local today_total = 0
	local today_quota = 0
	for _, u in ipairs(d.units) do
		today_total = today_total + (u.used or 0)
		if (u.quota or 0) > 0 then today_quota = today_quota + u.quota end
	end
	d.today_total = today_total
	d.today_quota = today_quota
	d.today_reset = (meta.date and d.reset_by_day[meta.date:gsub("-", "")]) or 0
	d.today_actual = today_total + d.today_reset

	-- D12 单源台账：(day × key) = hist_key 叠加窗口内重置，全文件唯一的分钟数推导。
	-- 不变式：Σ_day dev_day_rows[dev].by == dev_rows[dev].minutes；设备合计 == 条目合计。
	-- d.days / d.key_rows / d.dev_rows / d.dev_day_rows 全部只从本台账纯归约得出。
	local ledger, hist_seen = {}, {}
	for _, dt in ipairs(dates) do ledger[dt] = {} end
	for _, dt in ipairs(dates) do
		-- hist（当天总量）只取「有没有」这个存在位；分钟数一律由台账给出
		if d.hist[dt] ~= nil then hist_seen[dt] = true end
		local per = d.hist_key[dt]
		if per then
			hist_seen[dt] = true
			for key, v in pairs(per) do
				ledger[dt][key] = (ledger[dt][key] or 0) + v
			end
		end
	end
	for _, r in ipairs(rrows) do
		ledger[r.date][r.key] = (ledger[r.date][r.key] or 0) + r.before
	end

	-- 每天的分钟数 = 台账当日合计（含重置）；label 直接挂在条目上，
	-- 「按设备每日用量」矩阵表头直接遍历 d.days（不再单设独立的日期列投影）。
	local maxmin = 0
	for _, dt in ipairs(dates) do
		local minutes = 0
		for _, v in pairs(ledger[dt]) do minutes = minutes + v end
		if minutes > maxmin then maxmin = minutes end
		d.days[#d.days + 1] = {
			date = dt, date_iso = date_iso(dt), label = dt:sub(5, 6) .. "-" .. dt:sub(7, 8),
			minutes = minutes, weekday = weekday_cn(dt),
			reset = rday[dt] or 0, has = (hist_seen[dt] == true),
		}
	end
	d.days_max = maxmin

	-- 4) 历史汇总（与柱状图、按条目占比同一个 minutes 口径）
	local sum, cnt, mx = 0, 0, 0
	for _, day in ipairs(d.days) do
		if day.has or (day.reset or 0) > 0 then
			sum = sum + day.minutes
			cnt = cnt + 1
			if day.minutes > mx then mx = day.minutes end
		end
	end
	d.hist_sum = sum
	d.hist_days = cnt
	d.hist_avg = (cnt > 0) and math.floor(sum / cnt + 0.5) or 0
	d.hist_max = mx

	-- 5) 按条目（最近 30 天合计 + 占比）—— 台账按 key 归约（重置已在台账里，不再另加）
	--    R7：行带 device 维度，排序挪到 6) 之后按设备分组（见 devrank）
	local labels = {}
	for _, e in ipairs(d.entries) do labels[e.key] = e end
	for _, day in ipairs(d.days) do
		for key, v in pairs(ledger[day.date]) do
			d.key_totals[key] = (d.key_totals[key] or 0) + v
		end
	end
	local rows = {}
	for key, v in pairs(d.key_totals) do
		local e = labels[key]
		rows[#rows + 1] = {
			key = key,
			name = e and e.label or key,
			device = e and e.device or "",
			minutes = v,
			share = (sum > 0) and math.floor(v * 100 / sum + 0.5) or 0,
		}
	end

	-- 6) 按设备（把该设备下各条目 30 天用量相加；设备口径：能映射到设备名 device ~= ""）
	for _, r in ipairs(rows) do
		local dev = r.device or ""
		if dev ~= "" then
			d.dev_totals[dev] = (d.dev_totals[dev] or 0) + r.minutes
		end
	end
	local drows = {}
	for dev, v in pairs(d.dev_totals) do
		drows[#drows + 1] = { device = dev, minutes = v,
			share = (sum > 0) and math.floor(v * 100 / sum + 0.5) or 0 }
	end
	table.sort(drows, function(a, b) return a.minutes > b.minutes end)
	d.dev_rows = drows

	-- R7：key_rows 按设备分组排序 —— 设备顺序沿用 dev_rows（30 天用量多者在前），
	-- 组内按条目分钟降序；映射不到设备名（device == ""）的条目整体排最后。
	-- 纯归约：只重排上面的 rows，不动台账、不动数据源口径，也不动 D12 守卫。
	local devrank = {}
	for i, dr in ipairs(drows) do devrank[dr.device] = i end
	table.sort(rows, function(x, y)
		local rx = x.device ~= "" and devrank[x.device] or math.huge
		local ry = y.device ~= "" and devrank[y.device] or math.huge
		if rx ~= ry then return rx < ry end
		return x.minutes > y.minutes
	end)
	d.key_rows = rows

	-- 6b) 按设备每日矩阵：台账按 (设备, day) 归约；设备判定与「按设备分析」同一口径
	--     （能映射到设备名 device ~= "" 的条目才进表，与上面 dev_totals 完全一致）。
	local devmap = {}
	for _, day in ipairs(d.days) do
		for key, v in pairs(ledger[day.date]) do
			local ent = labels[key]
			local dev = (ent and ent.device) or ""
			if dev ~= "" then
				devmap[dev] = devmap[dev] or {}
				devmap[dev][day.date] = (devmap[dev][day.date] or 0) + v
			end
		end
	end
	d.dev_days = devmap
	local ddrows = {}
	for dev, by in pairs(devmap) do
		local total = 0
		for _, v in pairs(by) do total = total + v end
		ddrows[#ddrows + 1] = { device = dev, total = total, by = by }
	end
	table.sort(ddrows, function(x, y)
		if x.total ~= y.total then return x.total > y.total end
		return x.device < y.device
	end)
	d.dev_day_rows = ddrows

	-- D12 不变式守卫（F-R2-3）：真守卫，不是注释 —— 归约一旦与源数据对不上
	-- （如重置被重复叠加、归约口径漂移），页面顶部给出可见标记并留系统日志，
	-- 绝不静默输出错数。两条不变式：
	--   ① Σ_day dev_day_rows[dev].by == dev_rows[dev].minutes（矩阵 vs 设备合计）
	--   ② 台账合计 == Σ hist_key(窗口) + Σ 窗口内重置（台账是唯一源，不被二次计数；
	--     第 2 轮复审的注入实验证明：只有②能在 r.before 翻倍时报警）
	local drift
	for _, row in ipairs(d.dev_rows) do
		local byday = devmap[row.device]
		local total = 0
		if byday then
			for _, v in pairs(byday) do total = total + v end
		end
		if total ~= row.minutes then
			drift = (drift and (drift .. "; ") or "")
				.. row.device .. " matrix=" .. total .. " != rows=" .. row.minutes
		end
	end
	local total_ledger, total_source = 0, 0
	for _, day in ipairs(d.days) do
		for _, v in pairs(ledger[day.date]) do total_ledger = total_ledger + v end
	end
	for _, dt in ipairs(dates) do
		for _, v in pairs(d.hist_key[dt] or {}) do total_source = total_source + v end
	end
	for _, r in ipairs(rrows) do total_source = total_source + r.before end
	if total_ledger ~= total_source then
		drift = (drift and (drift .. "; ") or "")
			.. "ledger=" .. total_ledger .. " != source=" .. total_source
	end
	if drift then
		d.invariant_drift = drift
		pcall(function()
			(require "luci.sys").log("parentcontrol: D12 invariant drift: " .. drift)
		end)
	end

	-- 7) 重置记录（倒序，带条目名与设备名）
	local rr = {}
	for _, r in ipairs(d.resets) do
		local e = labels[r.key]
		rr[#rr + 1] = {
			date = r.date, time = r.time, key = r.key,
			name = e and e.label or r.key,
			device = e and e.device or "",
			before = r.before,
		}
	end
	table.sort(rr, function(a, b)
		if a.date ~= b.date then return a.date > b.date end
		return a.time > b.time
	end)
	while #rr > 60 do table.remove(rr) end
	d.reset_rows = rr

	return d
end

return M
