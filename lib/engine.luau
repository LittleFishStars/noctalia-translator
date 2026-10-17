--!nonstrict
-- 翻译后端。三种实现统一成一个入口：
--
--   hub     「大模型控制中心」（ylxc/llm-hub）的 OpenAI 兼容接口，路由/配额/统计都在它那边
--   openai  任意 OpenAI 兼容 API 直连（api_base + api_key + model）
--   google  Google 翻译公开端点，免密钥，作为没有任何大模型配置时的兜底
--
--   M.translate({ kind = "auto"|"hub"|"openai"|"google", text, target, model = string? },
--               function(text, err, meta) ... end)
--   meta = { engine = string, model = string?, unavailable = boolean? }
--          unavailable 表示"这条后端还没准备好"（没装/没起/没填 Key），auto 模式据此换下一条。

local config = require("./config.luau")
local langs = require("./langs.luau")
local hub = require("./hub.luau")

local M = {}

local DEFAULT_PROMPT = "You are a translation engine. Translate the user's text into {lang} "
    .. "({code}). Output only the translation - no explanation, no quotes, no extra formatting. "
    .. "Keep the original line breaks, numbers, URLs, code and proper nouns intact."

--- 系统提示；设置里写了自定义提示就用它，其中 {lang} 会替换成目标语言名。
local function systemPrompt(target)
    local custom = config.setting("prompt")
    if custom ~= "" then
        local langName = langs.name(target)
        local at = custom:find("{lang}", 1, true)
        if at then
            return custom:sub(1, at - 1) .. langName .. custom:sub(at + 6)
        end
        return custom
    end
    local template = DEFAULT_PROMPT
    local langName = langs.name(target)
    local at = template:find("{lang}", 1, true)
    local head = template:sub(1, at - 1) .. langName .. template:sub(at + 6)
    local codeAt = head:find("{code}", 1, true)
    if codeAt then
        head = head:sub(1, codeAt - 1) .. target .. head:sub(codeAt + 6)
    end
    return head
end

--- OpenAI 兼容响应里取正文；content 可能是字符串，也可能是分段数组。
local function chatContent(body)
    local decoded = noctalia.json.decode(body)
    if type(decoded) ~= "table" or type(decoded.choices) ~= "table" then
        return nil
    end
    local message = decoded.choices[1]
    message = if type(message) == "table" then message.message else nil
    if type(message) ~= "table" then
        return nil
    end
    local content = message.content
    if type(content) == "string" then
        return content
    end
    if type(content) == "table" then
        local parts = {}
        for _, segment in content do
            if type(segment) == "table" and type(segment.text) == "string" then
                table.insert(parts, segment.text)
            elseif type(segment) == "string" then
                table.insert(parts, segment)
            end
        end
        if #parts > 0 then
            return table.concat(parts)
        end
    end
    return nil
end

--- 清理模型输出：去空白、去整体包裹的引号、去偶发的"翻译："前缀。
local function clean(raw)
    if type(raw) ~= "string" then
        return nil
    end
    local text = noctalia.string.trim(raw)
    if text == "" then
        return nil
    end
    local openLen, closeLen = 0, 0
    if #text >= 2 and text:sub(1, 1) == '"' and text:sub(-1) == '"' then
        openLen, closeLen = 1, 1
    elseif text:find("^“") and text:find("”$") then
        openLen, closeLen = 3, 3
    elseif #text >= 2 and text:sub(1, 1) == "'" and text:sub(-1) == "'" then
        openLen, closeLen = 1, 1
    end
    if openLen > 0 and #text > openLen + closeLen then
        text = noctalia.string.trim(text:sub(1 + openLen, #text - closeLen))
    end
    text = noctalia.string.trim((text:gsub("^[Tt]ranslation[:：]%s*", "")))
    return if text == "" then nil else text
end

--- 统一的 HTTP 错误文案。
local function httpError(res, engine)
    local label = noctalia.tr("engine." .. engine)
    if not res.ok or res.status == 0 then
        return noctalia.tr("err.unreachable")
    end
    if res.status == 401 or res.status == 403 then
        return noctalia.tr("err.auth", { engine = label })
    end
    if res.status == 404 then
        return noctalia.tr("err.not_found", { engine = label })
    end
    if res.status == 429 then
        return noctalia.tr("err.rate_limit")
    end
    if res.status >= 500 then
        return noctalia.tr("err.server")
    end
    return noctalia.tr("err.status", { status = tostring(res.status) })
end

--- 向 OpenAI 兼容端点发一次 chat 请求。
local function chatRequest(opts, endpoint, key, model, engine, onDone)
    local headers = { "Content-Type: application/json" }
    if type(key) == "string" and key ~= "" then
        table.insert(headers, "Authorization: Bearer " .. key)
    end
    local body = noctalia.json.encode({
        model = model,
        messages = {
            { role = "system", content = systemPrompt(opts.target) },
            { role = "user", content = opts.text },
        },
        temperature = 0,
        stream = false,
    })
    noctalia.http({ method = "POST", url = endpoint, headers = headers, body = body }, function(res)
        if not res.ok or res.status >= 400 then
            onDone(nil, httpError(res, engine), { engine = engine })
            return
        end
        local text = clean(chatContent(res.body))
        if not text then
            onDone(nil, noctalia.tr("err.bad_response"), { engine = engine })
            return
        end
        onDone(text, nil, { engine = engine, model = model })
    end)
end

--- 大模型控制中心：先探测（目录 / 端口 / 密钥 / 模型目录），再打它的 /v1/chat/completions。
local function fetchHub(opts, onDone)
    hub.probe(function(probe)
        if not probe.ok then
            local message
            if not hub.installed() then
                message = noctalia.tr("err.no_hub")
            elseif probe.reason == "http_401" or probe.reason == "http_403" then
                message = noctalia.tr("err.hub_auth")
            else
                message = noctalia.tr("err.hub_down", { url = probe.base })
            end
            onDone(nil, message, { engine = "hub", unavailable = true })
            return
        end

        local model = opts.model or config.setting("hub_model")
        if type(model) ~= "string" or model == "" then
            model = probe.model
        end
        if type(model) ~= "string" or model == "" then
            -- 控制中心的 chat 接口要求 model 字段（它按模型名做路由）
            onDone(nil, noctalia.tr("err.need_hub_model"), { engine = "hub", unavailable = true })
            return
        end
        chatRequest(opts, probe.base .. "/v1/chat/completions", probe.key, model, "hub", onDone)
    end)
end

--- 直连 OpenAI 兼容 API。
local function fetchOpenAI(opts, onDone)
    local key = config.setting("api_key")
    local model = opts.model or config.setting("model")
    if key == "" then
        onDone(nil, noctalia.tr("err.need_key"), { engine = "openai", unavailable = true })
        return
    end
    if model == "" then
        onDone(nil, noctalia.tr("err.need_model"), { engine = "openai", unavailable = true })
        return
    end
    local base = config.trimBase(config.setting("api_base"))
    chatRequest(opts, base .. "/chat/completions", key, model, "openai", onDone)
end

--- Google 翻译公开端点（免密钥），作为兜底。
local function fetchGoogle(opts, onDone)
    local url = "https://translate.googleapis.com/translate_a/single?client=dict-chrome-ex&sl=auto&tl="
        .. noctalia.string.urlEncode(opts.target)
        .. "&dt=t&q="
        .. noctalia.string.urlEncode(opts.text)

    noctalia.http({ url = url }, function(res)
        if not res.ok or res.status >= 400 then
            onDone(nil, httpError(res, "google"), { engine = "google" })
            return
        end
        local decoded = noctalia.json.decode(res.body)
        if type(decoded) ~= "table" or type(decoded[1]) ~= "table" then
            onDone(nil, noctalia.tr("err.bad_response"), { engine = "google" })
            return
        end
        local parts = {}
        for _, segment in decoded[1] do
            if type(segment) == "table" and type(segment[1]) == "string" then
                table.insert(parts, segment[1])
            end
        end
        if #parts == 0 then
            onDone(nil, noctalia.tr("err.bad_response"), { engine = "google" })
            return
        end
        local source = if type(decoded[3]) == "string" then decoded[3]:lower() else nil
        onDone(table.concat(parts), nil, { engine = "google", source = source })
    end)
end

--- 没有控制中心可用时，auto 该走哪条：配好直连就用直连，否则 Google。
local function implicitKind()
    if config.setting("api_key") ~= "" and config.setting("model") ~= "" then
        return "openai"
    end
    return "google"
end

local function run(kind, opts, onDone)
    if kind == "hub" then
        fetchHub(opts, onDone)
    elseif kind == "openai" then
        fetchOpenAI(opts, onDone)
    else
        fetchGoogle(opts, onDone)
    end
end

--- 按设置分派。auto：有控制中心就优先用它，否则直连，最后 Google。
function M.translate(opts, onDone)
    local kind = opts.kind or "auto"
    if kind ~= "auto" then
        run(kind, opts, onDone)
        return
    end

    if not hub.installed() then
        run(implicitKind(), opts, onDone)
        return
    end

    fetchHub(opts, function(text, err, meta)
        if text then
            onDone(text, nil, meta)
            return
        end
        if meta and meta.unavailable then
            -- 控制中心没装/没起/缺模型：静默换兜底后端，别让翻译用不了
            run(implicitKind(), opts, onDone)
            return
        end
        onDone(nil, err, meta)
    end)
end

return M
