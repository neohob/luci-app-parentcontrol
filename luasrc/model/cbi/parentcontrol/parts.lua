-- 三个模块表（time / protocol / weburl）共用的「平日/节假日档案」字段与校验。
--
-- 统一模型：**没有"模式"枚举**。每个档案只回答两件事：什么时候能用、能用多少
--     封 = (不在可用时段内)  或  (已用 ≥ 额度)
--   · 可用时段：默认 00:00:00-23:59:59（全天），不跨日、起必须早于止
--   · 额度：分钟数；填 0 = 一分钟都不给（即全禁）；勾「不限额度」则只判时段
--   · 不限制 = ☑不限额度 + 时段全天（此时一条封锁规则都不会生成，只计数）
--   条目是否生效由列表页的「开启」开关决定。
--
-- 注意：本文件是被 require 的子模块，LuCI 注入的全局（translate 等）在这里不可用，必须显式 require。
-- 另外：所有字段保持 rmempty 默认（可选）。CBI 的「必填」(rmempty=false) 在字段被 depends 隐藏时
-- 照样报 missing，会让页面存不了盘；「起<止」「必填」用下面的自定义 validate + 前端提示实现。
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

-- 读同一 section 里另一个字段「本次提交」的值（CBI 的 validate 看不到兄弟字段）
local function submitted(self, key)
	return http.formvalue(("cbid.%s.%s.%s"):format(self.map.config, self.section, key))
end

-- 可用时段：格式 + 起必须早于止（不支持跨日）
function M.validate_window(self, value)
	local ok, err = M.validate_time(self, value)
	if not ok then return nil, err end
	local is_start = self.option:find("_qstart$") ~= nil
	-- 注意：不能写成 gsub("_qstart$","_qend"):gsub("_qend$","_qstart") —— 来回替换会转回自己，
	-- 于是 a>=b 恒真、每个合法的"起"都被判错、编辑页存不了盘（真机上踩过）。
	local other = submitted(self, is_start
		and self.option:gsub("_qstart$", "_qend")
		or  self.option:gsub("_qend$",  "_qstart"))
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

-- label 是 "平日" / "节假日"（必须是字面量翻译键，不能拼接）；拼在字段标题前做区分。
function M.add_profile(t, sfx, label)
	local s = t:option(cbi.Value, sfx .. "_qstart", label .. " " .. i18n.translate("可用起"))
	s.placeholder = '00:00:00'; s.default = '00:00:00'
	s.validate = M.validate_window
	s.rmempty = true

	local e = t:option(cbi.Value, sfx .. "_qend", label .. " " .. i18n.translate("可用止"))
	e.placeholder = '23:59:59'; e.default = '23:59:59'
	e.validate = M.validate_window
	e.rmempty = true

	local u = t:option(cbi.Flag, sfx .. "_unlimited", label .. " " .. i18n.translate("不限额度"))
	u.default = "0"
	u.rmempty = true

	-- 提示写在标签里，不用 cbi-value-description：描述会作为独立一行渲染在字段下方，
	-- 视觉上容易跟后一个字段（共享组）黏在一起，看起来像它俩是一组。
	local q = t:option(cbi.Value, sfx .. "_quota",
		label .. " " .. i18n.translate("每日分钟（0 = 全禁）"))
	q.placeholder = i18n.translate("如 60")
	q.default = "60"
	q.datatype = "uinteger"
	q.rmempty = true

	-- 提示统一写在标签里（与「每日分钟（0 = 全禁）」同一种风格），不再用 placeholder：
	-- placeholder 只在输入框为空时可见，填过东西就看不到了。
	local p = t:option(cbi.Value, sfx .. "_pool",
		label .. " " .. i18n.translate("共享组（留空 = 独立额度）"))
	p.rmempty = true
end

return M
