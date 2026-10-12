-- 网址条目的详细设置页（从列表页的「编辑」按钮进入，section id 在 arg[1]）
local o = require "luci.sys"
local disp = require "luci.dispatcher"
local parts = require "luci.model.cbi.parentcontrol.parts"

if not arg[1] then
	luci.http.redirect(disp.build_url("admin", "control", "parentcontrol", "weburl"))
	return
end

local a, t, e
a = Map("parentcontrol", translate("编辑网址条目"),
	translate("平日 / 节假日 两套档案各自设<b>可用时段</b>+<b>每日额度</b>。</br><b>可用时段</b>内才能使用（默认全天 00:00:00-23:59:59；不跨日，起必须早于止），时段外的流量直接被丢弃、<b>不计入额度</b>；时段内累计用满额度也会被封。</br>勾 <b>不限额度</b> 就只受时段限制（额度框会消失）。额度 <b>0</b> = 一分钟都不给（全禁）。额度按自然日、每天 0 点重置，可填共享组名并入额度池。"))
a.redirect = disp.build_url("admin", "control", "parentcontrol", "weburl")
a.template = "parentcontrol/edit"

if not a:get(arg[1]) then
	luci.http.redirect(a.redirect)
	return
end

t = a:section(NamedSection, arg[1], "weburl")
t.addremove = false

t:option(Value, "remarks", translate("备注"))

e = t:option(Value, "mac", translate("MAC地址"))
e.rmempty = true
o.net.mac_hints(function(mac, name) e:value(mac, "%s (%s)" % {mac, name}) end)

e = t:option(Value, "ip", translate("静态IP/主机名"),
	translate("与 MAC 任一命中即生效，防止客户端改 MAC。留空不启用。"))
e.rmempty = true

e = t:option(TextValue, "apps", translate("要封锁的名称") .. '<font color="green">' .. translate("(逗号或换行分隔)") .. '</font>',
	translate("填应用/游戏/网站名称（中英文均可），也可直接填域名或 IP/CIDR。原始域名/IP/CIDR 会直接生效；名称部分点下面的「AI 解析」换成真实域名。"))
e.rmempty = true

e = t:option(TextValue, "domains", translate("域名/IP") .. '<font color="green">' .. translate("(生效列表，逗号或换行分隔)") .. '</font>',
	translate("真正生效的列表：这里填的域名会由路由器解析成 IP，并按目标 IP 封锁（IPv4 上无法按域名或文本内容匹配）。「AI 解析」的结果会追加到这里。"))
e.rmempty = true

e = t:option(DummyValue, "pc_ai_parse", translate("AI 解析"),
	translate("把上面的名称交给 AI，换成真实域名并追加到「域名/IP」。"))
e.template = "parentcontrol/ai_parse"

parts.add_profile(t, "sd", translate("平日"))
parts.add_profile(t, "hd", translate("节假日"))

return a
