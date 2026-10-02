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
	entry({"admin", "control", "parentcontrol","stats"}, cbi("parentcontrol/stats"), _("使用统计"), 45).leaf = true
	-- 各模块的「详细设置」独立页（列表行用 extedit 跳过来，section id 在 arg[1]）
	entry({"admin", "control", "parentcontrol","weburl_edit"}, cbi("parentcontrol/weburl_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","time_edit"}, cbi("parentcontrol/time_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","protocol_edit"}, cbi("parentcontrol/protocol_edit")).leaf = true
	entry({"admin", "control", "parentcontrol","status"}, call("status")).leaf = true
	entry({"admin", "control", "parentcontrol","reset_quota"}, call("reset_quota")).leaf = true
end

function status()
    local e = {}
    -- 网址过滤链在 mangle 表，时间/端口链在 filter 表，两个表都要查。
    -- 只判断「链是否存在」，不要求有匹配规则：开启状态下即使列表全空也应显示运行中。
    e.status = luci.sys.call("iptables -t mangle -S 2>/dev/null | grep -q PARENTCONTROL || iptables -S 2>/dev/null | grep -q PARENTCONTROL") == 0
    luci.http.prepare_content("application/json")
    luci.http.write_json(e)
end

-- 重置某条目/池今天的额度。key 必须严格匹配白名单（防 shell 注入）。
function reset_quota()
    -- 改状态的操作必须 POST + CSRF token：GET 会被跨站顶层导航触发
    -- （Lax cookie 会带上），导致额度被清零并写日志。
    if not require("luci.dispatcher").test_post_security() then return end
    local key = luci.http.formvalue("key") or ""
    local ok = false
    if key:match("^[a-z][a-z0-9_]*_[0-9]+$") or key:match("^pool:[A-Za-z0-9_.%-]+$") then
        ok = (luci.sys.call("/etc/init.d/parentcontrol reset_quota " .. key .. " >/dev/null 2>&1") == 0)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = ok, key = key })
end


