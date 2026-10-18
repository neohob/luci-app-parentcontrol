-- MAC → 设备名（来自 DHCP 租约/ARP；丢掉 IP 兜底值，去掉 .lan/.local 后缀）。
-- 列表页(ui.lua)和看板(statsdata.lua)共用，别再各抄一份。
--
-- 第 11k-9 轮（A142 / D56）：采集抽成 _collect()，M.map() 与 M.hints() **共用一份**，
-- 收掉 review23 的 Low-1 / Low-2 / Low-3：
--   * Low-3：两处口径不同（map() 丢 IP 形态名并剥 .lan/.local，hints() 两者都不做）⇒
--     同一编辑页里「设备」列与下拉 label 会显示成两个样子。净化现在只在 _collect() 做一次。
--   * Low-2：pcall 只包了 require，没包 sys.net.mac_hints(cb) 的调用与回调 ⇒ 源抛错时
--     异常外泄、编辑页直接 500。现在错误包含覆盖到**回调执行**。
--   * Low-1：去重「先到者胜」让先到的空名吃掉后到的真实设备名 ⇒ 下拉 label 只剩裸 MAC。
--     现在空名让位（value 仍保留先到者的原样 MAC）。
local M = {}

-- 上限：租约表可能很长，避免把页面撑爆。只有 M.hints() 消费它（M.map() 不需要上限）。
local MAX_HINTS = 200

-- 名称净化（**唯一口径**）：空名 / 纯 IP 形态名（mac_hints 在缺 hostname 时会拿 IP 兜底）
-- 视为无名；再去掉 .lan / .local 后缀。返回 (净化名, 是否「可赋值」)。
-- 「可赋值」= 修前 M.map() 会把它写进 _names 的那些：name 非 nil 且不是 IP 形态。
-- 注意空串**算**可赋值（Lua 里 "" 为真，修前 `if mac and name` 会放行并写入 ""）。
local function _purify(name)
	if name == nil then return "", false end
	if name:match("^%d+%.%d+%.%d+%.%d+$") then return "", false end
	return (name:gsub("%.lan$", ""):gsub("%.local$", "")), true
end

-- 一次采集（全文件**唯一**一处 mac_hints 调用）：产出「按首次出现顺序」的去重数组
--   { { mac = 首次出现的原样 MAC, name = 首个非空净化名（空名让位）, mapname = 最后一次可赋值 } }
--  * mac 保留**原样**（hints 的 value 要原样回写用户系统里的形态，不做大小写归一）；
--  * name 供 M.hints() 用：**先到者胜，但空名让位** —— 修前 hints 是 first-wins，先到的空名
--    会吃掉后到的真名（review23 §Q7 的 Low-1）。故只在先到者 name == "" 时用后到的非空名
--    补齐（design §11.31.2 A142 做法 4），先到者非空则一律不动。
--  * mapname 取「最后一次可赋值」（含空串），供 M.map() 用 —— 修前 map 是 last-wins，
--    逐字节复现它必须保留「最后一次赋值」而不是「最后一个非空」（A142-2 硬门槛）。
--    两者只差在「先非空、后空串」与「两条都非空」这两种序上：map 永远跟最后一条（修前
--    行为），hints 永远跟先到的那条（修前行为）—— 即两边各自逐字节留在修前的语义上。
--  * pcall 覆盖 **回调执行**（Low-2）：源抛错不外泄；已采集到的部分保留（通常 0 条），
--    编辑页照常渲染而不是 500。
local _collected
local function _collect()
	if _collected then return _collected end
	local out, seen = {}, {}
	pcall(function()
		local ok_sys, sys = pcall(require, "luci.sys")
		if not (ok_sys and sys and sys.net and sys.net.mac_hints) then return end
		sys.net.mac_hints(function(mac, name)
			if not mac or mac == "" then return end
			local k = mac:lower()   -- 去重键：同一 MAC 可能在租约与 ARP 里各出现一次
			local clean, assignable = _purify(name)
			local e = seen[k]
			if not e then
				e = { mac = mac, name = clean, mapname = assignable and clean or nil }
				seen[k] = e
				out[#out + 1] = e
			else
				if assignable then e.mapname = clean end        -- M.map()：last-wins（含空串）
				if e.name == "" and clean ~= "" then e.name = clean end -- M.hints()：空名让位（先到者非空则不动）
			end
		end)
	end)
	_collected = out
	return out
end

-- MAC → 设备名（map）。用 mapname（最后一次可赋值）：与修前**逐字节一致** —— 修前对
-- nil 名 / IP 形态名根本不写入 _names，对空串却会写入 ""；`mapname ~= nil` 正好是这两条
-- 判定的复现（A142-2 硬门槛，含 map() 表的键集合）。
local _names
function M.map()
	if _names then return _names end
	_names = {}
	for _, e in ipairs(_collect()) do
		if e.mapname ~= nil then
			_names[e.mac:lower()] = e.mapname
		end
	end
	return _names
end

function M.name(mac)
	if not mac or mac == "" then return "" end
	return M.map()[mac:lower()] or ""
end

-- MAC 候选下拉数据（第 11k-8b 轮 A133-2/A138）：给「绑定设备」的 <datalist> 用。
-- **逻辑必须留在模型里**：clients_rows.htm 是视图模板，跑在 LuCI 的受限沙箱里；
-- `pcall` / `table.sort` 在视图沙箱里没有确凿先例（math.* 有，stats.htm 用过），
-- 若不在沙箱 env 里编辑页会直接 500，而宿主侧没有 lua、静态门也发现不了。
-- 模型模块经 require 加载、走 Lua 5.1 默认全局环境 —— _collect() 里
-- pcall(require, "luci.sys") 就是这个模式，且已在真机验证过。
local _hints
-- 契约（第 11k-10 轮 A152-I1）：返回值是**模块级 memo 的同一个表**（`_hints`）本身，不是副本 ——
-- 调用方**不得**写入 / 排序 / 裁剪它。当前两个消费方（`model/cbi/parentcontrol/ui.lua`、
-- `statsdata.lua`）都只读，且 LuCI 每个请求一个新 VM ⇒ 今天无实际污染；但别名写入会把污染
-- 带到本 VM 内的下一次调用（含并发的模板渲染）。要改编排请先复制一份再动。
-- 静态门也查不到别名写入（词法级防御不在本仓护栏预算内，`design.md §11.32.8`），所以这条靠
-- 注释 + 消费方只读约定，而不是靠断言。
function M.hints()
	if _hints then return _hints end
	local hints = {}
	for _, e in ipairs(_collect()) do
		hints[#hints + 1] = { mac = e.mac, name = e.name }
	end
	-- 排序：按小写 MAC 字典序（渲染稳定，便于真机对比；去重后小写键唯一 ⇒ 全序）
	table.sort(hints, function(a, b) return a.mac:lower() < b.mac:lower() end)
	-- 在模型内截断上限，消费方（视图）因此不需要 math.min
	if #hints > MAX_HINTS then
		local capped = {}
		for i = 1, MAX_HINTS do capped[i] = hints[i] end
		hints = capped
	end
	_hints = hints
	return hints
end

return M
