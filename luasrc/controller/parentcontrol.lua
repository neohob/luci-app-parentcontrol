module("luci.controller.parentcontrol", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/parentcontrol") then return end

        entry({"admin", "control"}, firstchild(), "Control", 44).dependent = false
	local e = entry({"admin","control","parentcontrol"},firstchild(),_("Parent Control"),2)
	e.dependent=false
	e.acl_depends = { "luci-app-parentcontrol" }
	entry({"admin","control","parentcontrol","time"},cbi("parentcontrol/time"),_("Time Control"),1).leaf=true
	entry({"admin", "control", "parentcontrol","weburl"}, cbi("parentcontrol/weburl"), _("Weburl Control"), 20).leaf = true
        entry({"admin", "control", "parentcontrol","protocol"}, cbi("parentcontrol/protocol"), _("Protocol Control"), 30).leaf = true 
	entry({"admin", "control", "parentcontrol","quota"}, cbi("parentcontrol/quota"), _("Usage Limit"), 40).leaf = true
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

-- 用量看板：实际计算在 shell 侧（/etc/init.d/parentcontrol usage_json），这里只转发。
function usage()
    local out = luci.sys.exec("/etc/init.d/parentcontrol usage_json 2>/dev/null")
    if not out or out == "" then
        out = '{"day":"","type":"","reset":"","issued":false,"items":[],"history":[]}'
    end
    luci.http.prepare_content("application/json")
    luci.http.write(out)
end
