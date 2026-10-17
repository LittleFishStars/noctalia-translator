# Translator · 启动器翻译搜索源

在 Noctalia 启动器里敲 `/tr`，直接用大模型把文本翻成目标语言；本机装了大模型控制中心
（[`ylxc/llm-hub`](https://github.com/LittleFishStars/noctalia-llm-hub)）的话，请求会**转交给控制中心**，
路由、配额、用量统计统一在控制中心里看。

```
/tr 中文 The quick brown fox jumps over the lazy dog
        ↓
敏捷的棕色狐狸跃过那只懒狗        → 中文 · 大模型控制中心 · deepseek-flash
复制原文                          The quick brown fox jumps over the lazy dog
```

- **三条后端随手切**：`auto`（自动挑最合适的）、`hub`（强制走大模型控制中心）、
  `openai`（任意 OpenAI 兼容端点）、`google`（免费公开端点，无需密钥）。
- **自动探测控制中心**：不用手填地址和密钥——先看设置，再看控制中心写在宿主状态目录里的
  `llmhubd.port` 端口文件，再看默认端口；密钥读控制中心自己的配置；模型名从 `/v1/models`
  里挑第一个可用的。
- **不阻塞输入**：停止输入 300ms 才发请求，只有最后一次查询的结果会被采纳，慢请求不会盖掉新结果。
- **结果可复制**：回车复制译文并弹通知，第二条「复制原文」一键拿回原文。
- **语言随便写**：`zh`、`中文`、`Chinese`、`en`、`英语`、`日语`、`ja`… 都能认；
  不写语言就走默认目标语言，**中文输入自动翻成英文**（可关）。

---

## 安装

插件已在本机 `~/.local/share/noctalia/plugins/ylxc-translator`，宿主会自动发现：

```bash
noctalia msg plugins list | grep translator      # 确认已被识别
noctalia msg plugins enable ylxc/translator       # 启用
```

> 注意：官方也有一个 `noctalia/translator`，两者前缀都是 `tr`，同时启用会抢同一个前缀。
> 想换前缀就改 `plugin.toml` 里 `[[launcher_provider]].prefix`（比如 `fy`），再重新启用插件。

---

## 用法

打开启动器（默认快捷键可在「设置 → 外壳 → 启动器」里看），输入：

| 输入 | 效果 |
| --- | --- |
| `/tr 今天天气不错` | 翻成设置里的默认目标语言（默认中文） |
| `/tr en 你好，世界` | 翻成英语 |
| `/tr 日语 早上好` | 翻成日语 |
| `/tr` | 只显示提示：当前会走哪条后端、翻成什么语言 |

- **回车**：复制译文（弹通知提示已复制）。
- **下移一格回车**：复制原文。
- 译文有多行时，第一条只显示首行，副标题里标注「还有 N 行」，回车复制的仍是完整译文。

---

## 设置

「设置 → 插件 → Translator」：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `target_lang` | `zh` | 默认目标语言，支持代码或别名（`zh`/`中文`/`en`/`英文`…） |
| `engine` | `auto` | `auto` / `hub` / `openai` / `google`，见下节 |
| `hub_url` | 空 | 控制中心地址；留空＝自动探测（端口文件 → 默认端口） |
| `hub_model` | 空 | 让控制中心用哪个模型；留空＝自动挑第一个可用的 |
| `hub_api_key` | 空 | 控制中心的访问密钥；留空＝读控制中心自己的配置 |
| `api_base` | `https://api.openai.com/v1` | OpenAI 兼容端点（DeepSeek、Moonshot、本地 vLLM… 都行） |
| `api_key` | 空 | 上面那个端点的密钥 |
| `model` | 空 | 上面那个端点用的模型名 |
| `prompt` | 空 | 自定义系统提示词，可写 `{lang}` 占位；留空用内置提示词 |
| `auto_flip` | 开 | 目标语言是中文、而输入本身是中日韩文字时，自动改翻成英文 |
| `show_engine` | 开 | 在结果副标题里显示实际走了哪条后端、用了哪个模型 |

`hub_*` 三项只在 `engine` 为 `auto` / `hub` 时出现在设置界面，`api_*` / `model` 只在
`auto` / `openai` 时出现（`visible_when`）。

---

## 后端怎么选

`auto`（默认）按下面的顺序挑：

1. **大模型控制中心**——装了就优先走它（地址、密钥、模型全自动探测）。
2. **OpenAI 兼容端点**——填了 `api_key` 和 `model` 就用它。
3. **Google 公开端点**——兜底，不需要密钥，但要求本机能访问 `translate.googleapis.com`
   （国内直连通常不通，此时会提示「连不上翻译服务」）。

强制指定时，`hub` 不可用会直接报错并说明原因（没装 / 没运行 / 密钥不对），
不会静默降级——免得你以为在用控制中心，其实走了别的路。

---

## 工作原理

```
启动器 /tr …  →  translator.luau（解析语言、查缓存、预置「翻译中」占位）
                     ↓
                lib/engine.luau（三种后端统一入口，异步回调）
                     ↓
   hub: lib/hub.luau 探测 → POST {hub}/v1/chat/completions
   openai:                POST {api_base}/chat/completions
   google:                GET  translate.googleapis.com/translate_a/single
                     ↓
                回填结果；结果项 id 里带着完整译文，重启后历史项依然能复制
```

- 请求体：`messages = [system 提示词, user 原文]`、`temperature = 0`、`stream = false`，
  从 `choices[0].message.content` 取译文（数组形式的 content 也会拼起来）。
- 系统提示词要求模型只输出译文、不要解释；`prompt` 里写 `{lang}` 会替换成目标语言名。
- 译文会去掉模型偶尔加的包裹引号。

## 目录结构

```
plugin.toml           清单：启动器搜索源 + 11 项设置
translator.luau       入口：解析 → 缓存 → 异步翻译 → 回填
lib/config.luau       设置读取（逐键 getConfig，便于清单静态核对）
lib/langs.luau        语言别名表与识别
lib/hub.luau          大模型控制中心探测（目录 / 端口 / 密钥 / 模型）
lib/engine.luau       三种后端统一调用
translations/*.json   中英文界面文案
```

## 自测

```bash
python3 -c "import json,sys;[json.load(open(f)) for f in ['translations/en.json','translations/zh-Hans.json']]"
noctalia msg plugins disable ylxc/translator && noctalia msg plugins enable ylxc/translator
noctalia msg panel-open launcher "/tr 中文 hello world"      # 看启动器里的结果
```

## 许可证

MIT © 2026 ylxc
