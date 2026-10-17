--!nonstrict
-- 「大模型控制中心」（ylxc/llm-hub）探测。
--
-- 翻译源不直接读别的插件的内存状态（宿主没有这种接口），而是按控制中心自己写下的
-- 运行时文件来判断：插件目录是否存在、llmhubd.port 写了哪个端口、配置里的 server.api_key、
-- 以及 /health 与 /v1/models 两个公开端点。任何一步失败都降级为"不可用"，由调用方兜底。

local config = require("./config.luau")

local M = {}

local PLUGIN_DIR_NAME = "ylxc-llm-hub"
local PROBE_TTL_MS = 60000 -- 探测结果缓存，避免每次敲键盘都打一次 /health
local probeCache = nil

--- 控制中心插件目录：优先取与本插件同级的目录，回落到默认安装位置。
function M.pluginDir()
    local mine = noctalia.pluginDir()
    if type(mine) == "string" and mine ~= "" then
        local parent = mine:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            return parent .. "/" .. PLUGIN_DIR_NAME
        end
    end
    return "~/.local/share/noctalia/plugins/" .. PLUGIN_DIR_NAME
end

function M.installed()
    return noctalia.fileExists(M.pluginDir() .. "/plugin.toml")
end

--- 控制中心可能把运行时数据放在这几个位置（宿主 per-plugin 数据目录优先）。
local function dataDirs()
    local dirs = {}
    local xdg = noctalia.getenv("XDG_STATE_HOME")
    if type(xdg) == "string" and xdg ~= "" then
        table.insert(dirs, xdg .. "/noctalia/plugins/data/ylxc/llm-hub")
        table.insert(dirs, xdg .. "/llm-hub")
    end
    table.insert(dirs, "~/.local/state/noctalia/plugins/data/ylxc/llm-hub")
    table.insert(dirs, "~/.local/state/llm-hub")
    return dirs
end

--- 守护进程端口：读 llmhubd.port；读不到就交给调用方用配置或 8787。
function M.readPort()
    for _, dir in dataDirs() do
        local txt = noctalia.readFile(dir .. "/llmhubd.port")
        local n = tonumber((txt or ""):match("^%s*(%d+)"))
        if n then
            return n
        end
    end
    return nil
end

--- 控制中心的配置文件（server.port / server.api_key）。
function M.readHubConfig()
    local candidates = {}
    local xdg = noctalia.getenv("XDG_CONFIG_HOME")
    if type(xdg) == "string" and xdg ~= "" then
        table.insert(candidates, xdg .. "/llm-hub/config.json")
    end
    table.insert(candidates, "~/.config/llm-hub/config.json")
    for _, path in candidates do
        local txt = noctalia.readFile(path)
        if type(txt) == "string" and txt ~= "" then
            local cfg = noctalia.json.decode(txt)
            if type(cfg) == "table" then
                return cfg
            end
        end
    end
    return nil
end

--- 从 /v1/models 里挑一个模型名：跳过 mock 与已禁用的，优先第一个可用的。
local function pickModel(body)
    local decoded = noctalia.json.decode(body)
    if type(decoded) ~= "table" or type(decoded.data) ~= "table" then
        return nil
    end
    local fallback = nil
    for _, item in decoded.data do
        if type(item) == "table" and type(item.id) == "string" then
            local isMock = item.id:match("^mock") ~= nil
            if item.enabled ~= false and not isMock then
                return item.id
            end
            if fallback == nil and item.enabled ~= false then
                fallback = item.id
            end
        end
    end
    return fallback
end

local function finish(result, cb)
    probeCache = result
    cb(result)
end

--- 探测控制中心是否可用。
--- 回调收到 { ok = boolean, base = string, key = string, model = string?, version = string?, reason = string? }
function M.probe(cb)
    local now = noctalia.nowMs()
    if probeCache and (now - probeCache.at) < PROBE_TTL_MS then
        cb(probeCache)
        return
    end

    local hubCfg = M.readHubConfig()
    local serverCfg = if type(hubCfg) == "table" and type(hubCfg.server) == "table" then hubCfg.server else {}

    -- 端点：设置里的 hub_url 优先，其次运行时端口文件，再其次配置，最后 8787
    local base = config.setting("hub_url")
    if base == "" then
        local port = M.readPort() or tonumber(serverCfg.port) or 8787
        base = "http://127.0.0.1:" .. tostring(math.floor(port))
    end
    base = config.trimBase(base)

    -- 密钥：设置优先，其次控制中心自己的配置（留空表示控制中心没开鉴权）
    local key = config.setting("hub_api_key")
    if key == "" and type(serverCfg.api_key) == "string" then
        key = noctalia.string.trim(serverCfg.api_key)
    end

    local result = { at = now, ok = false, base = base, key = key, model = nil, version = nil }
    local headers = {}
    if key ~= "" then
        table.insert(headers, "Authorization: Bearer " .. key)
    end

    noctalia.http({ url = base .. "/health", headers = headers }, function(health)
        if not health.ok or health.status ~= 200 then
            result.reason = if health.ok then "http_" .. tostring(health.status) else "unreachable"
            result.at = noctalia.nowMs()
            finish(result, cb)
            return
        end

        local info = noctalia.json.decode(health.body)
        if type(info) == "table" then
            result.version = if type(info.version) == "string" then info.version else nil
        end

        -- /v1/models 用于自动挑模型；拿不到也不影响翻译（后端会走自己的默认路由）
        noctalia.http({ url = base .. "/v1/models", headers = headers }, function(models)
            if models.ok and models.status == 200 then
                result.model = pickModel(models.body)
            end
            result.ok = true
            result.at = noctalia.nowMs()
            finish(result, cb)
        end)
    end)
end

--- 测试/调试用：清掉探测缓存。
function M.invalidate()
    probeCache = nil
end

return M
