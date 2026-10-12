-- AI 辅助解析：把「应用/游戏/网站名称」分解成真实域名，供编辑页的 domains 输入框使用。
--
-- 设计要点（见 docs/superpowers/specs/pc-ui-ai-rework-*）：
--  * 本模块是纯逻辑 + HTTP 代理：真正的网络请求交给 shell 子命令
--    `/etc/init.d/parentcontrol ai_http <GET|POST> <url> <infile|-> <outfile>`，
--    由 common.sh 的 pc_http 依序探测 curl/uclient-fetch/wget，不新增 OpenWrt 硬依赖。
--  * 本文件是被 require 的子模块，不能依赖 LuCI 注入的全局 translate()，
--    必须自己 require "luci.i18n"（范本：statsdata.lua）。
--  * 所有新增用户可见文案都包在 T()（= i18n.translate）里，中文 msgid。

local i18n = require "luci.i18n"
local sys  = require "luci.sys"

-- F-7：临时文件限权用（keyfile 含 API Key）。nixio.fs 缺失时降级为不限权（不致命）。
local okfs, fs = pcall(require, "nixio.fs")

local function T(s) return i18n.translate(s) end

local M = {}

-- 固定系统提示词：唯一职责 = 名称 -> 真实 ASCII 域名。
local SYS_PROMPT = "你是域名解析助手。用户会给出应用/游戏/网站的中文名称（可多个）。"
	.. "请只输出这些名称对应的**真实域名**，每行一个，只输出可被 DNS 解析的 ASCII 域名"
	.. "（形如 example.com），不要输出中文、不要输出解释、不要输出 markdown 代码块、"
	.. "不要输出路径或协议。不确定时给出最可能的官方域名，最多 5 个。"
M.SYS_PROMPT = SYS_PROMPT

-- 域名形态：至少一个点，每个标签以字母数字开头结尾。
local RE_IPV4         = "^%d+%.%d+%.%d+%.%d+$"
local RE_DOMAIN       = "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(%.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$"
local RE_DOMAIN_ASCII = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(%.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip(s, n)
	if type(s) == "string" and #s > n then return s:sub(1, n) end
	return s
end

-- 稳定去重 + 升序。
local function uniq_sorted(list)
	local seen, out = {}, {}
	for _, v in ipairs(list) do
		if type(v) == "string" and v ~= "" and not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	table.sort(out)
	return out
end

-- 按换行 / 逗号 / 中文逗号「、」/ 分号 / 空白切分成词元。
-- 注意：不能把多字节字符放进 Lua 字符类里逐字节排除，否则会切坏中文（0x80 是常见续字节）。
local function split_tokens(text)
	local t = tostring(text or "")
	t = t:gsub("%s+", " ")
	t = t:gsub("、", ","):gsub("，", ","):gsub("；", ","):gsub(";", ",")
	local out = {}
	for piece in t:gmatch("[^,%s]+") do
		out[#out + 1] = piece
	end
	return out
end

-- 把一段自由文本分类：能直接生效的（域名/IP/CIDR）进 direct，其余送 AI 的进 names。
function M.classify(text)
	local direct, names = {}, {}
	for _, tok in ipairs(split_tokens(text)) do
		if tok:find("/", 1, true) then                 -- CIDR / 含路径
			direct[#direct + 1] = tok
		elseif tok:match(RE_IPV4) then                 -- 纯 IPv4
			direct[#direct + 1] = tok
		elseif tok:match("^[%x:]+$") and select(2, tok:gsub(":", "")) >= 2 then
			-- F-8：真 IPv6 形态才直用（仅十六进制与冒号、至少两个冒号），
			-- 「抖音:短视频」这类含冒号的名称必须落到 names 送 AI。
			direct[#direct + 1] = tok
		elseif tok:match(RE_DOMAIN) then               -- 已是域名形态
			direct[#direct + 1] = tok:lower()
		else
			names[#names + 1] = tok
		end
	end
	return { direct = uniq_sorted(direct), names = uniq_sorted(names) }
end

-- 从模型回答里抽取合法的 ASCII 域名：剥 markdown 围栏/反引号/列表编号，
-- 剥协议前缀与路径端口，小写化，只留「至少一个点」的纯 ASCII 域名。
function M.extract_domains(text)
	local raw = tostring(text or "")
	if #raw > 4096 then raw = raw:sub(1, 4096) end

	local t = raw
	t = t:gsub("```", " ")   -- markdown 围栏
	t = t:gsub("`", " ")     -- 行内反引号
	t = t:gsub("%*", " ")    -- 粗体/斜体标记

	local domains = {}
	for line in (t .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("^%s*%d+[%.%)]%s+", "")   -- 「1. 」/「1) 」
		line = line:gsub("^%s*[%-%*%+]%s+", "")    -- 「- 」/「* 」
		line = line:gsub("、", ","):gsub("，", ","):gsub("；", ","):gsub(";", ",")
		for tok in line:gmatch("[^,%s]+") do
			tok = tok:lower()
			tok = tok:gsub("^https?://", "")     -- 去协议
			tok = tok:gsub("[/:].*$", "")        -- 去路径 / 端口
			tok = tok:gsub("^%.+", ""):gsub("%.+$", "")  -- 去首尾点
			if tok:match(RE_DOMAIN_ASCII) then
				domains[#domains + 1] = tok
			end
		end
	end
	return { domains = uniq_sorted(domains), raw = raw }
end

-- endpoint 白名单：http(s):// 开头，不含空白/引号/反引号/分号/竖线/&/$/括号/尖括号，且不含 ".."。
function M.valid_endpoint(url)
	if type(url) ~= "string" then return false end
	if url == "" or #url > 512 then return false end
	if url:find("..", 1, true) then return false end
	return url:match("^https?://[^%s'\"`;|&%$%(%)<>]+$") ~= nil
end

-- ---------- JSON（优先 luci.jsonc，兜底 luci.util / luci.json）----------

local function json_encode(tbl)
	local ok, s = pcall(function()
		local util = require "luci.util"
		if type(util.serialize_json) == "function" then
			return util.serialize_json(tbl)
		end
	end)
	if ok and type(s) == "string" then return s end

	local ok2, s2 = pcall(function()
		local jsonc = require "luci.jsonc"
		if type(jsonc.stringify) == "function" then
			return jsonc.stringify(tbl)
		end
	end)
	if ok2 and type(s2) == "string" then return s2 end

	local ok3, s3 = pcall(function()
		local enc = require("luci.json").Encoder()
		return enc:encode(tbl)
	end)
	if ok3 and type(s3) == "string" then return s3 end

	return nil
end

local function json_decode(str)
	local ok, r = pcall(function()
		return require("luci.jsonc").parse(str)
	end)
	if ok and type(r) == "table" then return r end

	local ok2, r2 = pcall(function()
		local dec = require("luci.json").Decoder()
		return dec:decode(str)
	end)
	if ok2 and type(r2) == "table" then return r2 end

	return nil
end

-- ---------- HTTP 代理（走 /etc/init.d/parentcontrol ai_http）----------

local seq = 0
math.randomseed(os.time())

local function tmpfile(kind)
	seq = seq + 1
	return string.format("/tmp/pc-ai-%s-%d-%d-%d", kind, os.time(), math.random(100000, 999999), seq)
end

-- 单引号 shell 转义，杜绝注入。
local function shq(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- F-7：临时文件创建后收紧为 0600（384 = 十进制 0o600；不拼 shell 字符串）。
-- 先建好再让 shell 重定向复用同一 inode（> 截断不改权限）。
local function tighten(path)
	if okfs and fs and fs.chmod then pcall(fs.chmod, path, 384) end
end

local function readfile(p)
	local f = io.open(p, "r")
	if not f then return nil end
	local d = f:read("*a")
	f:close()
	return d
end

-- 返回 body 字符串；失败返回 nil, 可读原因。
local function http_run(method, url, body, apikey)
	local out = tmpfile("out")
	local infile, keyfile

	-- 先建 out（0600）：pc_http 的重定向只截断、不重建，权限得以保留
	local f = io.open(out, "w")
	if f then f:close() end
	tighten(out)

	-- PC_AI_TIMEOUT 只允许数字，防止环境变量注入。
	local timeout = (os.getenv("PC_AI_TIMEOUT") or ""):match("^%d+$") or "15"
	local parts = { "PC_AI_TIMEOUT=" .. timeout }

	if apikey and apikey ~= "" then
		keyfile = tmpfile("key")
		local kf = io.open(keyfile, "w")
		if kf then kf:write(apikey); kf:close() end
		tighten(keyfile)
		parts[#parts + 1] = "PC_AI_KEY_FILE=" .. shq(keyfile)
	end

	if body ~= nil then
		infile = tmpfile("in")
		local inf = io.open(infile, "w")
		if not inf then
			return nil, T("无法创建临时文件")
		end
		inf:write(body)
		inf:close()
		tighten(infile)
	end

	local cmd = table.concat(parts, " ")
		.. " /etc/init.d/parentcontrol ai_http "
		.. method .. " " .. shq(url) .. " "
		.. (infile and shq(infile) or "'-'") .. " "
		.. shq(out) .. " >/dev/null 2>&1"

	local rc = sys.call(cmd)
	local data = readfile(out)

	os.remove(out)
	if infile then os.remove(infile) end
	if keyfile then os.remove(keyfile) end

	if rc ~= 0 then
		local reason = (type(data) == "string" and data ~= "")
			and data
			or T("AI 请求失败：路由器缺少可用的 HTTP 客户端，或网络不可达")
		return nil, clip(reason, 2048)
	end
	if type(data) ~= "string" or data == "" then
		return nil, T("AI 服务返回空响应")
	end
	return clip(data, 262144)
end

-- ---------- uci 配置 ----------

function M.config()
	local conf = { endpoint = "", model = "", apikey = "" }
	pcall(function()
		local uci = require("luci.model.uci").cursor()
		conf.endpoint = uci:get("parentcontrol", "@ai[0]", "endpoint") or ""
		conf.model    = uci:get("parentcontrol", "@ai[0]", "model") or ""
		conf.apikey   = uci:get("parentcontrol", "@ai[0]", "apikey") or ""
	end)
	return conf
end

-- 从 {endpoint}/models 拉取模型候选列表（OpenAI 兼容 GET /models）。
function M.models(endpoint, apikey)
	local conf = M.config()
	endpoint = trim(endpoint or "")
	if endpoint == "" then endpoint = trim(conf.endpoint or "") end
	-- F-9：apikey 为空时无条件回落已保存值（与 M.parse 对称），不再只挂在 endpoint == "" 分支里
	if apikey == nil or apikey == "" then apikey = conf.apikey or "" end
	if endpoint == "" then
		return { ok = false, error = T("请先填写 AI endpoint（以 http:// 或 https:// 开头）") }
	end
	if not M.valid_endpoint(endpoint) then
		return { ok = false, error = T("AI endpoint 无效（需以 http:// 或 https:// 开头）") }
	end

	local body, err = http_run("GET", endpoint:gsub("/+$", "") .. "/models", nil, apikey)
	if not body then return { ok = false, error = err } end

	local parsed = json_decode(body)
	if type(parsed) ~= "table" then
		return { ok = false, error = T("AI 服务响应不是 JSON，请确认 endpoint 是 OpenAI 兼容接口") }
	end

	local models = {}
	if type(parsed.data) == "table" then
		for _, item in ipairs(parsed.data) do
			if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
				models[#models + 1] = item.id
			end
		end
	end
	table.sort(models)
	return { ok = true, models = models }
end

-- 主流程：分类 -> 未配置则报错 -> 送 AI -> 抽取合法域名。
function M.parse(text, opts)
	opts = opts or {}

	local c = M.classify(text)
	if #c.names == 0 then
		-- 全部是域名/IP/CIDR，直用即可，不必调模型。
		return { ok = true, direct = c.direct, domains = {}, raw = "" }
	end

	local conf     = M.config()
	local endpoint = trim(opts.endpoint or conf.endpoint or "")
	local model    = trim(opts.model or conf.model or "")
	local apikey   = opts.apikey
	if apikey == nil then apikey = conf.apikey or "" end

	if endpoint == "" or model == "" then
		return { ok = false, error = T("请先在「设置」页配置 AI endpoint 与 model") }
	end
	if not M.valid_endpoint(endpoint) then
		return { ok = false, error = T("AI endpoint 无效（需以 http:// 或 https:// 开头）") }
	end

	local payload = json_encode({
		model       = model,
		temperature = 0,
		messages    = {
			{ role = "system", content = SYS_PROMPT },
			{ role = "user",   content = table.concat(c.names, "\n") },
		},
	})
	if not payload then
		return { ok = false, error = T("无法构造 AI 请求体") }
	end

	local body, err = http_run("POST", endpoint:gsub("/+$", "") .. "/chat/completions", payload, apikey)
	if not body then return { ok = false, error = err } end

	local parsed = json_decode(body)
	if type(parsed) ~= "table" then
		return { ok = false, error = T("AI 服务响应不是 JSON") }
	end

	local content
	local choices = parsed.choices
	if type(choices) == "table" and type(choices[1]) == "table" then
		local msg = choices[1].message
		if type(msg) == "table" then content = msg.content end
		if type(content) ~= "string" then content = choices[1].text end
	end
	if type(content) ~= "string" then
		return { ok = false, error = T("AI 响应缺少内容（choices[0].message.content）") }
	end

	local ex = M.extract_domains(content)
	if #ex.domains == 0 and #c.direct == 0 then
		-- A9 第四类失败（复审 F-1）：AI 有回应但抽不出任何合法域名，也没有可直用的项 ——
		-- 必须按失败红字处理，不得回落成绿色「新增 0 项」。
		return { ok = false, error = T("AI 没有解析出合法域名，请手动填写域名或 IP"), raw = ex.raw }
	end
	return { ok = true, direct = c.direct, domains = ex.domains, raw = ex.raw }
end

return M
