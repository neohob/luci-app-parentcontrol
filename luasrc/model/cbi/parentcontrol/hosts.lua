-- 绑定健康（第 8 轮 R10/D18/ADR-021）：LAN 在网设备清单，来自 shell 的 hosts_tsv 子命令。
-- 请求级缓存：一个请求里编辑页/列表页多处读也只跑一次 shell（页面刷新即失效）。
-- 注意：本文件是被 require 的子模块，不能用 LuCI 注入的全局（translate 等），必须显式 require。
local sys = require "luci.sys"

local M = {}

local _list
local _map

local function load()
	if _list then return end
	_list, _map = {}, {}
	local out = sys.exec("/etc/init.d/parentcontrol hosts_tsv 2>/dev/null") or ""
	for line in out:gmatch("[^\n]+") do
		-- shell 侧固定 5 个空格分隔字段：host <mac> <ip> <name> <online>（缺项以 - 占位）
		local kind, mac, ip, name, online =
			line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
		if kind == "host" and mac then
			local h = {
				mac = mac:lower(),
				ip = (ip ~= "-" and ip or ""),
				name = (name ~= "-" and name or ""),
				online = (online == "1"),
			}
			_list[#_list + 1] = h
			if not _map[h.mac] then _map[h.mac] = h end
		end
	end
end

-- 全部「当前/最近在网」设备（含只在 DHCP 租约里的，online=false）。
-- 顺序 = hosts_tsv 的输出顺序（邻居表在前、只在租约里的在后）。
function M.list()
	load()
	return _list
end

-- 某 MAC 是否在网：true / false；nil = 无从判断（MAC 为空 = 该条目没绑设备）。
-- 不在清单里（既不在邻居表、也没有租约）按「不在网」处理 —— 正是绑定失效的典型形态。
function M.online(mac)
	if not mac or mac == "" then return nil end
	load()
	local h = _map[mac:lower()]
	if not h then return false end
	return h.online
end

return M
