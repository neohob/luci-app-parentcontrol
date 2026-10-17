-- 包版本读取（第 11k-7 轮 A128 / D54）：静态资源缓存版本化的版本来源。
--
-- 为什么版本来自**运行时文件**而不是 Lua 常量、也不是构建期生成（理由见 design.md §11.29.2）：
--   * root/ 树会被 ipk 与 .run 两条打包路径原样拷贝 ⇒ 无需改任何打包脚本；
--   * 测试包是在 /tmp 副本里 sed Makefile 生成的，常量不会跟着变；
--   * 与 Makefile 的漂移由静态门 W178② 兜住（version 内容必须 == PKG_VERSION-PKG_RELEASE）。
--
-- 两条硬约束（静态门盯着，别改）：
--   W178③ 本文件里**不得**出现包版本号字面量 —— 版本只在 version 文件里，否则绕过 ②。
--   W178④ 回退值必须是**非空**字符串 —— 空串会让 `?v=` 等价于「无参数」，
--          浏览器随即命中旧缓存，本轮修复的意义整体失效。
--
-- 注：本模块被 require 时拿不到 CBI 注入的全局类名（同目录 parts.lua 的坑），本文件不用任何类名。

local M = {}

local VERSION_FILE = "/usr/lib/parentcontrol/version"
local FALLBACK = "0"          -- 非空！空串会让 ?v= 退化为无参数（W178④）
local cached                  -- 模块级 memo：一次进程只读一次盘

-- 只接受「安全字符」版本串：字母数字 . _ -。其余（空、含空格/换行/引号/HTML 特殊字符）一律回退。
local SAFE = "^[%-%w%._]+$"

function M.get()
	if cached then
		return cached
	end

	local val = FALLBACK
	local fh = io.open(VERSION_FILE, "r")
	if fh then
		local raw = fh:read("*a")
		fh:close()
		local text = raw and raw:match("^%s*(.-)%s*$") or nil
		if text and text:match(SAFE) then
			val = text
		end
	end

	cached = val
	return cached
end

return M
