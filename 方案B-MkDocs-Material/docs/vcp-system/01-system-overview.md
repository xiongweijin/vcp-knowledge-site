# 01 — VCP 系统全景

> 本系列文档每篇自洽，可独立阅读。末尾标注交叉引用指向关联模块。

---

## 1.1 VCP 是什么

VCP (Variable & Command Protocol) 是一个 Node.js 核心的 **AI 中间层**。它的核心使命是：给 LLM 提供一套完整的「存在基础设施」——记忆、工具、多 Agent 协同、文件操作、分布式执行。

它要解决的传统 AI 系统三大断裂：
- **前端 ↔ 后端断裂**：不同客户端之间状态割裂
- **AI ↔ 工具断裂**：LLM 只能机械调用 JSON Schema，缺乏语义级工具理解
- **AI ↔ 记忆断裂**：关闭上下文窗口 = 失忆，没有长期记忆和直觉

### 技术栈

| 层级 | 技术 | 源码位置 |
|:---|:---|:---|
| 运行时 | Node.js (CommonJS) | `server.js:1` |
| Web 框架 | Express.js | `server.js:231` |
| 向量索引 | Rust N-API (USearch/Vexus) | `rust-vexus-lite/` |
| 数据库 | SQLite (better-sqlite3) | `KnowledgeBaseManager.js:83` |
| WebSocket | ws 库 | `WebSocketServer.js:46` |
| 文件监听 | chokidar | `KnowledgeBaseManager.js:901` |
| 进程管理 | pm2-runtime | `Dockerfile` |

### 项目规模

- 673 个文件，76,448 行代码
- 95+ 活跃插件，分布在 `Plugin/` 目录下
- 14 个核心模块，扁平化放在 `modules/` 和根目录
- 无传统 `src/` 分层——运行时目录刻意保持扁平

> 源码依据：`AGENTS.md:36-38`、`AGENTS.md:79-80`

---

## 1.2 架构总览：核心三角

VCP 的架构可以理解为一个**核心三角**，三个文件撑起整个系统的骨架：

```
┌──────────────────────────────────────────────┐
│              server.js                        │
│         HTTP/SSE 入口 + 启动编排              │
│   Express 路由、中间件、生命周期管理           │
└──────────────┬───────────────┬───────────────┘
               │               │
       ┌───────▼───────┐ ┌─────▼─────────────────┐
       │   Plugin.js    │ │ KnowledgeBaseManager  │
       │  插件生命周期   │ │    RAG / 向量库       │
       │  加载/执行/分发 │ │  TagMemo / EPA / 索引 │
       └───────┬───────┘ └─────────────────────────┘
               │
    ┌──────────┴──────────┐
    │    Plugin/ 目录     │
    │   95+ 本地插件      │
    └─────────────────────┘
```

- **server.js**：唯一入口。负责环境加载、中间件注册、路由挂载、启动顺序编排。源码中 `dotenv.config()` 是第一行（`server.js:4`），`app.listen()` 是最后一步（`server.js:1573`）。
- **Plugin.js**：插件运行时。负责 manifest 发现、插件加载、六种类型的执行分发、服务路由注册。向外暴露 `pluginManager` 单例，被 server.js 引用（`server.js:113`）。
- **KnowledgeBaseManager.js**：知识库/RAG 总控。管理 SQLite 数据库、Vexus 向量索引、TagMemo 算法、EPA 模块、残差金字塔。也是单例，被 server.js 引用（`server.js:112`）。

另外还有一个横向贯穿的组件：

- **WebSocketServer.js**：分布式通信骨架。管理节点注册、客户端分型认证、消息分发、跨节点工具调用。被 server.js 引用（`server.js:116`）。

> 源码依据：`server.js:1-117`（所有核心模块的 require）；`docs/ARCHITECTURE.md:27-55`

---

## 1.3 启动序列

`node server.js` 执行时的启动序列（精简版，来源 `server.js:1531-1580`）：

| 步骤 | 内容 | 源码行号 |
|:---|:---|:---|
| 1 | `dotenv.config()` — 加载 config.env | `server.js:4` |
| 2 | 初始化日志系统（logger） | `server.js:26-28` |
| 3 | 解析 Agent/TVStxt 目录路径 | `server.js:33-92` |
| 4 | 创建 Express app + 中间件链 | `server.js:231+` |
| 5 | 加载 IP 黑名单 | `server.js:1532` |
| 6 | 确保 Agent/TVStxt 目录存在 | `server.js:1534-1537` |
| 7 | 加载 ModelRedirect.json | `server.js:1540-1543` |
| 8 | 初始化 AgentManager → TVSManager → ToolboxManager → SarPromptManager | `server.js:1545-1563` |
| 9 | `initialize()` — 核心初始化（见下） | `server.js:1566` |
| 10 | 预热 node-fetch ESM 模块 | `server.js:1570` |
| 11 | `app.listen(port)` — 开始监听 | `server.js:1573` |

### 第 9 步 initialize() 的内部顺序

最关键的一步，来源 `server.js:1424-1488`：

```
knowledgeBaseManager.initialize()     → 向量数据库就绪
    ↓
pluginManager.loadPlugins()           → 加载所有插件
    ↓
pluginManager.initializeServices()    → 初始化服务类插件 + 挂载 /admin_api 路由
    ↓
依赖注入（knowledgeBase + vcpLog）    → 注入到消息预处理器和服务模块
    ↓
pluginManager.initializeStaticPlugins() → 执行静态插件（含 emoji 列表生成）
    ↓
预热 Python 插件
```

> 源码依据：`server.js:1424-1488`

---

## 1.4 聊天请求完整流程

当客户端发送 `POST /v1/chat/completions` 时（来源 `server.js:1139`）：

```
1. Bearer Token 认证
2. 模型重定向检查（ModelRedirect.json）
3. VCPTavern 预处理（酒馆系统注入）
4. 消息预处理器链（RAGDiaryPlugin 记忆召回等）
5. 变量占位符替换（messageProcessor）
   ├── Agent 占位符 {{AgentName}} → 加载 Agent 提示词
   ├── Toolbox 占位符 {{VCPXxxToolBox}} → 加载工具箱（含向量折叠）
   ├── 系统变量 {{VarUser}} {{TarSysPrompt}} 等
   ├── 时间变量 {{Date}} {{Time}}
   └── 静态插件占位符 {{VCPForumLister}} 等
6. VCP 工具调用循环（最多 MaxVCPLoop* 次）
   ├── LLM 输出包含 <<<[TOOL_REQUEST]>>> → 解析并执行
   └── 工具结果注入上下文 → 继续 LLM 推理
7. 流式 SSE 或非流式 JSON 响应
```

> 源码依据：`server.js:1139-1142`（路由入口）；`chatCompletionHandler.js:543-570`（消息处理流程）；`messageProcessor.js:36-148`（变量替换入口）

---

## 1.5 核心模块速查

| 模块文件 | 职责 |
|:---|:---|
| `server.js` | HTTP/SSE 入口、启动编排、路由注册 |
| `Plugin.js` | 插件生命周期、六种类型执行分发 |
| `WebSocketServer.js` | 分布式节点与跨节点工具桥接 |
| `KnowledgeBaseManager.js` | RAG/标签/向量索引总控 |
| `modules/messageProcessor.js` | 提示词占位符注入管线 |
| `modules/chatCompletionHandler.js` | 对话主流程编排 |
| `modules/agentManager.js` | Agent 别名映射与热更新 |
| `modules/toolboxManager.js` | Toolbox 文件管理与折叠对象构建 |
| `modules/foldProtocol.js` | `[===vcp_fold===]` 解析与动态折叠构建 |
| `modules/contextManager.js` | 上下文窗口管理 |
| `modules/dynamicToolRegistry.js` | 动态工具注册与注入 |
| `modules/roleDivider.js` | 角色分割（system/user/assistant 楼层切割） |
| `modules/tvsManager.js` | TVS 变量文件管理 |
| `modules/sarPromptManager.js` | SarPrompt 动态提示词管理 |

---

## 交叉引用

- 变量替换的完整流程 → 见 `02-变量与占位符体系.md`
- 上下文折叠机制 → 见 `03-上下文折叠体系.md`
- 记忆系统深度解析 → 见 `04-记忆系统.md`
- 工具调用协议 → 见 `05-工具调用协议.md`
- 插件类型详解 → 见 `06-插件生态.md`
- Agent 提示词工程 → 见 `07-Agent提示词工程.md`
