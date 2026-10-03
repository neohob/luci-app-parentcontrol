-- 使用统计：读 shell 的 stats_tsv，解析并做分析，供看板模板渲染。
-- 本文件是被 require 的子模块 —— 不能用 LuCI 注入的全局（translate 等），必须显式 require。
local i18n = require "luci.i18n"
local sys = require "luci.sys"
local util = require "luci.util"
local devnames = require "luci.model.cbi.parentcontrol.devnames"

local M = {}

local function num(s, def)
	local n = tonumber(s)
	if n == nil then return def or 0 end
	return n
end

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

-- 采集 + 分析
function M.collect()
	local raw = sys.exec("/etc/init.d/parentcontrol stats_tsv 2>/dev/null") or ""
	local d = {
		meta = {}, entries = {}, pools = {}, hist = {}, hist_key = {},
		resets = {}, reset_by_day = {}, reset_by_key = {},
		units = {}, key_totals = {}, dev_totals = {}, days = {},
	}
	for _, line in ipairs(util.split(raw, "\n")) do
		if line ~= "" then
			local f = util.split(line, "\t")
			local k = f[1]
			if k == "meta" then
				d.meta = {
					date = f[2], daytype = f[3],
					min_kb = num(f[4], 8), keep = num(f[5], 90), now = f[6] or "",
				}
			elseif k == "entry" then
				d.entries[#d.entries + 1] = {
					key = f[2], module = f[3], idx = f[4], name = f[5] or "",
					mac = f[6] or "", mode = f[7] or "", quota = num(f[8]),
					used = num(f[9]), pool = f[10] or "", live_kb = num(f[11]),
					unlimited = (f[12] == "1"),
				}
			elseif k == "pool" then
				d.pools[#d.pools + 1] = {
					name = f[2], quota = num(f[3]), used = num(f[4]), members = f[5] or "",
				}
			elseif k == "hist" then
				d.hist[f[2]] = num(f[3])
			elseif k == "reset" then
				local dt, tm, key, before = f[2], f[3], f[4], num(f[5])
				d.resets[#d.resets + 1] = { date = dt, time = tm, key = key, before = before }
				d.reset_by_day[dt] = (d.reset_by_day[dt] or 0) + before
				d.reset_by_key[key] = (d.reset_by_key[key] or 0) + before
			elseif k == "histkey" then
				local dt, key = f[2], f[3]
				d.hist_key[dt] = d.hist_key[dt] or {}
				d.hist_key[dt][key] = num(f[4])
			end
		end
	end

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
		d.units[#d.units + 1] = {
			name = p.name, kind = "pool", quota = p.quota, used = p.used,
			members = members, pct = (p.quota > 0) and math.min(100, math.floor(p.used * 100 / p.quota)) or 0,
			remain = math.max(0, p.quota - p.used),
			status = (p.quota > 0 and p.used >= p.quota) and info("已耗尽") or info("放行中"),
		}
	end
	for _, e in ipairs(d.entries) do
		if not (e.pool ~= "" and pooled[e.pool]) then
			d.units[#d.units + 1] = {
				name = e.label, device = e.device, kind = "entry", quota = e.quota,
				used = e.used, pct = e.pct, remain = e.remain, status = e.status,
				projected = e.projected, live_kb = e.live_kb, key = e.key,
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
	local rday, rkey, rrows = {}, {}, {}
	for _, r in ipairs(d.resets) do
		if inwin[r.date] then
			rday[r.date] = (rday[r.date] or 0) + r.before
			rkey[r.key] = (rkey[r.key] or 0) + r.before
			rrows[#rrows + 1] = r
		end
	end
	d.reset_by_day, d.reset_by_key, d.resets = rday, rkey, rrows

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

	-- 每天的分钟数只有一个口径：历史文件用量 + 当天被重置掉的量
	local maxmin = 0
	for _, dt in ipairs(dates) do
		local rst = d.reset_by_day[dt] or 0
		local v = (d.hist[dt] or 0) + rst
		if v > maxmin then maxmin = v end
		d.days[#d.days + 1] = {
			date = dt, minutes = v, weekday = weekday_cn(dt),
			reset = rst, has = (d.hist[dt] ~= nil),
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

	-- 5) 按条目（最近 30 天合计 + 占比）
	local labels = {}
	for _, e in ipairs(d.entries) do labels[e.key] = e end
	for _, day in ipairs(d.days) do
		local per = d.hist_key[day.date]
		if per then
			for key, v in pairs(per) do
				d.key_totals[key] = (d.key_totals[key] or 0) + v
			end
		end
	end
	for key, v in pairs(d.reset_by_key) do
		d.key_totals[key] = (d.key_totals[key] or 0) + v
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
	table.sort(rows, function(a, b) return a.minutes > b.minutes end)
	d.key_rows = rows

	-- 6) 按设备（把该设备下各条目 30 天用量相加）
	for _, r in ipairs(rows) do
		local dev = (r.device ~= "" and r.device) or nil
		if dev then
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
