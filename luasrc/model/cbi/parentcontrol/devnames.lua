-- MAC → 设备名（来自 DHCP 租约/ARP；丢掉 IP 兜底值，去掉 .lan/.local 后缀）。
-- 列表页(ui.lua)和看板(statsdata.lua)共用，别再各抄一份。
local M = {}

local _names
function M.map()
	if _names then return _names end
	_names = {}
	local ok, sys = pcall(require, "luci.sys")
	if ok and sys.net and sys.net.mac_hints then
		sys.net.mac_hints(function(mac, name)
			if mac and name and not name:match("^%d+%.%d+%.%d+%.%d+$") then
				_names[mac:lower()] = (name:gsub("%.lan$", ""):gsub("%.local$", ""))
			end
		end)
	end
	return _names
end

function M.name(mac)
	if not mac or mac == "" then return "" end
	return M.map()[mac:lower()] or ""
end

-- MAC 候选下拉数据（第 11k-8b 轮）：给「绑定设备」的 <datalist> 用。
-- **逻辑必须留在模型里**：clients_rows.htm 是视图模板，跑在 LuCI 的受限沙箱里；
-- `pcall` / `table.sort` 在视图沙箱里没有确凿先例（math.* 有，stats.htm 用过），
-- 若不在沙箱 env 里编辑页会直接 500，而宿主侧没有 lua、静态门也发现不了。
-- 模型模块经 require 加载、走 Lua 5.1 默认全局环境 —— 上面 M.map() 的
-- pcall(require, "luci.sys") 就是这个模式，且已在真机验证过。
local MAX_HINTS = 200   -- 上限：租约表可能很长，避免把页面撑爆

local _hints
function M.hints()
	if _hints then return _hints end
	_hints = {}
	local seen = {}
	local ok_sys, sys = pcall(require, "luci.sys")
	if ok_sys and sys and sys.net and sys.net.mac_hints then
		sys.net.mac_hints(function(mac, name)
			if not mac or mac == "" then return end
			local k = mac:lower()   -- 去重：同一 MAC 可能在租约与 ARP 里各出现一次
			if seen[k] then return end
			seen[k] = true
			_hints[#_hints + 1] = { mac = mac, name = name or "" }
		end)
	end
	-- 排序：按小写 MAC 字典序（渲染稳定，便于真机对比；去重后小写键唯一 ⇒ 全序）
	table.sort(_hints, function(a, b) return a.mac:lower() < b.mac:lower() end)
	-- 在模型内截断上限，消费方（视图）因此不需要 math.min
	if #_hints > MAX_HINTS then
		local out = {}
		for i = 1, MAX_HINTS do out[i] = _hints[i] end
		_hints = out
	end
	return _hints
end

return M
