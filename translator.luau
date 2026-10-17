--!nonstrict
-- 启动器翻译搜索源（前缀 /tr）。
--
-- 输入形态：
--   /tr <文本>                 → 翻成设置里的默认目标语言
--   /tr <语言> <文本>          → 翻成指定语言（zh / en / 日语 / ja …）
--
-- 流程：解析 → 命中有没有缓存 → 预置"翻译中"占位 → 异步调后端 → 回填结果。
-- 只有最后一次查询的结果会被采纳（seq 守卫），避免慢请求盖掉新结果。
--
-- 结果项的 id 里带着完整译文（urlEncode 后），所以回车复制不需要任何常驻状态，
-- 启动器重启后历史项依然可用。

local config = require("./lib/config.luau")
local langs = require("./lib/langs.luau")
local engine = require("./lib/engine.luau")

local PREFIX = "tr"

local seq = 0       -- 查询序号
local cache = {}    -- key = 目标语言 .. "\0" .. 原文
local state = { raw = "", results = {} }

--- 取一条界面文案；subst 是命名占位表（{name} 形式）。
local function L(key, subst)
    return noctalia.tr(key, subst)
end

local function engineLabel(kind)
    if kind == "hub" then
        return noctalia.tr("engine.hub")
    elseif kind == "openai" then
        return noctalia.tr("engine.openai")
    elseif kind == "google" then
        return noctalia.tr("engine.google")
    end
    return noctalia.tr("engine.auto")
end

--- 结果项 id：各段都不含 ":"，这样 gmatch("[^:]+") 能稳定还原。
local function makeId(action, target, engineKind, text)
    return table.concat({
        PREFIX,
        action,
        target or "-",
        engineKind or "-",
        noctalia.string.urlEncode(text or ""),
    }, "::")
end

--- 解析查询：返回 目标语言代码?, 正文。
--- 只有当第一个 token 是语言 **且** 后面还有正文时，才把它当语言。
local function parse(raw)
    local body = noctalia.string.trim(raw)
    if body == "" then
        return nil, ""
    end
    local first, rest = body:match("^(%S+)%s+(.*)$")
    if first then
        local code = langs.resolve(first)
        local tail = noctalia.string.trim(rest)
        if code and tail ~= "" then
            return code, tail
        end
    end
    return nil, noctalia.string.trim(body)
end

local function publish()
    launcher.setResults(state.raw, state.results)
end

--- 译文第一行作为标题，行数多时在副标题里注明。
local function headLine(text)
    local first, count = text:match("^([^\n]*)(.*)$")
    if first == nil then
        first = text
    end
    local extra = 0
    for _ in (count or ""):gmatch("\n") do
        extra += 1
    end
    if #first > 200 then
        first = first:sub(1, 200) .. "…"
    end
    return first, extra
end

local function subtitleFor(record, extraLines)
    local parts = { "→ " .. langs.name(record.target) }
    if extraLines > 0 then
        table.insert(parts, L("result.more_lines", { n = extraLines }))
    end
    if config.setting("show_engine") then
        local label = engineLabel(record.engine)
        if record.model and record.model ~= "" then
            label = label .. " · " .. record.model
        end
        table.insert(parts, label)
    end
    return table.concat(parts, " · ")
end

local function resultRows(record, sourceText)
    local title, extraLines = headLine(record.text)
    local rows = {
        {
            id = makeId("copy", record.target, record.engine, record.text),
            title = title,
            subtitle = subtitleFor(record, extraLines),
            glyph = "language",
            category = noctalia.tr("category.result"),
        },
        {
            id = makeId("copysrc", record.target, record.engine, sourceText),
            title = noctalia.tr("result.copy_source"),
            subtitle = sourceText,
            glyph = "content_copy",
            category = noctalia.tr("category.result"),
        },
    }
    return rows
end

local function loadingRows(text, target)
    return {
        {
            id = makeId("busy", target, "-", text),
            title = noctalia.tr("result.translating"),
            subtitle = "→ " .. langs.name(target) .. " · " .. engineLabel(config.setting("engine")),
            glyph = "hourglass",
            category = noctalia.tr("category.result"),
        },
    }
end

local function errorRows(message)
    return {
        {
            id = makeId("busy", "-", "-", ""),
            title = noctalia.tr("result.failed"),
            subtitle = message,
            glyph = "error",
            category = noctalia.tr("category.result"),
        },
    }
end

--- 提示行的副标题：说清当前会走哪条后端。
local function hintSubtitle()
    local kind = config.setting("engine")
    if kind == "auto" then
        return L("hint.subtitle_auto", { engine = engineLabel("auto"), target = langs.name(config.setting("target_lang")) })
    end
    return L("hint.subtitle", { engine = engineLabel(kind), target = langs.name(config.setting("target_lang")) })
end

local function hintRows()
    local rows = {
        {
            id = makeId("busy", "-", "-", ""),
            title = noctalia.tr("hint.title"),
            subtitle = hintSubtitle(),
            glyph = "language",
            category = noctalia.tr("category.result"),
        },
    }
    return rows
end


--- 启动器查询入口。
function onQuery(raw)
    state.raw = raw
    local target, text = parse(raw)
    if text == "" then
        state.results = hintRows()
        publish()
        return
    end

    local to = target or config.setting("target_lang")
    if config.setting("auto_flip") and to == "zh" and langs.isCjk(text) then
        to = "en"
    end

    local key = to .. "\0" .. text
    local hit = cache[key]
    if hit then
        state.results = resultRows(hit, text)
        publish()
        return
    end

    seq += 1
    local mine = seq
    state.results = loadingRows(text, to)
    publish()

    engine.translate({
        kind = config.setting("engine"),
        text = text,
        target = to,
    }, function(translated, err, meta)
        if mine ~= seq then
            return -- 用户已经输入了新查询，丢弃这次结果
        end
        if err or not translated then
            state.results = errorRows(err or noctalia.tr("result.failed"))
            publish()
            return
        end
        local record = {
            text = translated,
            target = to,
            engine = meta and meta.engine or "google",
            model = meta and meta.model,
        }
        cache[key] = record
        state.results = resultRows(record, text)
        publish()
    end)
end

--- 回车执行：复制译文 / 复制原文。
function onActivate(id)
    local fields = {}
    for piece in tostring(id):gmatch("[^:]+") do
        table.insert(fields, piece)
    end
    if fields[1] ~= PREFIX then
        return
    end
    local action = fields[2]
    if action ~= "copy" and action ~= "copysrc" then
        return
    end
    local text = noctalia.string.urlDecode(fields[5] or "")
    if text == "" then
        return
    end
    noctalia.copyToClipboard(text)
    noctalia.notify(
        noctalia.tr("notify.copied.title"),
        if action == "copy" then noctalia.tr("notify.copied.body") else noctalia.tr("notify.copied_source.body")
    )
end
