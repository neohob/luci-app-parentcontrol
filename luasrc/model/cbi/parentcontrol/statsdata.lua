-- 使用统计：读 shell 的 stats_tsv（解析走 tsv.lua），做分析，供看板模板渲染。
-- 本文件是被 require 的子模块 —— 不能用 LuCI 注入的全局（translate 等），必须显式 require。
local i18n = require "luci.i18n"
local tsv = require "luci.model.cbi.parentcontrol.tsv"
local devnames = require "luci.model.cbi.parentcontrol.devnames"

local M = {}

-- A94/第 11k 轮：`entry` 行的 MAC 字段现在是**逗号连接的 MAC 列表**（一条目多设备）。
-- 逐个映射设备名（无已知名的用 MAC 原样），以 ` / ` 连接；一个都没有则返回空串
-- （空串让模板的「未指定设备」兜底生效，也保证未绑设备的条目不进「按设备分析」）。
-- 诊断明细（diag 行）传单个 MAC 也走这里，行为不变（有名字用名字，否则原样 MAC）。
function M.device_name(mac)
	local out = {}
	for m in tostring(mac or ""):gmatch("[^,]+") do
		local t = m:gsub("^%s+", ""):gsub("%s+$", "")
		if t ~= "" then
			local n = devnames.name(t)
			out[#out + 1] = (n ~= "" and n or t)
		end
	end
	return table.concat(out, " / ")
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

-- D12 不变式守卫（F-R2-3）：真守卫，不是注释 —— 归约一旦与源数据对不上
-- （如重置被重复叠加、归约口径漂移），页面顶部给出可见标记并留系统日志，绝不静默输出错数。
-- 不变式共两条（第 6 轮 / design §16.1 删除了原 ③）：
--   ① Σ_day dev_day_rows[dev].by == dev_rows[dev].minutes（矩阵 vs 设备合计）
--   ② 台账合计 == Σ hist_key(窗口) + Σ 窗口内重置（台账是唯一源，不被二次计数；
--     第 2 轮复审的注入实验证明：只有②能在 r.before 翻倍时报警）
--
-- 关于被删除的 ③（同设备同日 Σ_条目 devkey[dev][*][day] == devmap[dev][day]）：
-- 它的两侧在 collect() 里同源归约（都由同一次 hist_key / ledger 遍历得出），一旦有人把两遍
-- 合并成一遍就恒等、永不可能报警；而合并是语义中性的。⇒ ③ 不是正确性护栏，而是内部形状
-- 护栏；内部形状只能用静态断言表达，静态断言又必然可伪造（第 5 轮复审 Major-4 用死循环实测
-- 绕过）。故按 design §16.2 A60 删除。③ 想防的真实 bug 类（子行丢数据）已由行为判据覆盖：
-- W204⑨（Σ 子行 == 设备行合计）/ W209（渲染）/ 真机 B137⑤⑥（页面数字对账）。
-- `d.devkey` 仍由调用点传入（W218③ 断言其在场），本函数不再读它 —— 供测试与将来扩展保留。
-- A38（第 4 轮 / review27）：抽成**纯函数**。判据文本与 collect() 内联版逐字相同，只把原来
-- 捕获的闭包局部表改成从参数 d 取（dev_rows / dev_days / days / ledger / dates /
-- hist_key / rrows；devkey 已随 ③ 不再读取，调用点仍传）。这样可以直接喂**人造矛盾数据**
-- 断言「报警器真的会响」（W215 行为用例），
-- 而不必再写「这段代码不是死的」这类不可证伪的静态断言 —— helper 抽取、等价假条件
-- （`if false and X then`）、字符串诱饵都已被复审实测证明能绕过后者。
-- 入参缺省一律按空表处理（空/半截输入返回 nil、不抛）；不写 d，不依赖全局。
function M.invariants(d)
	d = d or {}
	local dev_rows = d.dev_rows or {}
	local dev_days = d.dev_days or {}
	local days     = d.days     or {}
	local ledger   = d.ledger   or {}
	local dates    = d.dates    or {}
	local hist_key = d.hist_key or {}
	local rrows    = d.rrows    or {}
	local drift
	for _, row in ipairs(dev_rows) do
		local byday = dev_days[row.device]
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
	for _, day in ipairs(days) do
		for _, v in pairs(ledger[day.date] or {}) do total_ledger = total_ledger + v end
	end
	for _, dt in ipairs(dates) do
		for _, v in pairs(hist_key[dt] or {}) do total_source = total_source + v end
	end
	for _, r in ipairs(rrows) do total_source = total_source + r.before end
	if total_ledger ~= total_source then
		drift = (drift and (drift .. "; ") or "")
			.. "ledger=" .. total_ledger .. " != source=" .. total_source
	end
	return drift
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
	--    A50/D34：labels / dlabel 的构造 = d.entries（已启用）→ 再并入 d.names（含
	--    off/gone）—— 历史/重置里已停用、已删除的 key 也有名字。三处回退链
	--    （key_rows/reset_rows/诊断 entry）统一为
	--      dlabel[key] or (d.names[key] and d.names[key].label) or ("条目 #" .. (idx+1))
	--    绝不回退原始 key；stale 判据 = state ~= "on"（d.names 缺该 key 视为 stale）。
	local labels = {}
	for _, e in ipairs(d.entries) do labels[e.key] = e end
	for key, nm in pairs(d.names or {}) do
		if not labels[key] then labels[key] = { label = nm.label, state = nm.state } end
	end
	local dlabel = {}
	for _, e in ipairs(d.entries) do dlabel[e.key] = e.label end
	for key, nm in pairs(d.names or {}) do
		if not dlabel[key] then dlabel[key] = nm.label end
	end
	local dstate = {}
	for key, nm in pairs(d.names or {}) do dstate[key] = nm.state end
	-- key 形如 <module>_<idx>（idx 从 0 起）；兜底「条目 #<idx+1>」，解析失败「条目 #?」
	local function key_idx(key)
		return tonumber(select(2, key:match("^(%w+)_(%d+)$")))
	end
	-- A55/review11 Low-1：空串与 nil 同罪 —— dlabel/d.names 里存了空串时，`or` 链会
	-- 短路出空白名，压掉「条目 #N」兜底。nz() 把空串也视为缺失。
	local function nz(a, b)
		if a ~= nil and a ~= "" then return a end
		return b
	end
	for _, day in ipairs(d.days) do
		for key, v in pairs(ledger[day.date]) do
			d.key_totals[key] = (d.key_totals[key] or 0) + v
		end
	end
	local rows = {}
	for key, v in pairs(d.key_totals) do
		local e = labels[key]
		local _ix = key_idx(key)
		rows[#rows + 1] = {
			key = key,
			-- A50/D34 统一回退链（永不裸 key；A55：nz 让空串也回退，idx 解析失败退「条目 #?」）
			name = nz(dlabel[key], nz(d.names[key] and d.names[key].label,
				"条目 #" .. (_ix and _ix + 1 or "?"))),
			stale = (dstate[key] or "off") ~= "on",
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

	-- R3/A1：条目子行的展示名/停用态**复用** key_rows 同一份回退链（A50/D34 的 nz 链），
	-- 避免矩阵里另写一套导致「按设备+条目」与矩阵显示不一致。
	local kmeta = {}
	for _, r in ipairs(rows) do kmeta[r.key] = r end

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

	-- 6c) 设备 × 条目 × 日期：在 devmap 基础上再拆一层条目。口径与 devmap 完全一致
	--     （device ~= "" 才进表）。第二层归约漂移由测试侧 W204⑥⑦⑨ 承担。
	local devkey = {}
	for _, day in ipairs(d.days) do
		for key, v in pairs(ledger[day.date]) do
			local ent = labels[key]
			local dev = (ent and ent.device) or ""
			if dev ~= "" then
				local dk = devkey[dev]
				if not dk then dk = {}; devkey[dev] = dk end
				local kk = dk[key]
				if not kk then kk = {}; dk[key] = kk end
				kk[day.date] = (kk[day.date] or 0) + v
			end
		end
	end
	local kdrows = {}
	for _, dr in ipairs(ddrows) do
		local sub = devkey[dr.device] or {}
		local keys = {}
		for k, by in pairs(sub) do
			local t = 0
			for _, v in pairs(by) do t = t + v end
			keys[#keys + 1] = { key = k, total = t, by = by }
		end
		-- A1：设备内条目按 total 降序，并列按 key 升序（字符串序；key_rows 的比较器**无** key 兜底，见 design §12.4-3）
		table.sort(keys, function(a, b)
			if a.total ~= b.total then return a.total > b.total end
			return a.key < b.key
		end)
		-- A18/L5：单条目设备（nkey==1）没有可展开的子行，条目名必须**在行内**给出 ——
		-- 否则「每个设备要能看到它命中的每个条目（封锁名称）」在这个子集上不成立。
		-- 名字复用 key_rows 的同一份 kmeta 回退链（不另写一套，防两处显示分叉）。
		local only
		if #keys == 1 then
			local m1 = kmeta[keys[1].key]
			only = { name = m1 and m1.name or "（未知条目）",
				stale = (m1 and m1.stale) or false }
		end
		kdrows[#kdrows + 1] = { kind = "dev", device = dr.device,
			total = dr.total, nkey = #keys, by = dr.by, only = only }
		if #keys >= 2 then                      -- A3：单条目设备不产子行
			for _, k in ipairs(keys) do
				local m = kmeta[k.key]
				kdrows[#kdrows + 1] = { kind = "key", device = dr.device,
					key = k.key,
					-- A20/I1：回退链的最后一档**不许**是裸 key（`weburl_3` 之类内部
					-- 名字会漏到页面上）。kmeta 缺项时给可读占位，绝不回显 key。
					name = m and m.name or "（未知条目）",
					stale = (m and m.stale) or false,
					total = k.total, by = k.by }
			end
		end
	end
	d.dev_key_day_rows = kdrows

	-- D12 不变式守卫（F-R2-3）：真守卫，不是注释 —— 归约一旦与源数据对不上
	-- （如重置被重复叠加、归约口径漂移），页面顶部给出可见标记并留系统日志，
	-- 绝不静默输出错数。两条不变式：
	--   ① Σ_day dev_day_rows[dev].by == dev_rows[dev].minutes（矩阵 vs 设备合计）
	--   ② 台账合计 == Σ hist_key(窗口) + Σ 窗口内重置（台账是唯一源，不被二次计数；
	--     第 2 轮复审的注入实验证明：只有②能在 r.before 翻倍时报警）
	-- 原 ③（同设备同日 Σ_条目 devkey[dev][*][day] == devmap[dev][day]）已按 design §16.1
	-- 取消：它与 ① 同源归约、恒真不可证伪。其原覆盖类（第二层归约漂移，产品侧静默）
	-- 由测试侧 W204⑥⑦⑨ 承担 —— 那里才是这一类的真牙。
	-- A38：判据本体搬进 M.invariants(d)（纯函数，可喂人造数据做行为测试），这里只是一次调用。
	local drift = M.invariants({
		dev_rows = d.dev_rows, dev_days = devmap, devkey = devkey,
		days = d.days, ledger = ledger, dates = dates,
		hist_key = d.hist_key, rrows = rrows,
	})
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
		local _ix = key_idx(r.key)
		rr[#rr + 1] = {
			date = r.date, time = r.time, key = r.key,
			-- A50/D34 统一回退链（同 key_rows；A55：nz 让空串也回退，永不裸 key）
			name = nz(dlabel[r.key], nz(d.names[r.key] and d.names[r.key].label,
				"条目 #" .. (_ix and _ix + 1 or "?"))),
			stale = (dstate[r.key] or "off") ~= "on",
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

	-- 9) 诊断明细（第 8 轮 R13/D19/A24）：未被条目覆盖、但命中了条目目标的流量。
	--    行 = (条目, MAC)：按今日命中分钟降序；每行带 30 天按天合计（与 d.days 对齐、缺日补零）。
	--    目标列表**仅在**该条目只有一台未覆盖客户端有命中时内联；多台时标注「目标未区分设备」。
	-- 诊断区沿用上面的 dlabel/dstate（已并入权威名单 d.names，含 off/gone）。
	local tgt_by_key = {}
	for _, tg in ipairs(d.diag_tgt or {}) do
		tgt_by_key[tg.key] = tgt_by_key[tg.key] or {}
		local l = tgt_by_key[tg.key]
		l[#l + 1] = { target = tg.target, minutes = tg.minutes }
	end
	local drows = {}
	for _, r in ipairs(d.diag or {}) do
		local _ix = key_idx(r.key)
		local row = {
			key = r.key, mac = r.mac, ip = r.ip, hostname = r.hostname,
			online = r.online, minutes = r.minutes, first = r.first, last = r.last,
			-- D29/A36：名称一律取 stats_tsv 已解析的行内 name（remarks → apps 首项）；
			-- 条目已停用/已删除时仍有权威名单（dlabel 已并入 d.names）兜底，
			-- 只有行内 name 也为空才退「条目 #N」—— 诊断区永不出现 weburl_N 这类裸 key
			-- （行内 name 由 shell 三档回退保证非空；本链再对空串兜底，A57 前提）。
			-- A55：nz 让空串行内 name 也回退（shell 侧三档全空时不再渲染空白）。
			-- A43：行内 name 判空后再进 nz 链 —— Lua 的 and/or 返回操作数本身，子表达式
			-- (A and B) 为真时结果是布尔 true，会把字面量 true 渲染进页面。
			entry = (r.name ~= nil and r.name ~= "") and r.name
				or nz(dlabel[r.key], nz(d.names[r.key] and d.names[r.key].label,
					"条目 #" .. (_ix and _ix + 1 or "?"))),
			device = M.device_name(r.mac),
			days30 = {}, total30 = 0, by_date = {},
		}
		-- 条目已停用/已删除：其封锁规则已清理，但历史诊断计数仍保留（模板据此加注说明）。
		-- A50：判据改用权威名单的 state（off/gone → stale）；名单缺行（老数据源）视为启用。
		row.stale = ((dstate[r.key] or "on") ~= "on")
		local perday = (d.diag_day or {})
		for _, day in ipairs(d.days) do
			local v = (perday[day.date] or {})[r.key .. "|" .. r.mac] or 0
			row.days30[#row.days30 + 1] = { date = day.date, label = day.label, minutes = v }
			row.by_date[day.date] = v
			row.total30 = row.total30 + v
		end
		drows[#drows + 1] = row
	end
	table.sort(drows, function(x, y)
		if x.minutes ~= y.minutes then return x.minutes > y.minutes end
		return x.mac < y.mac
	end)
	local perkey = {}
	for _, r in ipairs(drows) do perkey[r.key] = (perkey[r.key] or 0) + 1 end
	for _, r in ipairs(drows) do
		if perkey[r.key] == 1 then
			r.targets = tgt_by_key[r.key] or {}
		else
			r.multi = true
		end
	end
	d.diag_rows = drows

	return d
end

return M
