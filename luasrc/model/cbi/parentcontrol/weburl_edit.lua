-- 条目详细设置页（第 8 轮 D17/ADR-018：一个条目 = 一台（或多台）被管设备 + 若干行「封锁名称」）。
-- 字段顺序（第 11k 轮 A95-2 更新）：条目名称(remarks) → 绑定设备行表(clients)
--                        → 绑定状态(_bind) → 封锁名称行表(apps) → 黑/白名单(mode) → 平日/节假日档案。
-- 旧的「域名/IP」(domains) 大框与页面级「AI 解析」按钮已撤：前者由行表取代（迁移把
-- domains 并进 apps 行），后者由行表里的逐行「AI 解析IP」取代（同一个 ai_parse 接口）。
-- 第 11k 轮：旧的单值「MAC地址」/「静态IP/主机名」两个控件已撤，改为 clients 设备行表。
local ui = require "luci.model.cbi.parentcontrol.ui"
local disp = require "luci.dispatcher"
local parts = require "luci.model.cbi.parentcontrol.parts"

if not arg[1] then
	luci.http.redirect(disp.build_url("admin", "control", "parentcontrol", "weburl"))
	return
end

local a, t, e
a = Map("parentcontrol", translate("编辑条目"),
	translate("一个条目 = 一台被管设备 + 若干行「封锁名称」。在下面逐行填：名称（给人看）+ 该名称真正生效的域名/IP。</br>平日 / 节假日 两套档案各自设<b>可用时段</b>+<b>每日额度</b>。<b>可用时段</b>内才能使用（默认全天 00:00:00-23:59:59；不跨日、起必须早于止），时段外的流量直接被丢弃、<b>不计入额度</b>；时段内累计用满额度也会被封。</br>勾 <b>不限额度</b> 就只受时段限制（额度框会消失）。额度 <b>0</b> = 一分钟都不给（全禁）。额度按自然日、每天 0 点重置，可填共享组名并入额度池。"))
a.redirect = disp.build_url("admin", "control", "parentcontrol", "weburl")
a.template = "parentcontrol/edit"

if not a:get(arg[1]) then
	luci.http.redirect(a.redirect)
	return
end

t = a:section(NamedSection, arg[1], "weburl")
t.addremove = false

-- ① 条目名称 = 这台设备的别名（展示用；可留空，列表页会兜底显示首个封锁名称）
e = t:option(Value, "remarks", translate("条目名称"),
	translate("这台被管设备的别名（如 iPad Pro）。只用于在列表里认出它；要封锁什么在下面的「封锁名称」行表里逐条填。"))
e.rmempty = true

-- ② 设备绑定（第 11k 轮 A95-2，用户拍板 ①）：一行一台设备 `MAC|IP`（两侧皆可空）。
-- 同一条目的多台设备共用一份额度/计时（合并计数链）——「iPad 轮换私有地址加旧 MAC」这类
-- 场景把多台都填进来即可。控件是 TextValue + 行表模板，真正提交的仍是 clients 原文。
e = t:option(TextValue, "clients", translate("绑定设备"),
	translate("一行一台设备：左边 MAC 地址，右边该设备的静态 IP（可留空）。同一台设备换 Wi-Fi 会换 MAC，可以把多台都填进来；这一列的次序就是规则次序，额度是这些设备合计的。"))
e.template = "parentcontrol/clients_rows"
e.rmempty = true

-- R10/D18（ADR-021）：绑定健康。绑定的 MAC **全部**不在网 ⇒ 该条目既不计时也不封锁
-- （典型原因：iOS/iPadOS「私有 Wi-Fi 地址」轮换）。这里只提示与一键重绑，不自动改配置。
e = t:option(DummyValue, "_bind", translate("绑定状态"),
	translate("绑定的设备不在网时，这个条目既不计时也不封锁。常见原因是 iOS「私有 Wi-Fi 地址」轮换：可在 iPad 的 Wi-Fi 设置里把该网络改为「固定」。此处只做检测与一键重绑，不会自动修改你的配置。"))
e.template = "parentcontrol/bind_status"
e.cfgvalue = function(self, section) return ui.clients_raw(self.map, section) end

-- ③ 封锁名称行表：一行一个名称（名称给人看，生效靠该行的域名/IP）
e = t:option(TextValue, "apps", translate("封锁名称"),
	translate("一行一个名称。点该行的「AI 解析IP」把名称换成真实域名；结果**追加**进该行（已存在的不重复添加，原有内容不会被覆盖）。"))
e.template = "parentcontrol/apps_rows"
e.rmempty = true

-- ④ 黑 / 白名单模式（默认黑名单；白名单下额度与时段照旧生效）
e = t:option(ListValue, "mode", translate("名单模式"),
	translate("黑名单：只封下面列出的目标（默认）。白名单：只放行下面列出的目标，该设备的其余流量全部封锁（局域网、路由器自身、DNS 与 DHCP 始终可用）。两种模式下额度与时段都照旧生效。"))
e:value("black", translate("黑名单（只封列出的目标）"))
e:value("white", translate("白名单（只放行列出的目标，其余全封）"))
e.default = "black"

parts.add_profile(t, "sd", translate("平日"))
parts.add_profile(t, "hd", translate("节假日"))

return a
