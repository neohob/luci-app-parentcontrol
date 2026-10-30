-- AI 辅助解析：把「要封锁的名称」分解成真实域名，供编辑页的 domains 输入框使用。
--
-- R6（名称条目模型）：解析输入 = 本条目的 remarks（一个条目一个名称；含逗号/
-- 顿号分隔的多个名称也接受，一次请求返回全部名称的域名**并集**）。前端把并集
-- **去重合并追加**进当前行（不清空已有内容，见 view/parentcontrol/apps_rows.htm + pc-ui.js）。
--
-- 设计要点（见 docs/superpowers/specs/pc-ui-ai-rework-*）：
--  * 本模块是纯逻辑 + HTTP 代理：真正的网络请求交给 shell 子命令
--    `/etc/init.d/parentcontrol ai_http <GET|POST> <url> <infile|-> <outfile>`，
--    由 common.sh 的 pc_http 依序探测 curl/uclient-fetch/wget，不新增 OpenWrt 硬依赖。
--  * 本文件是被 require 的子模块，不能依赖 LuCI 注入的全局 translate()，
--    必须自己 require "luci.i18n"（范本：statsdata.lua）。
--  * 所有新增用户可见文案都包在 T()（= i18n.translate）里，中文 msgid。
--  * Lua 5.1 陷阱（F2，真机实测）：模式匹配不支持「捕获组 + 量词」—— `(%w+)?` 里的
--    量词被当普通字符、模式永不匹配。全文件不得出现该形态；域名校验因此用
--    label 拆分式（见下方 is_domain_like 注释）。

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

-- IPv4 形态（纯字符类 + 量词，Lua 5.1 安全）。
local RE_IPV4 = "^%d+%.%d+%.%d+%.%d+$"

-- 域名校验（F2）：废弃旧 RE_DOMAIN / RE_DOMAIN_ASCII 正则 —— Lua 5.1（设备
-- /usr/bin/lua）不支持「捕获组 + 量词」，`([A-Za-z0-9-]*[A-Za-z0-9])?` 里的量词被
-- 当普通字符，正则永不匹配（真机实测：extract_domains 恒空、纯域名被误判成名称，
-- 见 test-report §4 F2）。改为 label 拆分校验：
--   按 "." 拆 ≥2 段；每段 1–63 字符；首尾是字母数字；中间只允许 [A-Za-z0-9-]。
-- 本文件所有模式只用「字符类 + 量词」，无任何捕获组带量词 —— 新增代码请保持。
local DOMAIN_LABEL_MAX = 63
local DOMAIN_NAME_MAX  = 253

-- head：首尾单字符类；mid：整段字符类（自带 ^…+$ 定界）。
local function is_domain_like(s, head, mid)
	if type(s) ~= "string" or #s == 0 or #s > DOMAIN_NAME_MAX then return false end
	local labels = {}
	for lab in s:gmatch("[^%.]+") do
		labels[#labels + 1] = lab
	end
	-- 点数 = 段数 - 1：拒绝空 label（首尾点、连续点）。
	local dots = select(2, s:gsub("%.", "."))
	if #labels < 2 or dots ~= #labels - 1 then return false end
	for i = 1, #labels do
		local lab = labels[i]
		if #lab > DOMAIN_LABEL_MAX then return false end
		if not lab:sub(1, 1):match(head) then return false end
		if not lab:sub(-1):match(head) then return false end
		if not lab:match(mid) then return false end
	end
	return true
end

-- 用户输入的域名判定（classify 直用分支）：大小写均可，命中后由调用方 lower()。
function M.is_domain(s)
	return is_domain_like(s, "[A-Za-z0-9]", "^[A-Za-z0-9-]+$")
end

-- 模型回答的域名判定（extract_domains 过滤）：只收小写 ASCII（回答已先 lower()）。
function M.is_domain_ascii(s)
	return is_domain_like(s, "[a-z0-9]", "^[a-z0-9-]+$")
end

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
		elseif M.is_domain(tok) then                    -- 已是域名形态
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
			if M.is_domain_ascii(tok) then
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
	-- F4：优先 luci.jsonc —— 它把空表编成 []（数组）；luci.util.serialize_json 会编成
	-- {}（对象），前端 concat 一旦收编就是 [object Object]。
	local ok, s = pcall(function()
		local jsonc = require "luci.jsonc"
		if type(jsonc.stringify) == "function" then
			return jsonc.stringify(tbl)
		end
	end)
	if ok and type(s) == "string" then return s end

	local ok2, s2 = pcall(function()
		local util = require "luci.util"
		if type(util.serialize_json) == "function" then
			return util.serialize_json(tbl)
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

-- F-7/F5：临时文件创建后收紧为 0600（不拼 shell 字符串）。nixio.fs.chmod 第二参
-- 必须是**字符串**模式 "0600" —— 传数值 384 会被 nixio 拒绝、且 pcall 吞错，真机上
-- 收紧静默失效、key 文件以 0644 存在（真机实测见 test-report §4 F5）。
local function tighten(path)
	if okfs and fs and fs.chmod then pcall(fs.chmod, path, "0600") end
end

local function readfile(p)
	local f = io.open(p, "r")
	if not f then return nil end
	local d = f:read("*a")
	f:close()
	return d
end

-- F8：pc_http 的失败文案里带原始 stderr（英文 + 工具名，如 "curl: (22) The requested
-- URL returned error: 401"）。按客户端退出码（文案里的 "(NN)"，22/28/7 是 curl 与
-- uclient-fetch 共用的语义码）映射成中文短语，原文括号附注 —— 与全中文界面风格一致。
local function humanize_http_error(text)
	local msg = trim(tostring(text or ""))
	local code = msg:match("%((%d+)[^%)]*%)")
	local hint
	if code == "22" then
		hint = T("AI 服务返回了错误状态（如 401/500），请检查 endpoint 与 API Key")
	elseif code == "28" then
		hint = T("AI 请求超时，请稍后重试")
	elseif code == "7" then
		hint = T("无法连接 AI 服务，请检查 endpoint 与网络")
	end
	if hint and msg ~= "" then
		return hint .. "（" .. clip(msg, 256) .. "）"
	end
	return msg
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
		return nil, clip(humanize_http_error(reason), 2048)
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
		-- A29/D21：段身份统一为命名节 `ai`，逐字段先读命名节，
		-- 为空再回落 `@ai[0]`（兼容未迁移、仍为匿名节的老安装）。
		local function pick(opt)
			local v = uci:get("parentcontrol", "ai", opt)
			if v == nil or v == "" then
				v = uci:get("parentcontrol", "@ai[0]", opt)
			end
			return v or ""
		end
		conf.endpoint = pick("endpoint")
		conf.model    = pick("model")
		conf.apikey   = pick("apikey")
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

-- F4：写给前端的 direct / domains 是**空列表时省略该键**。write_json 对空 Lua 表的
-- 编码形态因 LuCI 版本而异（serialize_json 会编成 {} 对象），前端 concat 把对象当
-- 元素追加就是 [object Object] 脏数据 —— 省键是第一道防线，前端 toList 是第二道。
local function with_list(res, key, list)
	if type(list) == "table" and #list > 0 then
		res[key] = list
	end
	return res
end

-- 主流程：分类 -> 未配置则报错 -> 送 AI -> 抽取合法域名。
function M.parse(text, opts)
	opts = opts or {}

	local c = M.classify(text)
	if #c.names == 0 then
		-- 全部是域名/IP/CIDR，直用即可，不必调模型。（domains 恒空 → 省键，F4。）
		local r = { ok = true, raw = "" }
		with_list(r, "direct", c.direct)
		return r
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
	local r = { ok = true, raw = ex.raw }
	with_list(r, "direct", c.direct)
	with_list(r, "domains", ex.domains)
	return r
end

-- ======================================================================
-- round75（R75-C）：未归类目标的「AI 推测」
--
-- 隐私红线（用户拍板，没有商量空间）：请求体里**只允许**出现三样东西 ——
--   ① 每个未归类目标的公网网段（IPv4，且不是私网/保留段）
--   ② 该网段的 ASN 组织名（来自 round74 的 ASN 缓存，如 AKAMAI-ASN1, NL）
--   ③ 该条目已配的「封锁名称」清单（只有名称文字，不含域名）
-- 绝不发送：MAC、主机名、内网 IP、LAN 网段、设备名、条目备注、其它条目的名称、
-- 用户 uci 全量配置。连「内网网段的形态」都不许出现（发出去就等于泄露编址）。
--
-- 推测结果**绝不写进统计归属**：不进 n/t/nut 行、不进 .map、不进 uci。
-- 只作为展开区里的一个临时展示字段（「低置信 · 推测」）。
-- ======================================================================

-- 名字清单里的「IP 字面量」判定：名称不该是地址；私网地址更是绝不能外发。
-- 只认「整串就是个地址」的形态（含 CIDR / IPv6），不误伤「我的世界」这类中文名。
local function looks_like_ip(v)
	if type(v) ~= "string" or v == "" then return false end
	if v:match("^%d+%.%d+%.%d+%.%d+") then return true end
	if v:find(":", 1, true) and v:match("^[%x:%.]+$") then return true end
	return false
end

-- 严格 IPv4 拆分：4 段、每段 1–3 位十进制、**无前导零**（"010.1.2.3" 视为可疑形态）、
-- 每段 ≤ 255。任何不满足都返回 nil ⇒ 调用方按「不可外发」处理（防绕过）。
local function ipv4_octets(addr)
	local parts = {}
	for p in addr:gmatch("[^%.]+") do parts[#parts + 1] = p end
	if #parts ~= 4 then return nil end
	local o = {}
	for i = 1, 4 do
		local p = parts[i]
		if #p == 0 or #p > 3 then return nil end
		if not p:match("^%d+$") then return nil end
		if #p > 1 and p:sub(1, 1) == "0" then return nil end
		local n = tonumber(p)
		if not n or n > 255 then return nil end
		o[i] = n
	end
	return o
end

-- 是否「不能发给第三方」：私网 / 保留 / 组播 / 形态可疑 / 非 IP 一律 true。
-- 覆盖与 root/etc/init.d/parentcontrol 的 pc_asn_queryable() 同一张表（round74b 的
-- R74-M1 就是漏了这张表，把 18 个内网地址发给了 Team Cymru）：
--   0/8、10/8、127/8、172.16/12、192.168/16、169.254/16、100.64/10、
--   192.0.0/24、192.0.2/24、198.18/15、198.51.100/24、203.0.113/24、≥224
-- 以及 IPv6 的 ::1、fe80::/10、fc00::/7（只放行全局单播 2000::/3）。
--
-- 注意（I-4，round75b）：本函数对 IPv6 只做「私网/链路本地/组播」粗判，所以
-- `is_private_addr("2001:db8::1")` 返回 **false**（2001:db8::/32 落在 2000::/3 里）。
-- 这不构成泄漏，因为「能不能发给第三方」的实际闸门是 is_public_prefix()，它对 IPv6
-- 一律返回 false（只放行 IPv4 形态）。复用本函数时请连着看 is_public_prefix。
function M.is_private_addr(s)
	if type(s) ~= "string" then return true end
	local v = trim(s)
	if v == "" then return true end
	v = v:gsub("/%d+$", "")
	v = v:gsub("^%[", ""):gsub("%]$", "")
	if v:find(":", 1, true) then
		local h = v:lower()
		if h == "::" or h == "::1" then return true end
		if h:sub(1, 2) == "::" then return true end          -- ::ffff:1.2.3.4 等映射形态
		if h:sub(1, 2) == "fe" or h:sub(1, 2) == "fc" or h:sub(1, 2) == "fd" then return true end
		if h:sub(1, 2) == "ff" then return true end          -- 组播
		local f = h:sub(1, 1)
		if f == "2" or f == "3" then return false end        -- 2000::/3 全局单播
		return true
	end
	local o = ipv4_octets(v)
	if not o then return true end
	local a, b, c = o[1], o[2], o[3]
	if a == 0 or a == 10 or a == 127 then return true end
	if a == 172 and b >= 16 and b <= 31 then return true end
	if a == 192 and b == 168 then return true end
	if a == 169 and b == 254 then return true end
	if a == 100 and b >= 64 and b <= 127 then return true end
	if a == 192 and b == 0 then return true end             -- 192.0.0.0/24 与 192.0.2.0/24
	if a == 198 and (b == 18 or b == 19) then return true end
	if a == 198 and b == 51 and c == 100 then return true end
	if a == 203 and b == 0 and c == 113 then return true end
	if a >= 224 then return true end
	return false
end

-- 「可外发的网段」：公网 IPv4 单地址或 IPv4 CIDR（IPv6/域名一律不发：没有 ASN 前缀，
-- 发出去也没有意义，只会扩大暴露面）。
function M.is_public_prefix(s)
	if type(s) ~= "string" then return false end
	local v = trim(s)
	if v == "" then return false end
	if not (v:match("^%d+%.%d+%.%d+%.%d+$") or v:match("^%d+%.%d+%.%d+%.%d+/%d+$")) then return false end
	-- 掩码必须 0..32：`8.8.8.8/33` 之类形状合法、语义非法，不该进请求体。
	local mask = v:match("/(%d+)$")
	if mask then
		mask = tonumber(mask)
		if not mask or mask > 32 then return false end
	end
	return not M.is_private_addr(v)
end

-- 固定系统提示词：唯一职责 = 「网段 + 组织名 + 已配名称」→ 猜这是哪类服务。
-- 明确要求不确定就返回空数组（不许编），并强制 JSON 数组形态便于严格校验。
local INFER_SYS_PROMPT = "你是网络流量归因助手。用户会给出若干「公网网段 + 该网段的 ASN 组织名」"
	.. "以及该条目已配置的封锁名称清单。请推测每个网段最可能属于哪个被封锁的服务/应用。"
	.. "只输出一个 JSON 数组，每个元素形如 {\"prefix\":\"网段\",\"name\":\"名称\",\"confidence\":\"low 或 mid\"}，"
	.. "不要输出任何解释、不要输出 markdown 代码块。prefix 必须是用户给出的网段之一。"
	.. "name 用中文或英文的通用服务名，不超过 20 字，不得包含竖线字符。"
	.. "**不确定就返回空数组 []，绝对不要编造**。"
M.INFER_SYS_PROMPT = INFER_SYS_PROMPT

-- 从模型回答里抽出 JSON 数组：容忍 ```json 包裹与前后废话（与 extract 同风格）。
local function extract_json_array(content)
	if type(content) ~= "string" then return nil end
	local s = trim(content)
	s = s:gsub("^```[%w]*%s*", ""):gsub("%s*```$", "")
	local i, j = s:find("%[")
	if not i then return nil end
	-- 从最后一个 "]" 往前找，容忍数组后面还有废话
	local k = s:match(".*()%]")
	if not k or k < i then return nil end
	return s:sub(i, k)
end

-- 严格校验模型输出。返回 items（只含发送集合里的 prefix），或 nil, 原因。
local function sanitize_infer(parsed, sentmap)
	if type(parsed) ~= "table" then return nil, T("AI 响应不是 JSON 数组") end
	local out, seen = {}, {}
	for _, it in ipairs(parsed) do
		if type(it) == "table" then
			local p = trim(it.prefix or "")
			local n = trim(it.name or "")
			local conf = trim(it.confidence or "")
			-- prefix 必须在**刚才发出去的那批**里：不在的一律丢弃（防模型幻觉塞东西）。
			if p ~= "" and sentmap[p] and not seen[p] then
				if n ~= "" and #n <= 64 and not n:find("|", 1, true) and not n:find("%c") then
					if conf ~= "mid" then conf = "low" end
					seen[p] = true
					out[#out + 1] = { prefix = p, name = n, confidence = conf }
				end
			end
		end
	end
	return out
end

-- I-1（round75b）：组织名是唯一「不经任何过滤就进请求体」的字段。它来自 `stats_tsv asn`
--（shell 侧已经把制表符、回车、换行都删掉了），但本层不该依赖上游净化：控制字符能把一条记录拆成
-- 两行（结构注入），IPv4 字面量会把一个地址顺带发出去。所以这里：控制字符→空格、抹掉
-- 任何 IPv4 形态的 token、折叠空白、截断到 64 字。
local function clean_org(s)
	local v = tostring(s or "")
	v = v:gsub("[%c]", " ")
	v = v:gsub("%d+%.%d+%.%d+%.%d+", " ")
	v = v:gsub(" +", " "):gsub("^ ", ""):gsub(" $", "")
	if #v > 64 then
		v = v:sub(1, 64):gsub(" +$", "")
	end
	return v
end

-- R75-C 主流程。
-- opts = {
--   items = { { target = "<网段>", org = "<ASN 组织名>" }, ... },   -- 来自 round74 的 ASN 数据
--   names = { "<已配名称>", ... },                                  -- 该条目已配的封锁名称
--   endpoint / model / apikey,                                      -- 可覆盖 M.config()
--   http  = function(method, url, body, apikey) ... end,             -- 测试注入用
-- }
-- 返回 { ok, items = { {prefix,name,confidence} }, sent = { 网段... }, body = <请求体原文>, error }
-- body 只回给调用方（测试用来逐字节断言隐私面），不写页面、不落盘。
function M.infer(opts)
	opts = opts or {}

	local conf = M.config()
	local endpoint = trim(opts.endpoint or conf.endpoint or "")
	local model = trim(opts.model or conf.model or "")
	local apikey = opts.apikey
	if apikey == nil then apikey = conf.apikey or "" end

	-- ① 可发送项：公网 IPv4 网段 + 有 ASN 组织名。没有组织名（查询失败 / IPv6 / 域名）
	--    一律跳过 —— 发一个光秃秃的网段既没信息量，又白白多泄露一个编址。
	local sent, sentmap, lines = {}, {}, {}
	for _, it in ipairs(opts.items or {}) do
		if type(it) == "table" then
			local tgt = trim(it.target or "")
			local org = clean_org(it.org)
			if tgt ~= "" and org ~= "" and M.is_public_prefix(tgt) and not sentmap[tgt] then
				sentmap[tgt] = true
				sent[#sent + 1] = tgt
				lines[#lines + 1] = tgt .. "  " .. org
			end
		end
	end
	if #sent == 0 then
		-- 没有可发的东西 ⇒ **一个字节都不发**（连空请求也不发）。
		return { ok = true, items = {}, sent = {}, body = "" }
	end

	-- ③ 名称清单：只发名称文字。IP 字面量（含私网地址）一律剔除 —— 名称不该是地址。
	local names = {}
	for _, n in ipairs(opts.names or {}) do
		local v = trim(n)
		if v ~= "" and #v <= 64 and not v:find("[|%c]") and not looks_like_ip(v) then
			names[#names + 1] = v
		end
	end

	if endpoint == "" or model == "" then
		return { ok = false, error = T("请先在「设置」页配置 AI endpoint 与 model"), sent = sent }
	end
	if not M.valid_endpoint(endpoint) then
		return { ok = false, error = T("AI endpoint 无效（需以 http:// 或 https:// 开头）"), sent = sent }
	end

	local user = table.concat(lines, "\n")
	if #names > 0 then
		user = user .. "\n已配名称：" .. table.concat(names, "、")
	end

	local payload = json_encode({
		model       = model,
		temperature = 0,
		messages    = {
			{ role = "system", content = INFER_SYS_PROMPT },
			{ role = "user",   content = user },
		},
	})
	if not payload then
		return { ok = false, error = T("无法构造 AI 请求体"), sent = sent }
	end

	local http = opts.http or http_run
	local body, err = http("POST", endpoint:gsub("/+$", "") .. "/chat/completions", payload, apikey)
	if not body then
		return { ok = false, error = err, sent = sent, body = payload }
	end

	local parsed = json_decode(body)
	if type(parsed) ~= "table" then
		return { ok = false, error = T("AI 服务响应不是 JSON"), sent = sent, body = payload }
	end

	local content
	local choices = parsed.choices
	if type(choices) == "table" and type(choices[1]) == "table" then
		local msg = choices[1].message
		if type(msg) == "table" then content = msg.content end
		if type(content) ~= "string" then content = choices[1].text end
	end
	if type(content) ~= "string" then
		return { ok = false, error = T("AI 响应缺少内容（choices[0].message.content）"), sent = sent, body = payload }
	end

	local arr = extract_json_array(content)
	if not arr then
		return { ok = false, error = T("AI 响应里没有 JSON 数组"), sent = sent, body = payload }
	end
	local dec = json_decode(arr)
	local items, why = sanitize_infer(dec, sentmap)
	if not items then
		return { ok = false, error = why, sent = sent, body = payload }
	end
	return { ok = true, items = items, sent = sent, body = payload }
end

-- ======================================================================
-- round75（R75-D）：一键把推测结果归入条目
--
-- 语义（用户原话）：名称已存在 ⇒ 追加到该名称行的域名列表末尾；不存在 ⇒ 末尾新增一行。
-- 写回必须**最小编辑**：其它行逐字节保持原样（禁止「读出来 → pc_apps_rows 归一化 →
-- 整体重写」，那会把用户写的逗号、空名称行、缩进全洗掉）。
-- ======================================================================

local APPS_MAX = 4096

-- 与 common.sh 的 pc_apps_rows 同口径地算「某行的名称」：
-- `|` 前部分（控制字符转空格、折叠空格、去首尾空格）；为空则取域名列表首项；再空返回 nil。
local function row_name(line)
	local name, rest = line:match("^([^|]*)|(.*)$")
	if name == nil then
		name, rest = line, ""
	end
	name = name:gsub("%c", " "):gsub(" +", " "):gsub("^ ", ""):gsub(" $", "")
	if name ~= "" then return name end
	local first
	for tok in rest:gmatch("[^,%s]+") do first = tok break end
	if first and first ~= "" then return first end
	return nil
end

-- 该行域名 token 里是否已有 target（大小写不敏感）。
local function row_has_token(rest, target)
	local want = target:lower()
	for tok in rest:gmatch("[^,%s]+") do
		if tok:lower() == want then return true end
	end
	return false
end

-- 在行尾追加一个 token，但**行尾的 `\r` 必须留在行尾**（round75c R75B-L1）。
-- 直接 `line .. " " .. tgt` 在 CRLF 文件里会把目标接到 `\r` 之后 ⇒ 该行变成
-- `"甲|a.com\r c.com"`；而 `ui.lua` 的 `apps_rows()` 用 `[^\r\n]+` 切行 ⇒ 切成两行
-- ⇒ 条目列表凭空多出一条幽灵封锁名称、统计页多出名称子层。
-- `ui.lua` 只读不改：这里插到 `\r` 之前就够，不需要动解析侧。
local function add_before_eol(line, sep, tgt)
	if line:sub(-1) == "\r" then
		return line:sub(1, -2) .. sep .. tgt .. "\r"
	end
	return line .. sep .. tgt
end

-- target 校验：IPv4/IPv6 CIDR 或合法域名。
function M.valid_target(s)
	if type(s) ~= "string" then return false end
	local v = trim(s)
	if v == "" or #v > 128 then return false end
	if v:find("[%s%c|]") then return false end
	if v:match("^%d+%.%d+%.%d+%.%d+$") then return ipv4_octets(v) ~= nil end
	if v:match("^%d+%.%d+%.%d+%.%d+/%d+$") then
		local addr, bits = v:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
		if not addr then return false end
		local n = tonumber(bits)
		return ipv4_octets(addr) ~= nil and n ~= nil and n >= 0 and n <= 32
	end
	if v:find(":", 1, true) then
		-- IPv6（可带 /nn）：只做形态校验，不做完整规范化。
		local addr, bits = v:match("^([%x:%.]+)/(%d+)$")
		if addr then
			local n = tonumber(bits)
			return n ~= nil and n >= 0 and n <= 128
		end
		return v:match("^[%x:%.]+$") ~= nil
	end
	return M.is_domain(v)
end

-- 名称校验：非空、≤64、不含 `|`、不含任何控制字符（%c）。
function M.valid_name(s)
	if type(s) ~= "string" then return false end
	local v = trim(s)
	if v == "" or #v > 64 then return false end
	if v:find("|", 1, true) or v:find("%c") then return false end
	return true
end

-- 纯函数：给定 apps 原文，把 target 归到 name 名下。不碰 uci、不碰文件。
-- 返回 { ok, action = "appended"|"created"|"exists", text = <新文本>, error }
function M.apply_name(apps, target, name)
	if not M.valid_name(name) then
		return { ok = false, error = T("名称不合法（不能为空、不超过 64 字、不含竖线与换行）") }
	end
	if not M.valid_target(target) then
		return { ok = false, error = T("目标不合法（需是 IP、CIDR 或域名）") }
	end
	local tgt = trim(target)
	local want = trim(name):lower()
	local text = tostring(apps or "")

	-- 末尾换行要原样保留（round75b 必修 2）：以前 `("甲|a.com\n乙|b.com\n")` 写回会变成
	-- `"甲|a.com c.com\n乙|b.com"`（吃掉末尾 `\n`）。pc_apps_rows 不受影响，但违反
	-- 「最小编辑、不整体重写」原则 ⇒ 数出末尾换行数，写回时补上。
	local ntail, body = 0, text
	while #body > 0 and body:sub(-1) == "\n" do
		body = body:sub(1, -2)
		ntail = ntail + 1
	end

	-- 按行切，**保留每行原文**（含空行位置）。
	local lines = {}
	for line in (body .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end

	local hit = 0
	for i = 1, #lines do
		local nm = row_name(lines[i])
		if nm and nm:lower() == want then
			hit = i
			break
		end
	end

	local newtext
	if hit > 0 then
		local line = lines[hit]
		local name_part, rest = line:match("^([^|]*)|(.*)$")
		if name_part == nil then
			-- 纯名称行（无 `|`）：补上分隔符与目标（CRLF 行的 `\r` 留在行尾）。
			lines[hit] = add_before_eol(line, "|", tgt)
			newtext = table.concat(lines, "\n")
		elseif row_has_token(rest, tgt) then
			-- 该行域名列表里已有这个目标 ⇒ 不写 uci，如实返回 exists。
			return { ok = true, action = "exists", text = text }
		else
			-- 追加到该行域名列表**末尾**（用空格分隔；pc_apps_rows 逗号/空格等价）。
			lines[hit] = add_before_eol(line, " ", tgt)
			newtext = table.concat(lines, "\n")
		end
	else
		-- 名称不存在 ⇒ 末尾新增一行 `名称|目标`。
		lines[#lines + 1] = trim(name) .. "|" .. tgt
		newtext = table.concat(lines, "\n")
	end

	if ntail > 0 then newtext = newtext .. string.rep("\n", ntail) end
	if #newtext > APPS_MAX then
		return { ok = false, error = T("条目内容超过 4096 字上限，请精简后再归入") }
	end
	return { ok = true, action = (hit > 0 and "appended" or "created"), text = newtext }
end

-- 写 uci + 后台触发重建。
-- opts = { key = "weburl_<i>", target, name, uci = <cursor>, reload = function() end }
-- 返回 { ok, action, rebuild = "started"|"skipped", error }
function M.apply_entry(opts)
	opts = opts or {}
	local key = trim(opts.key or "")
	-- key 白名单（防注入）：只接受 weburl_<数字>。
	if not key:match("^weburl_%d+$") then
		return { ok = false, error = T("条目编号不合法") }
	end
	local idx = tonumber(key:match("^weburl_(%d+)$"))

	local uci = opts.uci
	if not uci then
		local ok, c = pcall(require, "luci.model.uci")
		if not ok then return { ok = false, error = T("无法访问配置") } end
		uci = c.cursor()
	end

	-- 按 pc_uget 同口径定位真实节名：weburl_<idx> 里的 idx 是「该类型第几个节」（0 起）。
	local sec, i = nil, 0
	uci:foreach("parentcontrol", "weburl", function(s)
		if i == idx then sec = s[".name"] end
		i = i + 1
	end)
	if not sec then
		return { ok = false, error = T("找不到该条目（可能已被删除，请刷新页面）") }
	end

	local apps = uci:get("parentcontrol", sec, "apps") or ""
	local res = M.apply_name(apps, opts.target, opts.name)
	if not res.ok then return { ok = false, error = res.error } end
	if res.action == "exists" then
		-- 已经是这个归属 ⇒ 不写 uci、不触发重建（避免无意义的 15–30 秒重建）。
		return { ok = true, action = "exists", rebuild = "skipped" }
	end

	uci:set("parentcontrol", sec, "apps", res.text)
	local cok = uci:commit("parentcontrol")
	if cok == false then
		return { ok = false, error = T("保存配置失败（uci commit 未成功）") }
	end

	-- reload = stop; start，真机 15–26 秒 ⇒ 必须后台起、立刻返回，否则 LuCI 请求会挂死。
	local reload = opts.reload
	if reload then reload() end
	return { ok = true, action = res.action, rebuild = "started" }
end

return M
