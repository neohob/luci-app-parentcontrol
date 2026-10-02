-- 三个模块表（time / protocol / weburl）共用的「平日/节假日档案」字段与时间校验。
-- 放在这里而不是各文件各抄一份，避免三张表字段漂移。
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
-- 时段：起控/停控（起控=停控 或留空 = 全天封）；额度：每日分钟 + 可选共享组。
function M.add_profile(t, sfx, label)
	local m = t:option(ListValue, sfx .. "_mode", translate(label .. "模式"))
	m:value("off", translate("关闭"))
	m:value("time", translate("时段"))
	m:value("quota", translate("每日额度"))
	m.default = "time"
	m.rmempty = true

	local s = t:option(Value, sfx .. "_start", translate("起控"))
	s.placeholder = '00:00'; s.default = '00:00'; s.validate = M.validate_time
	s:depends(sfx .. "_mode", "time")
	s.rmempty = true

	local e = t:option(Value, sfx .. "_end", translate("停控"))
	e.placeholder = '00:00'; e.default = '00:00'; e.validate = M.validate_time
	e:depends(sfx .. "_mode", "time")
	e.rmempty = true

	local q = t:option(Value, sfx .. "_quota", translate("每日分钟"))
	q.datatype = "uinteger"
	q:depends(sfx .. "_mode", "quota")
	q.rmempty = true

	local p = t:option(Value, sfx .. "_pool", translate("共享组"))
	p.placeholder = translate("留空=独立额度")
	p:depends(sfx .. "_mode", "quota")
	p.rmempty = true
end

return M
