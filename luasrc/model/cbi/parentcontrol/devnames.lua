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

return M
