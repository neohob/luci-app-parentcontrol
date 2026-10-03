-- 三个模块表（time / protocol / weburl）共用的「平日/节假日档案」字段与校验。
-- 放在这里而不是各文件各抄一份，避免三张表字段漂移。
--
-- 统一模型（每个档案）：关闭 / 每日额度；额度模式下有「可用时段」+「额度」：
--   封 = (不在可用时段内) 或 (额度用完了)
--   勾「不限额度」→ 额度框隐藏，只判时段；不勾 → 额度必填、不能为 0
--   时段不跨日，起必须早于止；默认 00:00:00-23:59:59（全天）
--   额度按自然日重置（用量文件按天分文件），没有「发放时刻」了
--
-- 注意：CBI 模型文件里可以直接用 ListValue/Value/translate/...（加载时由 LuCI 注入），
-- 但本文件是被 require 的子模块，环境里没有这些全局名 —— 必须从 luci.cbi 取，
-- 否则 t:option(nil, ...) 会报 "class must be a descendant of AbstractValue"。
--
-- 另外：这里所有字段都保持 rmempty 默认（可选）。CBI 的「必填」(rmempty=false) 在字段
-- 被 depends 隐藏时照样会报 missing，那会让「关闭」模式的条目根本存不了盘。
-- 「必填 / 不能为 0 / 起<止」用下面的自定义 validate 实现，前端另有即时提示。
local cbi = require "luci.cbi"
local i18n = require "luci.i18n"
local http = require "luci.http"

local M = {}

-- HH:MM:SS → 秒（非法 → nil）
local function to_sec(t)
	local hh, mm, ss = string.match(t or "", "^(%d?%d):(%d%d):(%d%d)$")
	if not hh then return nil end
	return tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end

function M.validate_time(self, value)
	local hh, mm, ss = string.match(value or "", "^(%d?%d):(%d%d):(%d%d)$")
	if not hh or tonumber(hh) > 23 or tonumber(mm) > 59 or tonumber(ss) > 59 then
		return nil, "时间格式必须为 HH:MM:SS"
	end
	return value
end

-- 读同一 section 里另一个字段「本次提交」的值。
-- CBI 的 validate 看不到兄弟字段，只能自己按 cbid 从表单里取。
local function submitted(self, key)
	return http.formvalue(("cbid.%s.%s.%s"):format(self.map.config, self.section, key))
end

-- 可用时段：格式 + 起必须早于止（本插件不支持跨日）
function M.validate_window(self, value)
	local ok, err = M.validate_time(self, value)
	if not ok then return nil, err end
	local is_start = self.option:find("_qstart$") ~= nil
	local other = submitted(self, self.option:gsub("_qstart$", "_qend"):gsub("_qend$", "_qstart"))
	if other and other ~= "" then
		local a, b = to_sec(value), to_sec(other)
		if a and b then
			if is_start and a >= b then
				return nil, "可用起必须早于可用止（不支持跨日时段）"
			elseif not is_start and b >= a then
				return nil, "可用止必须晚于可用起（不支持跨日时段）"
			end
		end
	end
	return value
end

-- 额度不能填 0：0 会让「用完封」和「不限额度」两种含义打架（要不限请勾复选框）
function M.validate_quota(self, value)
	if value ~= nil and value ~= "" and tonumber(value) == 0 then
		return nil, "额度不能填 0；要不限请勾选「不限额度」"
	end
	return value
end

-- mode_label 必须是字面量（翻译键要求字面量，不能拼接）。
function M.add_profile(t, sfx, mode_label)
	local m = t:option(cbi.ListValue, sfx .. "_mode", mode_label)
	m:value("off", i18n.translate("关闭"))
	m:value("quota", i18n.translate("每日额度"))
	m.default = "off"
	m.rmempty = true

	local s = t:option(cbi.Value, sfx .. "_qstart", i18n.translate("可用起"))
	s.placeholder = '00:00:00'; s.default = '00:00:00'
	s.validate = M.validate_window
	s:depends(sfx .. "_mode", "quota")
	s.rmempty = true

	local e = t:option(cbi.Value, sfx .. "_qend", i18n.translate("可用止"))
	e.placeholder = '23:59:59'; e.default = '23:59:59'
	e.validate = M.validate_window
	e:depends(sfx .. "_mode", "quota")
	e.rmempty = true

	-- 勾上 = 不限额（额度框隐藏），只判可用时段
	local u = t:option(cbi.Flag, sfx .. "_unlimited", i18n.translate("不限额度"))
	u.default = "0"
	u:depends(sfx .. "_mode", "quota")
	u.rmempty = true

	-- 额度：默认 60，不能填 0；勾了「不限额度」就隐藏（depends 组内 AND，组间 OR）
	local q = t:option(cbi.Value, sfx .. "_quota", i18n.translate("每日分钟"))
	q.placeholder = i18n.translate("必填，如 60")
	q.default = "60"
	q.datatype = "uinteger"
	q.validate = M.validate_quota
	q:depends({ [sfx .. "_mode"] = "quota", [sfx .. "_unlimited"] = "0" })
	q.rmempty = true

	local p = t:option(cbi.Value, sfx .. "_pool", i18n.translate("共享组"))
	p.placeholder = i18n.translate("留空=独立额度")
	p:depends({ [sfx .. "_mode"] = "quota", [sfx .. "_unlimited"] = "0" })
	p.rmempty = true
end

return M
