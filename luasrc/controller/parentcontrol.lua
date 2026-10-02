module("luci.controller.parentcontrol", package.seeall)

local util = require "luci.util"

function index()
    if not nixio.fs.access("/etc/config/parentcontrol") then return end

        entry({"admin", "control"}, firstchild(), "管控", 44).dependent = false
	local e = entry({"admin","control","parentcontrol"},firstchild(),_("家长控制"),2)
	e.dependent=false
	e.acl_depends = { "luci-app-parentcontrol" }
	entry({"admin","control","parentcontrol","time"},cbi("parentcontrol/time"),_("时间限制"),1).leaf=true
	entry({"admin", "control", "parentcontrol","weburl"}, cbi("parentcontrol/weburl"), _("网址过滤"), 20).leaf = true
        entry({"admin", "control", "parentcontrol","protocol"}, cbi("parentcontrol/protocol"), _("协议过滤"), 30).leaf = true 
	entry({"admin", "control", "parentcontrol","quota"}, cbi("parentcontrol/quota"), _("使用限额"), 40).leaf = true
	-- 各模块的「详细设置」独立页（列表行用 extedit 跳过来，section id 在 arg[1]）
	entry({"admin", "control", "parentcontrol","weburl_edit"}, cbi("parentcontrol/weburl_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","time_edit"}, cbi("parentcontrol/time_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","protocol_edit"}, cbi("parentcontrol/protocol_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","status"}, call("status")).leaf = true
	entry({"admin", "control", "parentcontrol","usage"}, call("usage")).leaf = true
end

function status()
    local e = {}
    -- 网址过滤链在 mangle 表，时间/端口链在 filter 表，两个表都要查。
    -- 只判断「链是否存在」，不要求有匹配规则：开启状态下即使列表全空也应显示运行中。
    e.status = luci.sys.call("iptables -t mangle -S 2>/dev/null | grep -q PARENTCONTROL || iptables -S 2>/dev/null | grep -q PARENTCONTROL") == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

-- 用量看板：shell 只输出 TSV（/etc/init.d/parentcontrol usage_tsv），JSON 在 Lua 侧组装
-- （写入交给 write_json，转义由框架处理）。
function usage()
    local out = luci.sys.exec("/etc/init.d/parentcontrol usage_tsv 2>/dev/null") or ""
    local res = { day = "", type = "", reset = "", issued = false, items = {}, history = {} }
    for _, line in ipairs(util.split(out, "\n")) do
        if line ~= "" then
            local f = util.split(line, "\t")
            if f[1] == "day" then
                res.day, res.type, res.reset, res.issued = f[2], f[3], f[4], (f[5] == "1")
            elseif f[1] == "item" then
                res.items[#res.items + 1] = { name = f[2], used = tonumber(f[3]) or 0, quota = tonumber(f[4]) or 0 }
            elseif f[1] == "history" then
                res.history[#res.history + 1] = { date = f[2], minutes = tonumber(f[3]) or 0 }
            end
        end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(res)
end
