--!nonstrict
-- 插件设置的统一读取口。
--
-- 清单静态检查会核对每个 [[setting]] 的 key 是否在代码里被 noctalia.getConfig("<key>")
-- 以字面量读到，所以这里逐键分支，不做动态拼串。每个键都给了与 plugin.toml 一致的兜底值：
-- 设置尚未播种（或类型不对）时也不会把 nil 传进下游。

local M = {}

local function trimmed(key)
    local v = noctalia.getConfig(key)
    if type(v) == "string" then
        return noctalia.string.trim(v)
    end
    return ""
end

--- 读取一个设置；未知键返回 nil。
function M.setting(key)
    if key == "target_lang" then
        local v = trimmed("target_lang")
        return if v ~= "" then v else "zh"
    elseif key == "engine" then
        local v = trimmed("engine")
        if v == "hub" or v == "openai" or v == "google" then
            return v
        end
        return "auto"
    elseif key == "hub_url" then
        -- 空串 = 自动探测控制中心的端口
        return trimmed("hub_url")
    elseif key == "hub_model" then
        -- 空串 = 自动挑控制中心里第一个可用模型
        return trimmed("hub_model")
    elseif key == "hub_api_key" then
        -- 空串 = 尝试读控制中心自己的配置
        return trimmed("hub_api_key")
    elseif key == "api_base" then
        local v = trimmed("api_base")
        return if v ~= "" then v else "https://api.openai.com/v1"
    elseif key == "api_key" then
        return trimmed("api_key")
    elseif key == "model" then
        return trimmed("model")
    elseif key == "prompt" then
        -- 自定义系统提示；支持 {lang} 占位（目标语言）
        return trimmed("prompt")
    elseif key == "auto_flip" then
        local v = noctalia.getConfig("auto_flip")
        return if type(v) == "boolean" then v else true
    elseif key == "show_engine" then
        local v = noctalia.getConfig("show_engine")
        return if type(v) == "boolean" then v else true
    end
    return nil
end

--- 去掉结尾斜杠，便于拼接路径。
function M.trimBase(base)
    local b = noctalia.string.trim(base or "")
    return (b:gsub("/+$", ""))
end

return M
