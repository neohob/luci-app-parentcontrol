-- 三个模块表（time / protocol / weburl）共用的「平日/节假日档案」字段与时间校验。
-- 放在这里而不是各文件各抄一份，避免三张表字段漂移。
--
-- 注意：CBI 模型文件里可以直接用 ListValue/Value/translate/... （加载时由 LuCI 注入），
-- 但本文件是被 require 的子模块，环境里没有这些全局名 —— 必须从 luci.cbi 取，
-- 否则 t:option(nil, ...) 会报 "class must be a descendant of AbstractValue"。
local cbi = require "luci.cbi"
local i18n = require "luci.i18n"

local M = {}

function M.validate_time(self, value)
	local hh, mm = string.match(value, "^(%d?%d):(%d%d)$")
	hh = tonumber(hh); mm = tonumber(mm)
	if hh and mm and hh <= 23 and mm <= 59 then
		return value
	end
	return nil, "时间格式必须为 HH:MM 或者留空"
end

-- 模式三选一（关闭 / 时段 / 每日额度），按模式显隐参数。
-- mode_label 必须是字面量（翻译键要求字面量，不能拼接）。
function M.add_profile(t, sfx, mode_label)
	local m = t:option(cbi.ListValue, sfx .. "_mode", mode_label)
	m:value("off", i18n.translate("关闭"))
	m:value("time", i18n.translate("时段"))
	m:value("quota", i18n.translate("每日额度"))
	m.default = "time"
	m.rmempty = true

	local s = t:option(cbi.Value, sfx .. "_start", i18n.translate("起控"))
	s.placeholder = '00:00'; s.default = '00:00'; s.validate = M.validate_time
	s:depends(sfx .. "_mode", "time")
	s.rmempty = true

	local e = t:option(cbi.Value, sfx .. "_end", i18n.translate("停控"))
	e.placeholder = '00:00'; e.default = '00:00'; e.validate = M.validate_time
	e:depends(sfx .. "_mode", "time")
	e.rmempty = true

	local q = t:option(cbi.Value, sfx .. "_quota", i18n.translate("每日分钟"))
	q.datatype = "uinteger"
	q:depends(sfx .. "_mode", "quota")
	q.rmempty = true

	local p = t:option(cbi.Value, sfx .. "_pool", i18n.translate("共享组"))
	p.placeholder = i18n.translate("留空=独立额度")
	p:depends(sfx .. "_mode", "quota")
	p.rmempty = true
end

return M
