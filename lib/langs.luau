--!nonstrict
-- 语言表与语言识别。
--
-- 查询里第一个词如果是语言（别名、"zh" 这类代码、或"中文"这样的写法），就当成目标语言，
-- 其余部分才是正文。任何 2–3 个字母的 token 都直接透传给后端，所以冷门语言也能用。

local M = {}

-- code → 别名（小写比较）。别名含英文、法文（官方表沿袭）与中文写法。
local LANGUAGES = {
    ar = { "arabic", "arabe", "阿拉伯语" },
    bg = { "bulgarian", "bulgare", "保加利亚语" },
    cs = { "czech", "tcheque", "捷克语" },
    da = { "danish", "danois", "丹麦语" },
    de = { "german", "allemand", "deutsch", "德语" },
    el = { "greek", "grec", "希腊语" },
    en = { "english", "anglais", "英语", "英文" },
    es = { "spanish", "espagnol", "espanol", "西班牙语" },
    et = { "estonian", "estonien", "爱沙尼亚语" },
    fa = { "persian", "farsi", "persan", "波斯语" },
    fi = { "finnish", "finnois", "芬兰语" },
    fr = { "french", "francais", "法语" },
    he = { "hebrew", "hebreu", "希伯来语" },
    hi = { "hindi", "印地语" },
    hu = { "hungarian", "hongrois", "匈牙利语" },
    id = { "indonesian", "indonesien", "印尼语" },
    it = { "italian", "italien", "意大利语" },
    ja = { "japanese", "japonais", "日语", "日文", "日本語" },
    ko = { "korean", "coreen", "韩语", "韩文", "한국어" },
    lt = { "lithuanian", "lituanien", "立陶宛语" },
    lv = { "latvian", "letton", "拉脱维亚语" },
    nl = { "dutch", "neerlandais", "荷兰语" },
    no = { "norwegian", "norvegien", "挪威语" },
    pl = { "polish", "polonais", "波兰语" },
    pt = { "portuguese", "portugais", "葡萄牙语" },
    ro = { "romanian", "roumain", "罗马尼亚语" },
    ru = { "russian", "russe", "俄语" },
    sk = { "slovak", "slovaque", "斯洛伐克语" },
    sl = { "slovenian", "slovene", "slovène", "斯洛文尼亚语" },
    sv = { "swedish", "suedois", "瑞典语" },
    th = { "thai", "thailandais", "泰语" },
    tr = { "turkish", "turc", "土耳其语" },
    uk = { "ukrainian", "ukrainien", "乌克兰语" },
    vi = { "vietnamese", "vietnamien", "越南语" },
    zh = { "chinese", "chinois", "mandarin", "中文", "汉语", "简体中文", "繁體中文", "繁体中文" },
}

-- 常见语言的短名，用于结果副标题与提示大模型。
local NAMES = {
    ar = "阿拉伯语", bg = "保加利亚语", cs = "捷克语", da = "丹麦语", de = "德语",
    el = "希腊语", en = "英语", es = "西班牙语", et = "爱沙尼亚语", fa = "波斯语",
    fi = "芬兰语", fr = "法语", he = "希伯来语", hi = "印地语", hu = "匈牙利语",
    id = "印尼语", it = "意大利语", ja = "日语", ko = "韩语", lt = "立陶宛语",
    lv = "拉脱维亚语", nl = "荷兰语", no = "挪威语", pl = "波兰语", pt = "葡萄牙语",
    ro = "罗马尼亚语", ru = "俄语", sk = "斯洛伐克语", sl = "斯洛文尼亚语",
    sv = "瑞典语", th = "泰语", tr = "土耳其语", uk = "乌克兰语", vi = "越南语",
    zh = "中文",
}

--- token → 语言代码；不是语言就返回 nil。
function M.resolve(token)
    local lower = tostring(token):lower()
    for code, aliases in LANGUAGES do
        if code == lower or table.find(aliases, lower) then
            return code
        end
    end
    -- 2–3 个字母的代码（de、jpn…）原样交给后端
    if lower:match("^%a%a%a?$") then
        return lower
    end
    return nil
end

--- 给人和给大模型看的语言名；未知代码回落到代码本身。
function M.name(code)
    return NAMES[code] or code
end

--- 文本是否以中日韩文字为主（用于"目标语言与原文相同就自动翻转"）。
function M.isCjk(text)
    local total, cjk = 0, 0
    for i = 1, #text do
        local b = text:byte(i)
        total += 1
        if (b >= 0xE4 and b <= 0xE9) then
            cjk += 1
        end
    end
    return total > 0 and (cjk / total) >= 0.2
end

return M
