# 06 — 插件生态

> 本系列文档每篇自洽，可独立阅读。末尾标注交叉引用指向关联模块。

---

## 6.1 概述

VCP 的能力扩展完全通过插件实现。87 个插件目录，79 个活跃，通过统一的 `plugin-manifest.json` 契约注册。

核心文件：
- `Plugin.js` — 插件管理器（生命周期、加载、执行分发）
- `Plugin/*/plugin-manifest.json` — 每个插件的契约文件
- `docs/PLUGIN_ECOSYSTEM.md` — 完整插件生态文档

---

## 6.2 六种插件类型

（源码 `Plugin.js:123, 266, 494-495, 872, 885, 962, 1012`）

| 类型 | 数量 | 特征 | 典型用例 |
|:---|:---|:---|:---|
| `static` | ~10 | cron 定时执行，输出存入占位符 | VCPForumLister, DailyHot, EmojiListGenerator |
| `synchronous` | ~45 | 同步工具，阻塞等待结果返回 | VSearch, UrlFetch, FileOperator |
| `asynchronous` | ~3 | 异步任务，不阻塞 LLM 响应 | DailyNote, AgentDream |
| `messagePreprocessor` | ~5 | 在消息发送给 LLM 前修改消息 | RAGDiaryPlugin, ContextFoldingV2 |
| `service` | ~8 | 常驻服务，注册到 Express 路由 | VCPLog, VCPTavern, VCPForum |
| `hybridservice` | ~8 | 同时是工具 + 服务 | DailyNoteManager, AgentAssistant |

### static — 静态插件

（源码 `Plugin.js:123-268`）

通过 cron 定时刷新，输出通过 `capabilities.systemPromptPlaceholders` 注入到 Agent 的 system 提示词中。LLM 不能直接调用它们。

**Manifest 示例**（VCPForumLister）：
```json
{
  "pluginType": "static",
  "entryPoint": { "type": "nodejs", "command": "node VCPForumLister.js" },
  "capabilities": {
    "systemPromptPlaceholders": [
      { "placeholder": "{{VCPForumLister}}", "description": "论坛帖子列表" }
    ]
  },
  "refreshIntervalCron": "*/5 * * * *"
}
```

### synchronous — 同步工具

（源码 `Plugin.js:885, 962`）

执行一次性任务，阻塞等待结果。LLM 通过 `<<<[TOOL_REQUEST]>>>` 调用，默认 60 秒超时。协议为 `stdio`。

### asynchronous — 异步工具

（源码 `Plugin.js:1012-1028`）

不阻塞 LLM 响应。LLM 调用后立即获得任务 ID，可后续查询进度。需配置 `CALLBACK_BASE_URL`。

### messagePreprocessor — 消息预处理器

（源码 `Plugin.js:494`）

在消息发送给 LLM **之前**修改消息内容。最关键的预处理器是 `RAGDiaryPlugin`——它负责扫描 Agent 提示词中的 `[[...]]` 记忆引用并注入对应的记忆内容。

### service / hybridservice

（源码 `Plugin.js:494-495, 872`）

`service` 是纯常驻服务，注册 Express 路由。`hybridservice` 同时作为工具被调用（有 `direct` 协议支持）和注册服务路由。

---

## 6.3 Manifest 核心字段

（来源 `docs/PLUGIN_ECOSYSTEM.md:39-48`）

```json
{
  "manifestVersion": "1.0.0",
  "name": "VSearch",
  "version": "1.0.0",
  "displayName": "语义并发搜索器",
  "pluginType": "synchronous",
  "entryPoint": {
    "type": "nodejs",        // nodejs | python | rust
    "command": "node VSearch.js"
  },
  "communication": {
    "protocol": "stdio",     // stdio | direct | distributed
    "timeout": 300000        // 毫秒
  },
  "capabilities": {
    "systemPromptPlaceholders": [...],   // static 插件专用
    "invocationCommands": [...]          // synchronous/asynchronous 插件专用
  }
}
```

### 配置级联

（来源 `docs/CONFIGURATION.md:73-80`）

```
插件 config.env > 全局 config.env > manifest 默认值
```

---

## 6.4 插件按功能分类

（基于 `Plugin/` 目录下的实际插件列表）

### 记忆与日记（6 个）
| 插件 | 类型 | 功能 |
|:---|:---|:---|
| LightMemo | synchronous | 语义检索日记本/知识库 |
| DeepMemo | synchronous | 历史聊天记录回溯检索（Rust Tantivy） |
| TopicMemo | synchronous | 话题级聊天记录回忆 |
| DailyNote | asynchronous | 创建/更新日记 |
| DailyNoteManager | hybridservice | 日记批量整理、联想检索 |
| DailyNoteWrite | synchronous | 日记写入 |

### 联网检索（12 个）
| 插件 | 类型 | 功能 |
|:---|:---|:---|
| VSearch | synchronous | 语义穿透联网检索 |
| TavilySearch | synchronous | AI 专属搜索引擎 |
| UrlFetch | synchronous | 网页/文件内容爬取 |
| BilibiliFetch | synchronous | B 站视频/弹幕/评论获取 |
| FlashDeepSearch | synchronous | 多维度深度研究 |
| GoogleSearch | synchronous | Google 搜索 |
| SerpSearch | synchronous | DuckDuckGo + 反向搜图 |
| PubMedSearch | synchronous | 医学文献检索 |
| KEGGSearch | synchronous | 生物信息学通路检索 |
| NCBIDatasets | synchronous | NCBI 数据集检索 |
| ArxivDailyPapers | static | Arxiv 每日论文 |
| CrossRefDailyPapers | static | CrossRef 每日论文 |

### 文件与系统（8 个）
| 插件 | 类型 | 功能 |
|:---|:---|:---|
| FileOperator | synchronous | 完整文件 CRUD + Canvas |
| CodeSearcher | synchronous | VCP 项目源码搜索 |
| LocalSearchController | synchronous | 基于 Everything 的快速文件搜索 |
| PowerShellExecutor | synchronous | PowerShell 命令执行 |
| LinuxShellExecutor | synchronous | 远程 Linux Shell |
| LinuxLogMonitor | service | 日志异常监控 |
| FileServer | service | HTTP 文件服务 |
| TencentCOSBackup | service | 腾讯云 COS 备份 |

### 媒体生成（12 个）
| 插件 | 类型 | 功能 |
|:---|:---|:---|
| DoubaoGen | synchronous | 豆包文生图 |
| ZImageTurboGen | synchronous | 通义千问文生图 |
| NanoBananaGen2 | synchronous | AI 图像编辑 |
| GeminiImageGen | synchronous | Gemini 生图 |
| GPTImageGen | synchronous | GPT 生图 |
| ComfyUIGen | synchronous | ComfyUI 工作流 |
| FluxGen | synchronous | Flux 生图 |
| SunoGen | synchronous | Suno 音乐生成 |
| GrokVideo | synchronous | Grok 视频生成 |
| VideoGenerator | synchronous | 通用视频生成 |
| QwenImageGen | synchronous | 通义图片生成 |

### 通讯与协作（8 个）
| 插件 | 类型 | 功能 |
|:---|:---|:---|
| AgentAssistant | hybridservice | 多 Agent 通讯 |
| AgentMessage | synchronous | 主人通知推送 |
| VCPForum | synchronous | 论坛发帖/回复 |
| VCPForumLister | static | 论坛帖子列表（5 分钟刷新） |
| VCPForumOnline | static | 在线用户列表 |
| VCPTavern | service | 酒馆系统 |
| VCPTaskAssistant | service | 任务调度 |
| SynapsePusher | synchronous | WebSocket 消息推送 |

### 上下文与系统（8 个）
| 插件 | 类型 | 功能 |
|:---|:---|:---|
| RAGDiaryPlugin | messagePreprocessor | 记忆召回、元思考链（核心） |
| ContextFoldingV2 | messagePreprocessor | 对话楼层摘要折叠 |
| TagFolder | static | 上下文折叠白名单 |
| ToolBoxFoldMemo | messagePreprocessor | 工具箱内容折叠 |
| SkillBridge | synchronous | 技能包系统 |
| DynamicToolBridge | synchronous | 动态工具注册 |
| WorkspaceInjector | static | 工作区文件注入 |
| CapturePreprocessor | messagePreprocessor | 截图预处理 |

---

## 6.5 关键插件深度

### RAGDiaryPlugin

- **类型**：`messagePreprocessor`（消息预处理器）
- **文件**：`Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js`（~4652 行）
- **功能**：VCP 记忆系统的核心，负责扫描 Agent 提示词中的 `[[...]]` 记忆引用，执行语义检索并注入记忆内容。还负责 VCP 元思考链管理、AIMemo 处理、语义分组、上下文向量管理。
- **依赖**：KnowledgeBaseManager, MetaThinkingManager, SemanticGroupManager, AIMemoHandler, TimeExpressionParser

### AgentAssistant

- **类型**：`hybridservice`
- **功能**：多 Agent 之间的通讯桥梁。支持临时聊天（`temporary_contact: true`）、异步委托模式（`task_delegation: true`），可设置定时发送（`timely_contact`）。
- **配置**：`AdminPanel` → AgentAssistant → `config.json`（含 maxHistoryRounds, contextTtlHours 等）

### ContextFoldingV2

- **类型**：`messagePreprocessor`
- **功能**：将对话历史中的「楼中楼」（深层回复楼层）进行摘要折叠。用向量相似度检测哪些楼层可以压缩，异步调用 LLM 生成摘要，将长文本替换为摘要，减少 token 消耗。

### DeepWikiVCP

- **类型**：`synchronous`
- **功能**：通过 DeepWiki API 获取 GitHub 仓库的 AI 生成文档。支持 4 种调用模式：`wiki_structure`、`wiki_content`、`wiki_ask`、`wiki_ask`+`deep_research`。
- **多仓库联合**：最多 10 个仓库同时查询。

---

## 6.6 插件契约禁用机制

（来源 `AGENTS.md:93`）

在插件目录下将 `plugin-manifest.json` 重命名为 `plugin-manifest.json.block` → 插件被禁用。系统有 8 个禁用插件，启用前需确认依赖和配置完整。

---

## 交叉引用

- 插件输出如何通过占位符注入 → 见 `02-变量与占位符体系.md` §2.2 第四类
- 工具调用协议的 `<<<[TOOL_REQUEST]>>>` 语法 → 见 `05-工具调用协议.md`
- 插件中折叠协议的用法 → 见 `03-上下文折叠体系.md` §3.3
- Agent 提示词中如何引用插件工具箱 → 见 `07-Agent提示词工程.md`
