# VCP 系统深度导读（使用者视角）

生成时间：2026-05-16  
目标：帮助使用者更准确地理解 VCPToolBox 的运行方式、使用入口和学习路径。  
方法：先读 `docs/` 文档体系，再用当前源码校准；凡是文档口径与源码口径不同，以源码为准。

---

## 1. 一句话心智模型

VCPToolBox 不是一个普通聊天前端，也不是单纯的工具插件集合。它更像一个 **OpenAI-compatible AI 中间层**：

```text
客户端 / OpenWebUI / VChat / 其他调用方
        |
        v
VCPToolBox HTTP API
        |
        +-- 消息预处理：Agent、变量、Tavern、图片/多模态、RAG、上下文折叠
        |
        +-- 上游模型 API：转发到 API_URL
        |
        +-- VCP 工具循环：解析 AI 输出中的 TOOL_REQUEST，自行执行插件，再把结果回灌给模型
        |
        +-- 管理/日志/WebSocket：面板、VCP 调用观察、分布式节点、插件服务路由
```

它的核心价值在于：**把模型、提示词、记忆、工具、后台管理和分布式执行统一到一个运行时里**。

---

## 2. 当前源码口径概览

当前仓库结构和旧文档有一定漂移，建议先记住这些源码现状：

| 项目 | 当前源码现状 |
|---|---|
| 核心入口 | `server.js` |
| 对话主流程 | `modules/chatCompletionHandler.js` |
| 插件总控 | `Plugin.js` |
| VCP 工具解析/执行 | `modules/vcpLoop/toolCallParser.js`, `modules/vcpLoop/toolExecutor.js` |
| 流式/非流式循环 | `modules/handlers/streamHandler.js`, `modules/handlers/nonStreamHandler.js` |
| 变量/Agent/Toolbox 替换 | `modules/messageProcessor.js` |
| 记忆与向量库 | `KnowledgeBaseManager.js`, `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js` |
| 管理后端 | `routes/adminPanelRoutes.js`, `routes/admin/*.js` |
| 管理前端 | `AdminPanel-Vue/`，不是旧文档里常写的 `AdminPanel/` |
| 插件规模 | `Plugin/` 下 107 个目录，96 个启用 manifest，11 个 block manifest |
| 启用插件类型 | `synchronous=61`, `static=14`, `hybridservice=10`, `service=5`, `messagePreprocessor=4`, `asynchronous=2` |

> 注意：`docs/` 文档体系非常适合学习架构，但其中一些数量、目录名和插件类型口径已经过期。

---

## 3. 启动链路

VCP 启动时的顺序可以理解为：

1. `server.js` 读取 `config.env`。
2. 创建 Express app，挂载中间件、特殊模型路由、管理鉴权、聊天 API。
3. 初始化 Agent / TVS / Toolbox / SarPrompt 等配置管理器。
4. 初始化 `KnowledgeBaseManager`，准备 SQLite、向量索引、TagMemoEngine、RAG 热参数监听。
5. 初始化 `DynamicToolRegistry`，从插件 manifest 同步可用工具。
6. `PluginManager.loadPlugins()` 扫描 `Plugin/*/plugin-manifest.json`。
7. `PluginManager.initializeServices()` 挂载 service/hybridservice 插件路由。
8. 初始化任务调度器、HTTP server、WebSocket server、FileFetcher。

关键源码锚点：

- `server.js:1424`：`initialize()` 先初始化向量数据库，再加载插件和服务。
- `server.js:1531`：`startServer()` 执行启动门控。
- `server.js:1573`：`app.listen(port, ...)` 真正监听端口。
- `server.js:1601`：HTTP server 启动后初始化 WebSocket。

学习建议：如果要理解“为什么某个插件没加载”，先看 `Plugin.js`；如果要理解“为什么服务启动失败”，先看 `server.js` 启动顺序。

---

## 4. 聊天请求链路

主要入口：

- `/v1/chat/completions`：标准 OpenAI-compatible 入口。
- `/v1/chatvcp/completions`：强制展示 VCP 调用信息的入口。
- `/v1/models`：向上游转发模型列表。
- `/v1/human/tool`：人类直接用纯文本工具块调用 VCP 工具。

`/v1/chat/completions` 的主流程：

```text
server.js 路由
  -> ChatCompletionHandler.handle()
      -> VCPTavern 优先预处理
      -> Agent / Toolbox / Var / Tar / Sar 等变量替换
      -> ImageProcessor 或 MultiModalProcessor
      -> 其他 messagePreprocessor
      -> fetchWithRetry() 调用上游模型
      -> StreamHandler 或 NonStreamHandler
          -> 解析 AI 输出中的 VCP 工具块
          -> ToolExecutor 执行工具
          -> 把工具结果作为新 user 消息回灌给模型
          -> 循环直到无工具调用或达到 MaxVCPLoop
```

关键源码锚点：

- `server.js:1139`：标准聊天入口。
- `server.js:1153`：强制展示 VCP 信息的聊天入口。
- `modules/chatCompletionHandler.js:324`：单次请求主处理函数。
- `modules/chatCompletionHandler.js:531`：VCPTavern 优先运行。
- `modules/chatCompletionHandler.js:559`：消息顺序处理，保证 Agent/Toolbox “首次展开”语义。
- `modules/chatCompletionHandler.js:606`：多模态预处理器选择。
- `modules/chatCompletionHandler.js:620`：其他通用 messagePreprocessor 依次运行。
- `modules/chatCompletionHandler.js:675`：第一次请求上游模型。

---

## 5. 插件系统

VCP 插件由 `plugin-manifest.json` 驱动。当前源码里主要类型是：

| 类型 | 典型用途 |
|---|---|
| `static` | 生成静态占位符能力，如工具说明、天气、列表 |
| `messagePreprocessor` | 修改 messages，例如图片处理、上下文折叠 |
| `synchronous` | 标准 stdio 工具，执行后返回 JSON |
| `asynchronous` | 长任务插件，先返回任务 ID，再通过 callback 更新 |
| `service` | 注册 HTTP/WebSocket/后台服务 |
| `hybridservice` | 同时可作为预处理器/服务/工具，当前 RAGDiaryPlugin、VCPTavern 等使用此类型 |

重要现实：`hybridservice` 不是边缘能力，而是当前系统的关键形态。源码中：

- `Plugin.js:494`：`hybridservice` 会被视作 messagePreprocessor。
- `Plugin.js:495`：`hybridservice` 也会被视作 service。
- `Plugin.js:872`：direct 协议的 `hybridservice` 工具调用走本地模块的 `processToolCall()`。

插件执行分三条路：

```text
AI 输出 TOOL_REQUEST
  -> ToolCallParser.parse()
  -> ToolExecutor.execute()
  -> PluginManager.processToolCall()
      |
      +-- distributed: WebSocketServer.executeDistributedTool()
      +-- ChromeControl: WebSocket forwardCommandToChrome()
      +-- hybridservice/direct: serviceModule.processToolCall()
      +-- synchronous/asynchronous stdio: spawn entryPoint.command
```

关键源码锚点：

- `Plugin.js:430`：扫描插件 manifest。
- `Plugin.js:706`：`processToolCall()` 是工具调用总入口。
- `Plugin.js:854`：分布式工具调用。
- `Plugin.js:872`：本地 direct hybridservice 调用。
- `Plugin.js:955`：stdio 插件执行。
- `Plugin.js:1204`：service 插件注册路由。

---

## 6. VCP 工具调用协议

VCP 没有用 OpenAI function calling，而是让模型在文本中输出自定义工具块：

```text
<<<[TOOL_REQUEST]>>>
tool_name:「始」插件名「末」
参数名:「始」参数值「末」
<<<[END_TOOL_REQUEST]>>>
```

当前解析器支持：

- `tool_name`：目标插件名。
- 其他字段：都会作为参数进入 `args`。
- `archery`：异步/旁路工具调用标记，`true` 或 `no_reply` 会进入 archery 分支。
- `ink: mark_history`：即使全局隐藏 VCP 输出，也可强制把该工具调用写入历史展示。
- `river`：给工具注入上下文，支持 `full`、`text`、`last:N`、`semantic:N`。
- `vref`：根据当前上下文从知识库跨分区召回引用。
- escape：`「始ESCAPE」` / `「末ESCAPE」` 可表达字面量边界符。

关键源码锚点：

- `modules/vcpLoop/toolCallParser.js:4`：工具块起止标记。
- `modules/vcpLoop/toolCallParser.js:28`：解析前只移除 `<think>...</think>`，没有移除 `<thinking>...</thinking>`。
- `modules/vcpLoop/toolCallParser.js:53`：提取下一个工具块。
- `modules/vcpLoop/toolCallParser.js:76`：解析块字段。
- `modules/vcpLoop/toolCallParser.js:93`：识别 `tool_name`。
- `modules/vcpLoop/toolCallParser.js:94`：识别 `archery`。
- `modules/vcpLoop/toolCallParser.js:96`：识别 `ink`。
- `modules/vcpLoop/toolCallParser.js:98`：识别 `river`。
- `modules/vcpLoop/toolCallParser.js:100`：识别 `vref`。
- `modules/vcpLoop/toolExecutor.js:187`：执行单个工具调用。
- `modules/vcpLoop/toolExecutor.js:191`：`river` 上下文注入说明。
- `modules/vcpLoop/toolExecutor.js:332`：最终调用 `pluginManager.processToolCall()`。

使用建议：

- 普通工具调用优先使用 `tool_name + 必要参数`，不要让模型每次都塞巨大上下文。
- 需要上下文时优先试 `river:text` 或 `river:last:N`，`river:full` 成本更高。
- 需要语义压缩上下文时再考虑 `river:semantic:N`。
- 若启用 `VCPToolCode=true`，工具调用必须携带正确 `tool_password`。

---

## 7. Agent、变量和 Toolbox

VCP 的提示词系统不是一个单层 system prompt，而是多来源注入：

| 能力 | 位置/配置 | 用法 |
|---|---|---|
| Agent | `Agent/`, `agent_map.json` | `{{AgentAlias}}` 或 `{{agent:AgentAlias}}` |
| TVS 变量文件 | `TVStxt/` | `VarXXX=xxx.txt`，然后 `{{VarXXX}}` |
| Toolbox | `toolbox_map.json`, `TVStxt/` | `{{ToolboxAlias}}` 或 `{{toolbox:ToolboxAlias}}` |
| Tar/Var 环境变量 | `config.env` | system 消息中替换 |
| SarPrompt | `SarModelN` / `SarPromptN` | 按模型名注入高级预设 |
| 动态工具列表 | `{{VCPDynamicTools}}` | 根据当前消息筛选工具说明 |

安全边界很关键：

- Agent 和 Toolbox 只在特权上下文展开。
- 特权上下文包括 `system` 消息，以及 VCPTavern 注入的 `[系统提示:]` / `[系统邀请指令:]` user 消息。
- 普通 user/assistant 消息里的 Agent/Toolbox 占位符不会被当作可读 prompt 的入口。
- 每个上下文只允许展开一个 Agent；同一 Toolbox 只展开一次。

关键源码锚点：

- `modules/messageProcessor.js:37`：总变量解析函数。
- `modules/messageProcessor.js:41`：Agent/Toolbox 只在特权角色中展开。
- `modules/messageProcessor.js:59`：识别 Agent alias。
- `modules/messageProcessor.js:60`：整个上下文只允许展开一个 Agent。
- `modules/messageProcessor.js:100`：识别 Toolbox alias。
- `modules/messageProcessor.js:101`：Toolbox 去重。
- `modules/messageProcessor.js:372`：处理 Var/Tar/Sar/时间/插件占位符等其他变量。
- `modules/agentManager.js:7`：Agent 映射文件是 `agent_map.json`。
- `modules/agentManager.js:272`：按 alias 获取 Agent prompt。
- `modules/toolboxManager.js:7`：Toolbox 映射文件是 `toolbox_map.json`。
- `modules/toolboxManager.js:123`：按 alias 获取折叠对象。

---

## 8. 动态工具注入

早期 VCP 提示词常把完整工具列表塞进 system prompt；当前更推荐理解 `{{VCPDynamicTools}}`：

```text
system prompt 中放 {{VCPDynamicTools}}
        |
        v
modules/messageProcessor.js 调 dynamicToolRegistry.buildInjection()
        |
        v
DynamicToolRegistry 根据当前 messages、关键词、分类、显式指令选择工具说明
```

它的好处是：插件很多时，不必每次把 96 个工具说明全部塞给模型。

支持的显式指令包括：

- `[[VCPDynamicTools:category=分类名:all]]`
- `[[VCPDynamicTools:tool=工具名]]`

关键源码锚点：

- `modules/messageProcessor.js:491`：遇到 `{{VCPDynamicTools}}` 时构建动态注入。
- `modules/dynamicToolRegistry.js:15`：默认 placeholder 是 `{{VCPDynamicTools}}`。
- `modules/dynamicToolRegistry.js:242`：初始化工具注册表。
- `modules/dynamicToolRegistry.js:450`：构建注入文本。
- `modules/dynamicToolRegistry.js:637`：从 PluginManager 抽取插件记录。
- `modules/dynamicToolRegistry.js:975`：解析显式 category/tool 指令。
- `ToolConfigs/dynamic_tool_bridge.config.json:3`：动态工具桥当前启用。

---

## 9. 记忆、RAG 与 TagMemo

VCP 记忆系统由两层组成：

```text
KnowledgeBaseManager
  - 管 SQLite
  - 管 chunks/tags/files 表
  - 管 Rust VexusIndex
  - 管全局 Tag 索引与各 diary 独立索引
  - 管 TagMemoEngine

RAGDiaryPlugin
  - 作为 messagePreprocessor 处理 system 中的 RAG 占位符
  - 根据最近 user/assistant 内容构造 queryVector
  - 支持 Time / Group / Rerank / TagMemo / AIMemo / Base64Memo / Expand / Associate 等修饰符
  - 把召回内容注入回 system prompt
```

常见 RAG 语法形态：

| 语法 | 含义 |
|---|---|
| `[[某某日记本]]` | 标准语义召回 |
| `<<某某日记本>>` | 全文/直接检索类路径 |
| `《《某某日记本》》` | 混合阈值模式 |
| `{{某某日记本}}` | 直接引入模式 |
| `[[AIMemo=True]]` | AIMemo 全局许可证开关 |
| `::AIMemo` / `::AIMemo:预设名` | 语义推理检索模式，必须有许可证才生效 |
| `::TagMemo` | 启用 TagMemo 增强 |
| `::TagMemo+` | 启用 TagMemo 加测地线重排 |
| `::Rerank` / `::Rerank+` | 调外部 rerank 服务 |
| `::Time` | 时间感知召回 |
| `::TimeDecay...` | 时间衰减 |
| `::Group` | 语义组增强 |
| `::Base64Memo` | 从召回内容中提取附件并注入多模态 |
| `::Expand` | 命中 chunk 后展开父文档 |
| `::Associate` | 联想共现发现 |

当前源码里一个容易误解的点：

- `::AIMemo:0.6` 不是阈值语法。
- AIMemo 预设名的正则是 `::AIMemo(?::([\w-]+))?`，只接受字母、数字、下划线、连字符。
- 小数点不会被完整识别为预设名。

关键源码锚点：

- `KnowledgeBaseManager.js:86`：知识库初始化。
- `KnowledgeBaseManager.js:144`：初始化 TagMemoEngine。
- `KnowledgeBaseManager.js:409`：统一 search 接口。
- `KnowledgeBaseManager.js:473`：按 diary 独立索引搜索。
- `KnowledgeBaseManager.js:711`：公共 TagMemo 增强接口。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1100`：RAGDiaryPlugin 的 messagePreprocessor 入口。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1122`：识别 `[[AIMemo=True]]`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1234`：用户/AI 意图加权向量。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1270`：历史上下文分段。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1492`：AIMemo 修饰符解析。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2303`：单个 RAG 占位符处理核心。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2371`：TagMemo/TagMemo+ 解析。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2430`：调用 TagMemo 预感应标签。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2532`：Shotgun Query，多向量并行搜索。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3406`：Rerank 执行与降级逻辑。
- `TagMemoEngine.js:61`：TagMemo 核心增强。
- `TagMemoEngine.js:537`：测地线重排。

---

## 10. 上下文折叠

当前上下文折叠不是独立孤岛，而是依赖 RAGDiaryPlugin 暴露的 `ContextBridge`：

```text
RAGDiaryPlugin
  -> FoldingStore
  -> getContextBridge()
      -> ContextFoldingV2
          -> system 中出现 [[ContextFoldingV2]] 或 {{ContextFoldingV2}}
          -> 根据当前 query 向量判断哪些历史楼层可折叠
          -> 需要时异步生成摘要
```

关键源码锚点：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4073`：暴露 ContextBridge。
- `Plugin/ContextFoldingV2/plugin-manifest.json:14`：声明 `requiresContextBridge: true`。
- `Plugin/ContextFoldingV2/ContextFoldingV2.js:65`：接收 ContextBridge。
- `Plugin/ContextFoldingV2/ContextFoldingV2.js:143`：折叠预处理器入口。
- `Plugin/ContextFoldingV2/ContextFoldingV2.js:149`：扫描 system 中的激活占位符。
- `Plugin/ContextFoldingV2/ContextFoldingV2.js:239`：必要时向量化楼层。

使用建议：

- 短对话不必启用折叠。
- 长对话、角色扮演、多轮任务链可以启用。
- 折叠依赖 embedding 能力；如果 embedding 路由或维度配置错，折叠和 RAG 都会受影响。

---

## 11. 管理面板与后台 API

当前管理后端已经模块化：

```text
routes/adminPanelRoutes.js
  -> routes/admin/system.js
  -> routes/admin/config.js
  -> routes/admin/plugins.js
  -> routes/admin/rag.js
  -> routes/admin/agents.js
  -> routes/admin/toolbox.js
  -> routes/admin/dynamicTools.js
  -> routes/admin/pluginStore.js
  -> ...
```

管理前端在 `AdminPanel-Vue/`，其中已有 `dist/`，根目录脚本提供：

- `npm start`：启动 VCP server。
- `npm run build:admin`：进入 `AdminPanel-Vue` 安装并构建。

关键源码锚点：

- `routes/adminPanelRoutes.js:73`：挂载 system/logs/config/plugins 等模块。
- `routes/adminPanelRoutes.js:84`：挂载 rag 模块。
- `routes/adminPanelRoutes.js:88`：挂载 dynamicTools 模块。
- `routes/adminPanelRoutes.js:94`：挂载 pluginStore 模块。
- `server.js:1343`：构造管理 API routes。
- `server.js:1449`：挂载 `/admin_api`。

---

## 12. 配置优先级和高风险配置

最基础的配置来自 `config.env`。不要把真实 `config.env` 提交到仓库。

最先要理解的配置：

| 配置 | 作用 |
|---|---|
| `API_URL` / `API_Key` | 上游模型 API |
| `PORT` | VCP 服务端口 |
| `Key` | 聊天 API 访问密码 |
| `VCP_Key` | WebSocket / 面板 / 分布式鉴权 |
| `AdminUsername` / `AdminPassword` | 管理后台登录 |
| `MaxVCPLoopStream` / `MaxVCPLoopNonStream` | 工具循环最大深度 |
| `ShowVCP` | 是否默认展示 VCP 工具输出 |
| `VCPToolCode` | 是否要求工具调用验证码 |
| `WhitelistImageModel` / `WhitelistEmbeddingModel` | 特殊模型白名单穿透 |
| `VECTORDB_DIMENSION` | 向量维度，必须和 embedding 模型一致 |
| `KNOWLEDGEBASE_FULL_SCAN_ON_STARTUP` | 启动时是否全量扫描知识库 |
| `KNOWLEDGEBASE_PERSIST_FOLDERS` | 哪些 diary 索引持久化 |
| `RAGMemoRefresh` | 工具循环后是否刷新 RAG 区块 |
| `AGENT_DIR_PATH` | Agent 根目录 |
| `TVSTXT_DIR_PATH` | TVS 变量文件目录 |

高风险点：

- `VECTORDB_DIMENSION` 配错会导致 embedding、RAG、折叠整体异常。
- `VCPToolCode=false` 时，工具调用更依赖 API 鉴权和 prompt 约束。
- `ShowVCP=false` 只是隐藏展示，不代表工具没有执行。
- `Rerank` 需要 `RerankUrl` / `RerankApi` / `RerankModel`；未配置时源码会降级跳过。
- `config.env.example` 有很多示例变量，但真实 `config.env` 可能含密钥，排查时只看键名，不要外泄值。

---

## 13. 使用者学习路线

建议按这个顺序学，比从所有插件开始读更省力：

1. **先跑通基础聊天**
   - 看 `config.env.example` 的 `API_URL`、`API_Key`、`PORT`、`Key`。
   - 用 `/v1/chat/completions` 作为 OpenAI-compatible endpoint。

2. **理解工具调用**
   - 学 `<<<[TOOL_REQUEST]>>>` 块格式。
   - 找一个低风险工具测试，例如查询/计算类工具。
   - 打开 `ShowVCP` 或用 `/v1/chatvcp/completions` 观察工具循环。

3. **理解 Agent/变量**
   - 看 `agent_map.json` 和 `Agent/`。
   - 看 `TVStxt/` 和 `VarXXX=xxx.txt`。
   - 不要把所有东西都塞 system；优先用 Agent/Toolbox 分层。

4. **理解动态工具注入**
   - 在 system prompt 中放 `{{VCPDynamicTools}}`。
   - 观察模型是否只看到相关工具。
   - 必要时用 `[[VCPDynamicTools:tool=工具名]]` 强制展开单个工具。

5. **理解 RAG**
   - 从 `[[某某日记本]]` 开始。
   - 再试 `::TagMemo` / `::TagMemo+`。
   - 最后再试 `::Time`、`::Rerank`、`::AIMemo`、`::Base64Memo`、`::Associate` 等复杂修饰符。

6. **理解上下文折叠**
   - 长上下文才启用。
   - 先确认 embedding 可用，再看 `ContextFoldingV2`。

7. **最后再读插件开发**
   - 先读 manifest schema。
   - 再选一种类型：`synchronous` 最容易入门，`hybridservice` 最强但复杂度更高。

---

## 14. 排错路线图

| 现象 | 优先检查 |
|---|---|
| 服务起不来 | `server.js` 启动日志、`config.env` 必填项、端口占用 |
| 模型请求失败 | `API_URL` / `API_Key`、上游 `/v1/models` 是否通 |
| 插件没出现 | `Plugin/*/plugin-manifest.json` 是否存在且 JSON 合法 |
| 工具块没有执行 | AI 输出格式、`tool_name` 是否匹配 manifest name、是否藏在 `<thinking>` 中 |
| 工具执行失败 | `PluginManager.processToolCall()` 分支、插件 entryPoint、插件私有 config |
| RAG 没结果 | embedding 配置、`VECTORDB_DIMENSION`、知识库扫描、diary 名称 |
| TagMemo 异常 | tags 表、tag index、`rag_params.json`、TagMemoEngine 初始化日志 |
| ContextFoldingV2 不工作 | system 中是否有激活占位符、RAGDiaryPlugin 是否提供 ContextBridge |
| 管理面板异常 | `AdminPanel-Vue/dist`、`AdminUsername/AdminPassword`、`/admin_api` 路由 |
| 分布式工具异常 | WebSocket 是否连上、`VCP_Key`、serverId、distributed manifest |

---

## 15. 当前已知文档漂移

这些点后续审核或使用时要特别留心：

1. 插件数量口径已变：当前是 107 个插件目录、96 个启用 manifest、11 个 block manifest。
2. 管理前端当前是 `AdminPanel-Vue/`，不是旧口径的 `AdminPanel/`。
3. `VCPTavern` 当前 manifest 是 `hybridservice`，不是单纯 `messagePreprocessor` 或 `service`。
4. 分布式工具实际调用在 `Plugin.js:854-860`。
5. 工具解析器只移除 `<think>`，没有移除 `<thinking>`；如果提示词样本要求 `<thinking>` 内工具不可执行，需要修源码或改提示词。
6. `::AIMemo:0.6` 不应解释为阈值；当前源码会按预设名正则解析，且小数点不匹配。
7. `::TagMemo+` 当前是 TagMemo 加测地线重排，不等于“不使用 Rerank”；外部 `::Rerank` 仍是另一条可选路径。

---

## 16. 推荐继续深入的源码阅读顺序

```text
server.js
  -> modules/chatCompletionHandler.js
  -> modules/messageProcessor.js
  -> Plugin.js
  -> modules/vcpLoop/toolCallParser.js
  -> modules/vcpLoop/toolExecutor.js
  -> modules/handlers/streamHandler.js
  -> modules/handlers/nonStreamHandler.js
  -> KnowledgeBaseManager.js
  -> Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js
  -> TagMemoEngine.js
  -> Plugin/ContextFoldingV2/ContextFoldingV2.js
  -> routes/adminPanelRoutes.js + routes/admin/*.js
```

如果目标是“会用”，读到 `messageProcessor + DynamicToolRegistry + RAGDiaryPlugin` 就已经能解决大多数使用问题。  
如果目标是“会改”，必须补上 `Plugin.js + vcpLoop + handlers`。  
如果目标是“会扩展记忆系统”，再深入 `KnowledgeBaseManager + TagMemoEngine + RAGDiaryPlugin`。

---

## 17. 本轮深度研究补充：VCP 的语义调度层

本轮继续阅读源码和外部说明后，可以把 VCP 的高级能力重新概括为一句话：

> VCP 不是简单的“模型 + 插件”，而是在模型外部搭了一层语义调度系统。它会根据当前上下文，动态决定展开哪些提示词、召回哪些记忆、暴露哪些工具、传递哪些附件，以及是否唤醒其他 Agent。

这也是“上下文引力场”这个说法比较贴切的原因：当前对话不是静态文本，而是会形成一个语义重心，牵引工具、记忆、附件和思考路径进入模型上下文。

### 17.1 三个核心概念的源码对应

| 概念 | 源码对应 | 准确理解 |
|---|---|---|
| 词元捕网 | `Plugin/RAGDiaryPlugin/SemanticGroupManager.js:274`, `Plugin/SemanticGroupEditor/SemanticGroupEditor.js:40`, `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2422` | 用词元/短语命中语义组，再把查询向量往相关语义方向偏转 |
| 思维簇 | `Plugin/ThoughtClusterManager/ThoughtClusterManager.js:42`, `KnowledgeBaseManager.js:310`, `Plugin/RAGDiaryPlugin/MetaThinkingManager.js:106` | 把“怎么思考”做成可检索的知识簇，并按链式流程多阶段检索 |
| 上下文引力场 | `modules/vcpLoop/toolExecutor.js:187`, `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1319`, `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4069` | 当前上下文向量影响工具执行、文件引用、附件注入和插件间共享能力 |

#### 词元捕网

词元捕网不是一个单独文件名，而是由“语义组”实现的概念层能力。

基本链路：

```text
用户输入
  -> detectAndActivateGroups(text)
  -> 命中 semantic_groups 中的词元
  -> getEnhancedVector()
  -> 原查询向量 + 语义组向量混合
  -> RAG / 元思考检索方向被偏转
```

当前源码里能明确确认的是：词元匹配主要是包含匹配，见 `SemanticGroupManager.js:299` 附近的 `includes` 逻辑。因此它不是复杂分词器，而是“词元命中 + 向量增强”的混合方案。

使用者视角可以这样理解：当你在 prompt 或记忆里持续维护语义组，VCP 会更容易把某类概念和某类记忆联系起来。

#### 思维簇

思维簇表面上是 `dailynote/` 下以“簇”结尾的文件夹，但在系统里它是被持久化索引的“思考模块库”。

典型链路：

```text
[[VCP元思考...]]
  -> RAGDiaryPlugin 解析元思考占位符
  -> MetaThinkingManager 读取 meta_thinking_chains.json
  -> 依次检索 前思维簇 / 逻辑推理簇 / 反思簇 / 结果辩证簇 ...
  -> 每一阶段的结果向量会影响下一阶段检索
```

普通 RAG 是“问题 -> 知识”。思维簇更像“问题 -> 思考方式 -> 下一步思考方式 -> 结论整理方式”。  
所以它的价值不只是补资料，而是让模型按预设的认知流程走。

#### 附件的上下文引力场

附件进入上下文主要有三条通道：

| 通道 | 源码 | 作用 |
|---|---|---|
| `river` | `modules/vcpLoop/toolExecutor.js:190` | 工具调用时携带上下文，支持 `full/text/last:N/semantic:N` |
| `vref` | `modules/vcpLoop/toolExecutor.js:55`, `modules/vcpLoop/toolExecutor.js:118` | 根据当前上下文召回语义相关文件 URL，注入 `args.vref_files` |
| `Base64Memo` | `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2686`, `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3979` | 从 RAG 召回结果中提取附件链接，必要时转成 base64 多模态内容 |

准确说，VCP 不是把所有附件永久塞进上下文，而是让附件以“链接/文件引用/可重新 base64 化资源”的形式待命。只有当当前语义足够相关时，它才会被重新吸进模型输入。

---

## 18. VCP 高阶功能地图

本轮梳理后，VCP 的高阶能力可以分成三类：主线已启用能力、可选高级能力、实验/默认禁用能力。

### 18.1 主线已启用能力

#### TagMemo 浪潮记忆算法

源码入口：

- `KnowledgeBaseManager.js:144`：初始化 `TagMemoEngine`
- `TagMemoEngine.js:59`：TagMemo 主算法入口
- `ResidualPyramid.js:22`：残差金字塔
- `ResultDeduplicator.js:3`：SVD / 残差去重器
- `TagMemoEngine.js:537`：测地线重排

它解决的是普通向量检索的两个问题：

1. 只找表面相似，容易漏掉深层相关内容。
2. 结果之间高度重复，浪费上下文。

TagMemo 的特点是先从查询向量中感应标签，再用残差金字塔拆出未被解释的语义能量，最后通过标签传播和测地线重排召回更有联想价值的记忆。

#### ContextBridge 上下文向量桥

源码入口：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4069`
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4087`
- `Plugin.js:581`
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:93`

它把 RAGDiaryPlugin 内部维护的上下文向量能力开放给其他插件。只要插件 manifest 声明 `requiresContextBridge: true`，初始化时就能拿到：

- 聚合上下文向量
- user / assistant 历史向量
- 上下文语义分段
- 逻辑深度 `L`
- 语义宽度 `S`
- 向量化、余弦相似度、加权平均等工具

这相当于给插件提供了一套“只读语义雷达”。

#### DynamicTools 动态工具清单

源码入口：

- `modules/messageProcessor.js:490`
- `modules/dynamicToolRegistry.js:15`
- `modules/dynamicToolRegistry.js:450`
- `modules/dynamicToolRegistry.js:706`

它让 `{{VCPDynamicTools}}` 不再是固定大段工具说明，而是根据当前上下文动态选择工具。

选择依据包括：

- 显式指令，例如 `[[VCPDynamicTools:tool=工具名]]`
- 分类指令，例如 `[[VCPDynamicTools:category=search:all]]`
- 工具描述与当前消息的关键词匹配
- 小模型分类
- embedding fallback 分类

它的意义是：插件数量很多时，模型不必每次看到所有工具，而是只看到当前任务可能需要的工具。

#### ToolBox 动态折叠协议

源码入口：

- `modules/foldProtocol.js:1`
- `modules/toolboxManager.js:147`
- `modules/messageProcessor.js:151`

它使用如下标记组织长提示词：

```text
[===vcp_fold:0.5::desc:某段能力说明===]
```

系统会根据当前上下文向量与 `desc` 的相似度决定是否展开该段内容。  
这让长工具说明、技能说明、复杂系统提示词可以“按需显影”。

#### River / vref 工具上下文协议

源码入口：

- `modules/vcpLoop/toolCallParser.js:74`
- `modules/vcpLoop/toolExecutor.js:187`
- `modules/vcpLoop/toolExecutor.js:190`
- `modules/vcpLoop/toolExecutor.js:302`

它是 VCP 工具调用协议里的增强层：

```text
river:full        给工具完整多模态上下文
river:text        给工具纯文本上下文
river:last:N      给工具最近 N 条文本消息
river:semantic:N  给工具语义最相关 N 条消息
vref:N            给工具语义相关文件引用
```

普通工具框架通常只传参数。VCP 可以把“当前语义环境”也传给工具。

#### 分布式工具执行

源码入口：

- `WebSocketServer.js:560`
- `WebSocketServer.js:623`
- `Plugin.js:1265`
- `Plugin.js:854`
- `FileFetcherServer.js:118`

分布式节点可以通过 WebSocket 注册远程工具，主 VCP 收到工具调用后再转发给对应节点执行。  
配合 `FileFetcherServer`，远程节点生成或持有的文件也可以被主服务器透明取回。

这使 VCP 可以从单机工具箱扩展成多机器工具网络。

#### Rust N-API 向量引擎

源码入口：

- `rust-vexus-lite/src/lib.rs:65`
- `rust-vexus-lite/src/lib.rs:229`
- `rust-vexus-lite/src/lib.rs:309`
- `rust-vexus-lite/src/lib.rs:357`
- `KnowledgeBaseManager.js:16`

它提供：

- usearch 向量索引
- 批量添加
- 向量搜索
- SQLite 恢复索引
- SVD
- 正交投影
- handshake 分析

这说明 VCP 的语义系统不是纯 prompt 结构，而是有原生向量计算和数学操作支撑。

### 18.2 可选高级能力

#### AgentAssistant 多 Agent 通讯与异步委托

源码入口：

- `Plugin/AgentAssistant/AgentAssistant.js:412`
- `Plugin/AgentAssistant/AgentAssistant.js:521`
- `Plugin/AgentAssistant/AgentAssistant.js:687`

能力包括：

- 唤醒指定 Agent
- 临时通讯
- 临时注入工具
- 异步委托长任务
- 查询委托进度
- 完成后通过 callback 回灌主对话

这是 VCP 里“多 Agent 社会”的基础设施。

#### VCPTaskAssistant 任务派发中心

源码入口：

- `Plugin/VCPTaskAssistant/vcp-task-assistant.js:305`
- `Plugin/VCPTaskAssistant/vcp-task-assistant.js:536`
- `Plugin/VCPTaskAssistant/vcp-task-assistant.js:552`

它可以把周期任务、一次性任务或自定义 prompt 派发给一个或多个 Agent。  
和 AgentAssistant 结合后，VCP 不只是被动响应，也可以主动调度 Agent 工作。

#### VCPMobileSync 移动端同步桥

源码入口：

- `Plugin/VCPMobileSync/README.md:13`
- `Plugin/VCPMobileSync/core/db.js:27`
- `Plugin/VCPMobileSync/transport/websocket.js:20`
- `Plugin/VCPMobileSync/sync/manifest.js:18`

它用 WebSocket + HTTP 做桌面端与手机端同步，核心是三阶段增量流水线：

```text
Metadata -> Topic -> Message
```

并用 SQLite hash 索引做差异比较。这个模块说明 VCP 生态不只面向服务端，也在往多端同步发展。

### 18.3 实验或默认禁用能力

#### AgentDream 梦系统

当前状态：`Plugin/AgentDream/plugin-manifest.json.block`，默认禁用。

源码入口：

- `Plugin/AgentDream/plugin-manifest.json.block:3`
- `Plugin/AgentDream/README.md:3`
- `Plugin/AgentDream/DreamWaveEngine.js:510`
- `Plugin/AgentDream/AgentDream.js:217`

它的思路是：让 Agent 在“梦境”中回顾记忆，通过 TagMemo / DreamWave 做联想，生成梦叙事，并把合并日记、删除冗余、梦感悟等操作记录为待管理员审批的 JSON。

这个模块很实验，但很能体现 VCP 的方向：让记忆系统不只是被检索，也能被 Agent 主动整理。

---

## 19. 四层架构重新理解

经过本轮补充，可以把 VCP 重新理解为四层：

```text
1. 接入层
   OpenAI-compatible API、管理面板、WebSocket、前端/移动端接入

2. 语义调度层
   ContextBridge、DynamicTools、ToolBox 动态折叠、ContextFoldingV2、River/vref

3. 记忆认知层
   RAGDiaryPlugin、KnowledgeBaseManager、TagMemo、词元捕网、思维簇、元思考链

4. 执行生态层
   本地插件、远程分布式插件、AgentAssistant、VCPTaskAssistant、ChromeBridge、MobileSync
```

其中最值得重点理解的是第 2 层和第 3 层。  
普通插件系统通常只有“模型调用工具”，而 VCP 多了一步：

```text
先理解当前上下文
  -> 再决定暴露哪些工具
  -> 再决定召回哪些记忆
  -> 再决定展开哪些提示词
  -> 再决定传递哪些附件/文件/上下文
  -> 最后才执行工具或请求模型
```

所以 VCP 的高阶能力不是“插件多”，而是“上下文参与了调度决策”。

---

## 20. 下一步重点研究：TagMemo + ContextBridge + DynamicTools

下一阶段建议集中研究这三件套，因为它们共同决定 VCP 的智能调度上限。

### 20.1 TagMemo 要回答的问题

研究目标：

1. `::TagMemo` 和 `::TagMemo+` 在 RAG 检索中的完整调用链。
2. `TagMemoEngine.applyTagBoost()` 如何改变查询向量。
3. 残差金字塔如何识别“主语义之外的微弱信号”。
4. 测地线重排和外部 `::Rerank` 的关系。
5. `rag_params.json` 中哪些参数真正影响 TagMemo 行为。

建议阅读顺序：

```text
Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2371
  -> KnowledgeBaseManager.js:711
  -> TagMemoEngine.js:59
  -> ResidualPyramid.js:22
  -> ResultDeduplicator.js:3
```

### 20.2 ContextBridge 要回答的问题

研究目标：

1. RAGDiaryPlugin 什么时候更新上下文向量。
2. ContextBridge 暴露了哪些只读接口。
3. `computeLogicDepth()` 和 `computeSemanticWidth()` 的实际语义。
4. ContextFoldingV2 如何使用 ContextBridge。
5. 其他插件如何声明 `requiresContextBridge` 并接入。

建议阅读顺序：

```text
Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1104
  -> Plugin/RAGDiaryPlugin/ContextVectorManager.js:93
  -> Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4069
  -> Plugin.js:581
  -> Plugin/ContextFoldingV2/ContextFoldingV2.js:144
```

### 20.3 DynamicTools 要回答的问题

研究目标：

1. `{{VCPDynamicTools}}` 是在哪个阶段被替换。
2. DynamicToolRegistry 如何从 PluginManager 同步工具。
3. 工具分类是如何产生的：手动规则、小模型、embedding fallback。
4. 显式指令 `[[VCPDynamicTools:tool=...]]` 和分类指令如何解析。
5. 当工具数量继续增长时，动态工具清单如何控制 token 成本。

建议阅读顺序：

```text
modules/messageProcessor.js:490
  -> modules/dynamicToolRegistry.js:212
  -> modules/dynamicToolRegistry.js:450
  -> modules/dynamicToolRegistry.js:706
  -> modules/dynamicToolRegistry.js:975
  -> Plugin.js:1265
```

### 20.4 三件套之间的关系

```text
TagMemo
  负责：从记忆系统中召回更有联想价值的内容

ContextBridge
  负责：把当前上下文的语义重心开放给插件

DynamicTools
  负责：根据当前上下文和工具分类，动态决定模型能看到哪些工具
```

合在一起就是：

```text
当前上下文
  -> ContextBridge 形成语义重心
  -> DynamicTools 选择相关工具
  -> TagMemo 召回相关记忆
  -> ToolBox / ContextFolding 控制提示词展开
  -> River / vref / Base64Memo 把必要上下文和附件传给工具或模型
```

这就是 VCP 当前最值得继续深挖的核心智能调度闭环。

---

## 21. 三件套源码确认与生活化理解

本节是在继续阅读源码后，对 `TagMemo + ContextBridge + DynamicTools` 的进一步确认。  
需要先校正一个容易误解的点：这三者不是一条简单的硬编码流水线，而是三套协同机制。

```text
TagMemo
  负责让记忆召回更聪明

ContextBridge
  负责把当前上下文语义状态开放给插件

DynamicTools
  负责让工具说明按任务动态展开
```

它们共享“上下文”和“向量能力”，但各自解决的问题不同。

### 21.1 TagMemo：记忆召回的联想图书管理员

#### 源码确认

核心调用链：

```text
RAGDiaryPlugin 解析 ::TagMemo / ::TagMemo+
  -> 计算动态 tagWeight / K / tagTruncationRatio
  -> 预调用 applyTagBoost 感应核心标签
  -> KnowledgeBaseManager.search(...)
  -> TagMemoEngine.applyTagBoost(...)
  -> VexusIndex.search(...)
  -> 可选 geodesicRerank(...)
```

关键源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2371`：解析 `::TagMemo` / `::TagMemo+`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2435`：预调用 `applyTagBoost()` 感应语义标签。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2497`：搜索时传入 `tagWeight`、核心标签和测地线选项。
- `KnowledgeBaseManager.js:488`：搜索前真正调用 `TagMemoEngine.applyTagBoost()` 改写查询向量。
- `TagMemoEngine.js:61`：TagMemo 主算法入口。
- `ResidualPyramid.js:25`：残差金字塔入口。
- `TagMemoEngine.js:537`：`::TagMemo+` 的测地线重排。

#### 准确理解

`::TagMemo` 不是关键词搜索。它会先对查询向量做 EPA 分析和残差金字塔分析，从语义空间里“感应”出相关标签，再把这些标签合成一个上下文向量，最后与原始查询向量融合。

核心流程可以理解为：

```text
原始查询向量
  -> EPA 分析：判断当前问题在哪个语义世界
  -> 残差金字塔：找出主语义之外还没被解释的微弱信号
  -> 标签收集：从 tagIndex 找相关标签
  -> 标签脉冲传播：沿标签共现矩阵扩散
  -> 语义去重：删除高度相似标签
  -> 标签上下文向量
  -> 原始查询向量与标签上下文向量融合
```

`::TagMemo+` 比 `::TagMemo` 多一步：测地线重排。它会复用前面标签脉冲传播形成的能量场，对 KNN 候选结果做二次排序。也就是说，普通 KNN 看“这个 chunk 和问题像不像”，测地线重排还看“这个 chunk 所在文件的标签，是否落在当前标签能量场里”。

`rag_params.json` 中已确认的关键参数包括：

| 参数 | 作用 |
|---|---|
| `RAGDiaryPlugin.tagWeightRange` | 动态 Tag 权重范围，默认 `[0.05, 0.45]` |
| `RAGDiaryPlugin.tagTruncationBase` / `tagTruncationRange` | 核心标签截断比例 |
| `KnowledgeBaseManager.activationMultiplier` | 根据残差特征调整 TagMemo 激活强度 |
| `KnowledgeBaseManager.dynamicBoostRange` | 限制最终 boost 强度 |
| `KnowledgeBaseManager.coreBoostRange` | 核心标签额外加权范围 |
| `KnowledgeBaseManager.spikeRouting` | 标签脉冲传播参数 |
| `KnowledgeBaseManager.geodesicRerank` | `::TagMemo+` 的测地线重排参数 |

#### 生活化类比

你去图书馆问：“我想做一个关于雨夜猫咪的故事。”

普通向量搜索像新手馆员，只找标题里有“雨夜”“猫咪”“故事”的书。  
TagMemo 像老馆员，他会继续联想：

- “雨夜”可能关联孤独、街灯、潮湿、城市。
- “猫咪”可能关联陪伴、流浪、敏感、观察者。
- “故事”可能需要人物动机、场景氛围、冲突。
- 你没明说“孤独”，但这个语义味道可能在问题里。

残差金字塔像老馆员继续追问：“这句话里还有哪些没有被主关键词解释掉的余味？”  
测地线重排像他不只看书名相似，还看这些书在读者借阅路径上是不是经常一起出现。

所以 TagMemo 的使用者心智模型是：

> 当你希望 RAG 不只是“搜相似文本”，而是“顺着语义关系联想相关记忆”，就使用 `::TagMemo`；当你还希望结果排序进一步参考标签网络，就使用 `::TagMemo+`。

### 21.2 ContextBridge：上下文状态的会议秘书

#### 源码确认

核心调用链：

```text
RAGDiaryPlugin.processMessages(...)
  -> contextVectorManager.updateContext(messages)
  -> RAGDiaryPlugin.getContextBridge()
  -> PluginManager 给 requiresContextBridge 插件注入 dependencies.contextBridge
  -> ContextFoldingV2 等插件读取上下文向量能力
```

关键源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1104`：更新上下文向量映射。
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:93`：`updateContext(messages)`。
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:244`：衰减聚合历史上下文向量。
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:285`：计算逻辑深度 `L`。
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:322`：计算语义宽度 `S`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4087`：暴露 `getContextBridge()`。
- `Plugin.js:581`：给声明 `requiresContextBridge` 的插件注入 Bridge。
- `Plugin/ContextFoldingV2/ContextFoldingV2.js:144`：ContextFoldingV2 使用 Bridge。

#### 准确理解

ContextBridge 是 RAGDiaryPlugin 暴露出来的只读语义接口。它不是直接替模型回答问题，而是给其他插件提供“当前上下文状态”。

它暴露的能力包括：

| 接口 | 作用 |
|---|---|
| `getAggregatedVector(role)` | 获取 user 或 assistant 历史消息的衰减聚合向量 |
| `getHistoryAssistantVectors()` | 获取历史 assistant 向量 |
| `getHistoryUserVectors()` | 获取历史 user 向量 |
| `getContextSegments(messages, threshold)` | 按语义相似度切分上下文段落 |
| `computeLogicDepth(vector)` | 判断语义能量是否集中，越高越聚焦 |
| `computeSemanticWidth(vector)` | 判断语义是否宽泛，越高越发散 |
| `embedText()` / `embedBatch()` | 带缓存的向量化 |
| `getEmbeddingFromCache()` | 只读缓存，不触发 API |
| `sanitize()` | 统一清洗文本，去掉 HTML、Emoji、工具噪声 |
| `cosineSimilarity()` / `weightedAverage()` / `averageVector()` | 向量数学工具 |
| `foldingStore` | 给 ContextFoldingV2 使用的折叠缓存接口 |

上下文更新时，系统会跳过 system 消息、最后一个 user 消息和最后一个 assistant 消息，主要维护“历史上下文”的向量缓存。这样做的含义是：最后一轮通常正在处理，历史向量则作为背景场存在。

#### 生活化类比

一场会议开了两个小时。ContextBridge 就像坐在旁边的会议秘书，他不替你发言，但一直维护一张白板：

- 刚才大家主要在聊什么？
- 哪些旧话题已经偏离当前主题？
- 当前讨论很聚焦，还是很发散？
- 哪些旧发言和现在仍然相关？

`L` 可以理解成“会议焦点有多集中”。  
`S` 可以理解成“会议话题铺得有多宽”。

ContextFoldingV2 就会问这个秘书：  
“这段旧发言和当前议题还相关吗？如果不相关，能不能折成摘要？”

所以 ContextBridge 的使用者心智模型是：

> 它是插件共享上下文语义状态的仪表盘。插件不用自己重新理解整场对话，可以通过 Bridge 获取当前语义重心和向量工具。

### 21.3 DynamicTools：工具说明的智能货架管理员

#### 源码确认

核心调用链：

```text
server.js 初始化 dynamicToolRegistry
  -> PluginManager 加载插件
  -> DynamicToolRegistry 从 manifest 提取 invocationCommands
  -> messageProcessor 遇到 {{VCPDynamicTools}}
  -> buildInjection(messages)
  -> 解析显式指令 / 工具分类 / 关键词匹配
  -> 输出轻量工具列表 + 相关工具完整说明
```

关键源码：

- `server.js:1431`：初始化 `dynamicToolRegistry`。
- `modules/messageProcessor.js:490`：遇到 `{{VCPDynamicTools}}` 时构建动态工具注入。
- `modules/dynamicToolRegistry.js:450`：`buildInjection()`。
- `modules/dynamicToolRegistry.js:645`：从插件 manifest 提取工具记录。
- `modules/dynamicToolRegistry.js:706`：工具分类入口。
- `modules/dynamicToolRegistry.js:724`：小模型分类。
- `modules/dynamicToolRegistry.js:803`：embedding fallback 分类。
- `modules/dynamicToolRegistry.js:975`：解析显式指令。
- `modules/dynamicToolRegistry.js:1006`：工具打分。
- `Plugin.js:620`：本地插件重载后触发 `tools_changed`。
- `Plugin.js:1288`：分布式工具注册后触发 `tools_changed`。

#### 准确理解

DynamicTools 解决的是“工具太多，不能全部塞进模型上下文”的问题。

它会生成两层工具说明：

1. **Brief tool list**：轻量工具列表，给模型知道大概有哪些工具。
2. **Expanded tool usage**：只展开被命中、被请求、或得分较高的工具完整说明。

工具为什么会被展开：

| 触发方式 | 说明 |
|---|---|
| 显式工具指令 | `[[VCPDynamicTools:tool=工具名]]` |
| 显式分类指令 | `[[VCPDynamicTools:category=search:all]]` |
| 强动词 + 工具名/分类 | 如“展开搜索类工具” |
| 分类命中 | 工具分类和当前 query 匹配 |
| 关键词命中 | 工具关键词和当前 query 匹配 |
| 工具描述命中 | 工具名、displayName、description、brief 命中当前 query |

工具分类来源按优先级大致是：

```text
自定义 classifier
  -> 小模型分类
  -> RAG embedding fallback 分类
  -> 关键词 fallback 分类
```

它还有 token 控制：

- `maxBriefListItems` 控制轻量列表数量。
- `maxExpandedPlugins` 控制自动展开工具数量。
- `maxForcedCategoryPlugins` 控制强制展开分类时的数量。
- `maxInjectionChars` 控制最终注入长度。

#### 生活化类比

你进一个五金店说：“我要修浴室水龙头。”

普通插件系统像店员把整本商品目录塞给你：螺丝刀、电锯、油漆、灯泡、园艺剪、焊枪全都给你看。

DynamicTools 像聪明店员：

- 先给你一张简短货架图：店里有哪些大类。
- 然后重点展开“水管扳手、生料带、密封圈、除锈剂”。
- 如果你明确说“把电钻也拿来”，它会强制展开电钻说明。
- 如果你说“列出所有搜索类工具”，它会展开 search 分类。

所以 DynamicTools 的使用者心智模型是：

> 当插件很多时，不要让模型背完整工具手册，而是让 `{{VCPDynamicTools}}` 根据当前任务摆出最可能用到的工具货架。

### 21.4 三件套如何协同

三者可以用“筹备一顿晚饭”来统一理解：

```text
ContextBridge
  是桌上的菜单讨论记录：
  今天几个人、偏辣还是清淡、预算多少、刚刚决定了什么。

DynamicTools
  是厨房管家：
  根据菜单只把锅、刀、调料、烤箱说明摆出来，不把整个仓库搬来。

TagMemo
  是老厨师的经验：
  你说“下雨天想吃热乎的”，他会联想到砂锅、姜汤、炖菜，
  而不是只搜索“下雨”两个字。
```

放回 VCP 系统里：

```text
当前上下文
  -> ContextBridge 维护语义重心和上下文向量
  -> DynamicTools 按任务展开相关工具说明
  -> TagMemo 在 RAG 检索时做标签联想和向量增强
  -> ToolBox / ContextFolding 控制提示词和历史上下文展开
  -> River / vref / Base64Memo 把必要上下文、文件、附件传给工具或模型
```

更准确地说：

- **TagMemo** 让记忆系统更会联想。
- **ContextBridge** 让插件共享上下文状态。
- **DynamicTools** 让工具生态在 token 成本内可控。

这三件套共同构成 VCP 的语义调度底座。它们让模型看到的不是“原始堆料”，而是经过上下文筛选、记忆联想、工具裁剪后的任务现场。

---

## 22. TagMemo+：不是普通 TagMemo，而是测地线重排

上一节把 `TagMemo` 放进三件套里讲了，但 `TagMemo+` 值得单独拆出来。它不是简单地“TagMemo 权重更大”，而是在 `TagMemo` 的标签能量传播之后，再用标签网络的“地形距离”对候选结果做一次二次排序。

### 22.1 入口语法

源码里确认了四种写法：

```text
::TagMemo
  启用 TagMemo，使用动态 tagWeight，不启用测地线重排。

::TagMemo0.3
  启用 TagMemo，固定 tagWeight=0.3，不启用测地线重排。

::TagMemo+
  启用 TagMemo，并启用测地线重排，tagWeight 仍使用动态权重。

::TagMemo+0.3
  启用 TagMemo，并启用测地线重排，tagWeight 固定为 0.3。
```

对应源码位置：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2371`：解析 `::TagMemo` / `::TagMemo+`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2380`：构造 `geoOptions`，把 `geodesicRerank`、`geoAlpha`、`minGeoSamples` 传给搜索层。
- `rag_params.json:22`：配置 `KnowledgeBaseManager.geodesicRerank`。

另外，工具态的 `LightMemo` 也支持同一套能力，只是入口写法不同：

```text
tag_boost: "0.6"
  普通 TagMemo。

tag_boost: "0.6+"
  TagMemo+，也就是 Wave v8 测地线重排。
```

对应源码位置：

- `Plugin/LightMemo/LightMemo.js:152`：解析 `tag_boost` 的 `+` 后缀。
- `Plugin/LightMemo/LightMemo.js:352`：LightMemo 内部调用测地线重排。
- `Plugin/LightMemo/plugin-manifest.json:41`：工具说明里明确暴露 `tag_boost: "0.6+"`。

### 22.2 调用链

完整链路可以这样看：

```text
RAG 占位符命中 ::TagMemo+
  -> RAGDiaryPlugin 解析 useGeodesicRerank=true
  -> 预调用 applyTagBoost 感应核心标签与幽灵节点
  -> vectorDBManager.search(..., tagWeight, coreTagsForSearch, geoOptions)
  -> KnowledgeBaseManager.search 解析 options
  -> TagMemoEngine.applyTagBoost 改写查询向量
  -> applyTagBoost 内部生成 lastEnergyField
  -> VexusIndex.search 做普通 KNN 检索
  -> TagMemoEngine.geodesicRerank 对候选结果重排
  -> hydrate chunk 文本与标签元数据
  -> TimeDecay / Rerank / Truncate / Expand / Associate 等后处理
```

关键源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2435`：搜索前先用 `applyTagBoost()` 感应标签，得到 `coreTagsForSearch`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2497`：普通路径搜索时把 `geoOptions` 传入 `vectorDBManager.search()`。
- `KnowledgeBaseManager.js:417`：`search()` 接受扩展 `options`。
- `KnowledgeBaseManager.js:488`：搜索前真正调用 `TagMemoEngine.applyTagBoost()`。
- `TagMemoEngine.js:68`：每次 TagMemo 开始时清空旧的 `lastEnergyField`，避免跨请求污染。
- `TagMemoEngine.js:265`：Spike Propagation 完成后缓存 `lastEnergyField`。
- `KnowledgeBaseManager.js:517`：单库搜索在 hydrate 前调用 `geodesicRerank()`。
- `KnowledgeBaseManager.js:642`：全库搜索在合并排序后也调用 `geodesicRerank()`。
- `TagMemoEngine.js:537`：`geodesicRerank()` 方法入口。

### 22.3 它到底多做了什么

普通 `TagMemo` 做的是“改写查询向量”：它先从问题向量里感应出相关标签，再沿着标签共现网络扩散，最后把这些标签合成一个上下文向量，与原始查询向量融合。

`TagMemo+` 多出来的是“重排候选结果”：它不会只问“这个 chunk 和问题向量像不像”，还会问“这个 chunk 所属文件的标签，是否落在刚才那片标签能量场里”。

算法上，`geodesicRerank()` 会做这几件事：

```text
候选 chunk
  -> 查 chunk_id 对应 file_id
  -> 查 file_id 对应 tag_id 列表
  -> 在 lastEnergyField 里查这些 tag_id 的能量
  -> 命中标签数量达到 minGeoSamples 才计算 geoScore
  -> normalizedGeo = geoScore / maxGeo
  -> finalScore = (1 - alpha) * knnScore + alpha * normalizedGeo
  -> 按 finalScore 重排
```

它有三层退化保护：

| 层级 | 情况 | 行为 |
|---|---|---|
| L0 | `lastEnergyField` 为空 | 直接返回原始排序 |
| L1 | 某个 chunk 命中的标签数小于 `minGeoSamples` | 这个 chunk 的 `geoScore=0` |
| L2 | 所有候选的 `maxGeo=0` | 整体退回纯 KNN 排序 |

对应源码：

- `TagMemoEngine.js:527`：注释列出 L0/L1/L2 三层防御。
- `TagMemoEngine.js:577`：按候选结果查标签能量。
- `TagMemoEngine.js:599`：`hitCount >= minGeoSamples` 才计算 `geoScore`。
- `TagMemoEngine.js:623`：结果保留 `geo_score`、`normalized_geo`、`geo_hit_count`。

### 22.4 和 Rerank / Rerank+ 的区别

`TagMemo+` 和 `Rerank+` 都叫“重排”，但不是一回事。

| 项目 | TagMemo+ | Rerank / Rerank+ |
|---|---|---|
| 位置 | 向量检索阶段内部，hydrate 前 | RAGDiaryPlugin 后处理阶段 |
| 依据 | 本地标签网络、共现矩阵、能量场 | 外部 reranker 模型返回的相关性分数 |
| 是否需要外部 API | 不需要 | 需要 `RerankUrl`、`RerankApi`、`RerankModel` |
| 是否截断候选池 | 不截断，只重排 | 最终会按 `originalK` 截断 |
| 适合解决 | 深层语义联想、标签网络里的隐含关联 | 文本级精排、问题和候选片段的直接相关性 |

更准确的顺序是：

```text
TagMemo / TagMemo+
  -> KNN 搜索内部增强与测地线重排
  -> TimeDecay
  -> Rerank / Rerank+
  -> Truncate
  -> Associate
  -> Expand
```

也就是说，`::TagMemo+::Rerank+0.7` 是可以叠加理解的：前者先用本地标签地形把候选池调顺，后者再让外部 reranker 做文本级精排或 RRF 融合。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2358`：解析 `::Rerank+`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2567`：后处理顺序是 `TimeDecay -> Rerank -> Truncate`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3406`：`_rerankDocuments()` 入口。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3577`：`Rerank+` 使用 RRF 融合。
- `docs/V8_GEODESIC_RERANK_DEVPLAN.md:259`：设计上明确 `geodesicRerank` 只重排不截断，避免提前压缩 Rerank+ 候选池。

### 22.5 生活化理解

普通向量搜索像在图书馆里按书名和简介相似度找书。

`TagMemo` 像一个熟悉馆藏的老馆员。你说“我想找那种雨夜、孤独、猫、城市边缘的故事”，他不会只搜“雨夜”和“猫”，还会联想到“陪伴、流浪、潮湿街道、观察者、温柔的危险感”。

`TagMemo+` 则像老馆员又看了一眼借阅路线图：有些书标题没那么像，但它们经常和“雨夜、孤独、流浪、陪伴”这几类书放在同一条读者路径上。于是它会把这些书往前排。

所以使用心法是：

> 想要“语义联想增强”，用 `::TagMemo`。想要“语义联想增强之后，再按标签网络地形重新排队”，用 `::TagMemo+`。如果还想让外部模型判断文本是否真的贴题，再叠加 `::Rerank` 或 `::Rerank+`。

---

## 23. 目前还漏掉的核心概念清单

这一轮补查后，我认为除了前面已经写过的词元捕网、思维簇、上下文引力场、TagMemo、ContextBridge、DynamicTools，还有下面这些概念值得继续深入。它们不是边角功能，很多都在 VCP 的“智能调度层”里起关键作用。

### 23.1 EPA / LRS 动态参数系统

EPA 是很多动态决策的底层仪表盘。它会把查询向量投影到语义空间里，得到逻辑深度 `L`、共振 `R`，再结合 ContextVectorManager 计算语义宽度 `S`。这些指标会影响动态 `K`、`tagWeight`、标签截断比例，以及 ContextFolding 的折叠激进程度。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:581`：`_calculateDynamicParams()`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:596`：读取 EPA 分析。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:601`：计算语义宽度 `S`。
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:285`：`computeLogicDepth()`。
- `Plugin/RAGDiaryPlugin/ContextVectorManager.js:322`：`computeSemanticWidth()`。

生活类比：它像医生先量体温、血压、血氧，再决定药量和检查范围。VCP 不是固定每次召回 5 条、固定 Tag 权重，而是看这次问题到底聚焦还是发散。

### 23.2 Time / TimeDecay / 时间连续性召回

VCP 的记忆不是纯语义系统，它也很重视时间。`::Time` 可以让系统解析用户问题里的时间范围，走“语义召回 + 时间召回”的双路检索；新对话阶段还会补最近几条记忆，保持连续性。`::TimeDecay` 则会在候选池里按时间衰减重排。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2356`：解析 `::Time`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2365`：解析 `::TimeDecay` 参数。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2478`：新对话阶段准备最近 chunk 补充。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2572`：应用 `_applyTimeDecay()`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3279`：`_applyTimeDecay()` 方法。

生活类比：你找聊天记录时，通常不是只搜关键词，还会想“应该是上周那次”“刚刚聊过的那件”。VCP 把这两种找法合在一起。

### 23.3 AIMemo 聚合语义推理

`AIMemo` 是跨日记本聚合检索模式。它不是普通占位符直接召回，而是先收集多个 AIMemo 请求，再统一交给 `AIMemoHandler` 聚合处理。它还有一个显式许可证开关：只有系统提示词里出现 `[[AIMemo=True]]`，`::AIMemo` 才真正生效。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:104`：初始化 `AIMemoHandler`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1121`：检测 `[[AIMemo=True]]`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1476`：收集 AIMemo 请求。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1884`：调用 `processAIMemoAggregated()`。
- `Plugin/RAGDiaryPlugin/AIMemoHandler.js:62`：聚合处理入口。

生活类比：普通 RAG 像分别问几个同事：“你那里有没有相关资料？”AIMemo 像先把几个同事的资料收上来，再让一个协调人统一整理成一份跨部门报告。

### 23.4 Expand 和 Associate

`::Expand` 是父文档展开：先命中 chunk，再把它所在的完整日记文件展开出来。`::Associate` 是联想共现发现：把已经召回的 chunk 当种子，再去跨索引寻找经常共同出现的相关内容。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2392`：解析 `::Expand`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2395`：解析 `::Associate`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2642`：执行联想发现。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2652`：执行父文档展开。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2785`：`_expandChunksToFullDocuments()`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2881`：`_applyAssociativeDiscovery()`。

生活类比：`Expand` 像先找到书里一句话，再把整章拿出来；`Associate` 像拿到几张线索卡以后，去找经常和这些线索一起出现的其他线索卡。

### 23.5 Ghost Tags / 幽灵节点

幽灵节点是临时注入 TagMemo 网络的标签对象。它们可以带向量，但不一定已经写入正式标签库。RAGDiaryPlugin 会把 hard/soft ghost tags 合并进 `coreTagsForSearch`，TagMemoEngine 再给它们分配负数 ID，并混入标签向量 Map 参与本次计算。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:346`：构造内存级幽灵节点。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1222`：准备 hard/soft ghost objects。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2437`：把字符串标签和幽灵对象一起传入 TagMemo。
- `TagMemoEngine.js:112`：分流 hard/soft ghost objects。
- `TagMemoEngine.js:344`：注入幽灵节点。
- `TagMemoEngine.js:383`：把幽灵向量混入正规标签 Map。

生活类比：正式标签像图书馆固定分类号；幽灵节点像这次临时贴上的便签。它不一定进入永久目录，但能帮这一次检索更贴近当前任务。

### 23.6 FoldingStore / ContextFoldingV2

ContextFoldingV2 是上下文折叠协议，FoldingStore 是它背后的持久化摘要柜。RAGDiaryPlugin 会把历史上下文 hash、向量和摘要状态同步到 SQLite。ContextBridge 再把 `foldingStore` 暴露给折叠插件。

对应源码：

- `Plugin/RAGDiaryPlugin/FoldingStore.js:10`：`FoldingStore` 类。
- `Plugin/RAGDiaryPlugin/FoldingStore.js:84`：`folding_entries` 表结构。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1108`：同步上下文到 FoldingStore。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4028`：`_syncContextToFoldingStore()`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4258`：ContextBridge 暴露 `foldingStore`。
- `README.md:314`：`[[ContextFoldingV2]]` 激活方式。

生活类比：长会开到一半，秘书会把旧议题折成摘要卡片。需要时翻摘要，不需要时就不要把完整发言塞回会议桌。

### 23.7 RoleValve 角色阀门

`RoleValve` 是 RAG 占位符的条件开关。它会按当前对话里 User、Assistant、System 消息数量做逻辑判断，决定这个占位符是否召回。

对应源码：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1043`：`RoleValve` 语义解析入口。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1496`：聚合模式里检查 RoleValve。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1555`：单日记本模式里检查 RoleValve。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1922`：普通占位符处理前检查 RoleValve。

生活类比：它像会议室门禁。不是所有资料都在任何阶段开放，可能要等 Assistant 已经回答过几轮，或者系统消息数量满足条件，才允许某个记忆库进场。

### 23.8 Archery / ink 工具调用控制

VCP 的工具协议不只是“调用工具并等待结果”。`archery: no_reply` 允许异步射箭，工具发出去但模型不等返回；`ink: mark_history` 则允许某些结果即使在 `ShowVCP=false` 时也强制写入后续历史。

对应源码：

- `modules/vcpLoop/toolCallParser.js:74`：工具块解析返回 `archery`、`markHistory`、`river`、`vref`。
- `modules/vcpLoop/toolCallParser.js:94`：解析 `archery`。
- `modules/vcpLoop/toolCallParser.js:96`：解析 `ink`。
- `modules/vcpLoop/toolCallParser.js:223`：把普通工具和 archery 工具分组。
- `README.md:1125`：`archery: no_reply` 说明。
- `README.md:1126`：`ink: mark_history` 说明。

生活类比：普通工具调用像你派人去取文件并坐着等。Archery 像你顺手发一封后台邮件，不耽误会议继续；ink 像你特别交代“这件事要写进会议纪要”。

### 23.9 LightMemo

LightMemo 是轻量回忆工具，不通过系统提示词占位符，而是作为工具直接调用。它会先从数据库收集候选 chunk，再做 BM25/语义/TagMemo/Rerank 混合排序。它也支持 `tag_boost: "0.6+"` 形式启用 TagMemo+。

对应源码：

- `Plugin/LightMemo/LightMemo.js:75`：LightMemo 插件类。
- `Plugin/LightMemo/LightMemo.js:147`：读取 `tag_boost`。
- `Plugin/LightMemo/LightMemo.js:291`：应用 TagMemo boost。
- `Plugin/LightMemo/LightMemo.js:352`：应用 Wave v8 测地线重排。
- `Plugin/LightMemo/LightMemo.js:386`：解析 Rerank+。

生活类比：RAG 占位符像提前写在系统提示词里的固定资料柜；LightMemo 像对话中随时拿起一个小型检索器，临时查一把记忆。

### 23.10 SkillBridge 和 ChromeBridge

这两个偏工具生态层，但也属于 VCP 高阶能力。

`SkillBridge` 通过折叠协议把 Skill 目录索引注入系统提示词，不把全部 Skill 正文一次性塞进去。`ChromeBridge` 则通过浏览器桥接和 CDP 能力，让模型不只是“模拟点击”，而是能更接近浏览器内核地执行和查询页面。

对应源码：

- `README.md:324`：SkillBridge 设计说明。
- `Plugin/SkillBridge/plugin-manifest.json:20`：`{{VCPSkillBridge}}` 占位符。
- `README.md:264`：ChromeBridge 浏览器模组说明。
- `Plugin/ChromeBridge/ChromeBridge.js:22`：ChromeBridge 初始化。
- `Plugin/ChromeBridge/plugin-manifest.json:56`：CDP 相关命令暴露。

生活类比：SkillBridge 像一本技能目录，先告诉你有哪些教材，需要哪本再翻哪本；ChromeBridge 像把浏览器从“遥控鼠标”升级成“接入控制台和页面状态”。

### 23.11 下一步建议的深挖优先级

按对理解 VCP 主线的价值排序，我建议后续这样推进：

```text
P0
  EPA / LRS 动态参数系统
  Time / TimeDecay / 时间连续性召回
  AIMemo 聚合语义推理
  Expand / Associate
  Ghost Tags
  FoldingStore / ContextFoldingV2

P1
  RoleValve
  LightMemo
  Archery / ink / River / vref 工具协议扩展
  SkillBridge
  ChromeBridge

P2
  全局统一时间感知
  AgentDream 等默认禁用或边缘高阶插件
```

如果把 VCP 当作一套“AI 工作台操作系统”，这些概念的位置大致是：

```text
记忆层
  TagMemo / TagMemo+ / Time / AIMemo / LightMemo / Expand / Associate

上下文层
  ContextBridge / ContextFoldingV2 / FoldingStore / EPA-LRS

工具层
  DynamicTools / ToolBox / Archery / ink / River / vref / SkillBridge / ChromeBridge

治理层
  RoleValve / Truncate / Rerank / Rerank+
```

这张图能帮助我们后面继续读源码：不要只按插件名字看，而要看它到底是在“记忆、上下文、工具、治理”哪一层工作。

---

## 24. 统一生活化隐喻：把 VCP 想成一座 AI 城市

为了避免前面类比太分散，后续统一使用一个体系：**VCP 是一座给 AI 生活和工作的城市**。

在这座城市里：

```text
模型
  是城市里的居民和决策者。

VCPToolBox
  是城市操作系统：道路、档案馆、工具行会、调度中心、门禁、广播台都在这里。

插件
  是城市里的专业店铺、工坊、服务机构。

RAG / TagMemo
  是城市图书馆和记忆档案馆。

ContextBridge / FoldingStore
  是会议秘书处和档案压缩库。

DynamicTools / ToolBox
  是城市导览牌和工具货架。

WebSocket 分布式节点
  是外地分馆、远程工坊和临时施工队。

AdminPanel
  是市政控制台。
```

这套类比的好处是：以后看到一个新能力，不要先问“它是什么插件”，而是先问：

```text
它是在城市的哪个区域工作？
  入口交通？
  角色档案？
  记忆图书馆？
  工具工坊？
  物流管道？
  远程分馆？
  市政门禁？
  外部口岸？
```

这个问题能直接帮助你判断：应该写系统提示词、写 RAG 占位符、写插件 manifest、写工具协议、还是改配置。

### 24.1 城门：OpenAI 兼容 API 入口

VCP 对外看起来像一个 OpenAI-compatible API，但内部会先经过一整套城市入口检查。

```text
客户端请求 /v1/chat/completions
  -> Bearer Token 认证
  -> 特殊模型白名单判断
  -> 模型名重定向
  -> 消息预处理器链
  -> 占位符和变量展开
  -> 上游模型请求
  -> VCP 工具循环
  -> SSE 或 JSON 返回
```

源码位置：

- `server.js:1139`：`/v1/chat/completions` 入口。
- `server.js:1153`：`/v1/chatvcp/completions` 强制显示 VCP 信息入口。
- `server.js:1167`：`/v1/human/tool` 人类直接调用工具入口。
- `server.js:925`：`/v1/schedule_task` 定时任务入口。
- `server.js:986`：`/v1/interrupt` 中断活动请求。
- `server.js:1377`：异步插件回调 `/plugin-callback/:pluginName/:taskId`。
- `modules/chatCompletionHandler.js:324`：主聊天处理器入口。
- `modules/chatCompletionHandler.js:453`：模型重定向日志位置。
- `routes/specialModelRouter.js:68`：特殊模型白名单透传入口。

城市类比：这是城门和交通枢纽。普通车进主路，图像模型或 embedding 模型可能走专用车道，紧急情况可以通过 `/v1/interrupt` 拉下刹车。

### 24.2 翻译局：消息预处理和变量展开

VCP 最强的一层不是工具本身，而是模型请求进入上游前，会先经过“翻译局”。翻译局会把系统提示词里的占位符、角色卡、变量文件、静态插件输出、动态工具说明全部展开成模型能读懂的内容。

主要变量类型：

| 变量类型 | 城市类比 | 作用 |
|---|---|---|
| `{{agent:xxx}}` / `{{xxx}}` | 居民身份档案 | 展开 Agent 角色文件 |
| `{{toolbox:xxx}}` | 专用工具蓝图 | 展开可复用工具说明块 |
| `{{Tar*}}` / `{{Var*}}` | 城市公告文件 | 从环境变量或 `TVStxt` 文件读取内容 |
| `{{SarPrompt*}}` | 高级预设档案 | 注入 SarPrompt 预设 |
| `{{Date}}` / `{{Time}}` / `{{Today}}` | 城市时钟 | 注入当前日期时间 |
| 静态插件占位符 | 店铺定时公告 | 注入 static 插件周期性输出 |
| `{{VCPDynamicTools}}` | 动态导览牌 | 按任务展开相关工具 |
| `{{VCPAllTools}}` | 全城工具总目录 | 展开所有工具说明 |
| `{{VCP_ASYNC_RESULT::...}}` | 任务回执柜 | 读取异步任务结果 |

源码位置：

- `modules/messageProcessor.js:37`：变量展开总入口 `resolveAllVariables()`。
- `modules/messageProcessor.js:41`：Agent 和 Toolbox 占位符的权限防护。
- `modules/messageProcessor.js:60`：同一上下文只允许展开一个 Agent。
- `modules/messageProcessor.js:151`：动态折叠协议入口。
- `modules/messageProcessor.js:377`：`SarPrompt` 注入。
- `modules/messageProcessor.js:423`：`Tar*` / `Var*` 变量处理。
- `modules/messageProcessor.js:451`：日期时间变量注入。
- `modules/messageProcessor.js:465`：静态插件占位符注入。
- `modules/messageProcessor.js:490`：`{{VCPDynamicTools}}` 注入。
- `modules/messageProcessor.js:544`：异步任务结果占位符。
- `modules/agentManager.js:272`：读取 Agent 角色文件。

城市类比：你交给城市一张杂乱的办事单，翻译局会把“去找小克的身份档案”“把天气公告贴进来”“把这次可能用到的工具目录展开”全部处理好，再送给模型。

### 24.3 营业执照：插件 Manifest

在 VCP 城市里，一个插件能不能开张，不是靠文件名，而是靠 `plugin-manifest.json` 这张营业执照。

营业执照声明了：

```text
这个店叫什么
它属于哪种店
怎么启动
怎么通信
有哪些工具指令
有哪些静态占位符
是否注册后台路由
是否需要 ContextBridge
是否需要管理员权限
配置项有哪些默认值
```

六种插件类型可以这样理解：

| 插件类型 | 城市类比 | 典型用途 |
|---|---|---|
| `static` | 定时公告牌 | 天气、状态、工具说明、监控报告 |
| `messagePreprocessor` | 入城翻译员 | RAGDiaryPlugin 这类请求前处理 |
| `synchronous` | 现场办事窗口 | 搜索、读写文件、计算、生成图片 |
| `asynchronous` | 长工单工坊 | 视频生成、耗时任务，完成后回调 |
| `service` | 常驻公共设施 | 图床、日志、浏览器桥、后台 API |
| `hybridservice` | 既有窗口又有后台的机构 | LightMemo、ChromeBridge 等 |

源码位置：

- `Plugin.js:475`：扫描插件目录并读取 manifest。
- `Plugin.js:494`：识别 `messagePreprocessor` / `hybridservice`。
- `Plugin.js:497`：direct 协议模块加载。
- `Plugin.js:565`：调用插件 `initialize()`。
- `Plugin.js:582`：给声明 `requiresContextBridge` 的插件注入 ContextBridge。
- `Plugin.js:633`：从 `invocationCommands` 生成工具说明。
- `Plugin.js:1204`：初始化 service 插件。
- `Plugin.js:1225`：service 插件注册 API 路由。
- `Plugin.js:1475`：direct 常驻插件变更时跳过自动热重载。
- `docs/PLUGIN_ECOSYSTEM.md:1`：插件生态完整文档。

城市类比：manifest 就像营业执照和店铺菜单。没有它，VCP 不知道这家店卖什么、怎么联系、能不能远程开分店、出问题怎么关门。

### 24.4 物流单：VCP 工具协议

VCP 没有走 OpenAI function-calling，而是使用自己的工具面单：

```text
<<<[TOOL_REQUEST]>>>
tool_name:「始」工具名「末」,
param:「始」参数值「末」
<<<[END_TOOL_REQUEST]>>>
```

这张物流单上还可以写特殊标记：

| 字段 | 城市类比 | 作用 |
|---|---|---|
| `archery: no_reply` | 放飞异步信使 | 工具执行但模型不等结果 |
| `ink: mark_history` | 写入会议纪要 | 强制把结果注入历史 |
| `river: full/text/last:N/semantic:N` | 携带案卷上下文 | 给工具传入对话上下文 |
| `vref: N` | 调档 N 份资料 | 附加最相关知识库文件 URL |

源码位置：

- `modules/vcpLoop/toolCallParser.js:4`：工具块起止标记。
- `modules/vcpLoop/toolCallParser.js:74`：解析结果结构包含 `archery`、`markHistory`、`river`、`vref`。
- `modules/vcpLoop/toolCallParser.js:94`：解析 `archery`。
- `modules/vcpLoop/toolCallParser.js:96`：解析 `ink`。
- `modules/vcpLoop/toolCallParser.js:98`：解析 `river`。
- `modules/vcpLoop/toolCallParser.js:100`：解析 `vref`。
- `modules/vcpLoop/toolExecutor.js:188`：工具执行入口处理 `river` / `vref`。
- `modules/vcpLoop/toolExecutor.js:197`：`river: full`。
- `modules/vcpLoop/toolExecutor.js:203`：`river: last:N`。
- `modules/vcpLoop/toolExecutor.js:209`：`river: semantic:N`。
- `modules/vcpLoop/toolExecutor.js:302`：解析并注入 `vref_files`。
- `README.md:1125`：`archery`、`ink`、`river`、`vref` 协议说明。

城市类比：普通工具调用只是寄一个包裹；`river` 是把案卷一起附上；`vref` 是让档案馆自动找几份相关材料放进包裹；`archery` 是发出信使后不等回信；`ink` 是要求把回执写进会议纪要。

### 24.5 物流仓库：file://、Base64Memo 和 FileFetcher

很多工具不只传文本，还要传文件、图片、音频、视频。VCP 里有两条重要物流线：

```text
file:// 物流线
  工具参数里出现 file://
  -> 本地可读则直接使用
  -> 不在本地则通过分布式 FileFetcher 回源获取
  -> 缓存成本地 file:// URL

Base64Memo 物流线
  RAG 召回文本里含附件链接
  -> ::Base64Memo 提取附件
  -> 读取并转成 data:*;base64
  -> 注入首条用户消息的多模态 content 数组
```

源码位置：

- `Plugin.js:752`：分布式插件跳过本地预拉取，直接透传 `file://`。
- `Plugin.js:759`：本地插件调用前解析 `file://`。
- `FileFetcherServer.js:43`：`fetchFile()`。
- `FileFetcherServer.js:149`：`resolveFileUrl()`。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1111`：收集 `::Base64Memo` 附件。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1320`：把附件转成 base64 并注入用户消息。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2686`：`::Base64Memo` 提取逻辑。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3961`：`_extractAttachments()`。
- `modules/chatCompletionHandler.js:598`：识别多模态 base64 part。

城市类比：`file://` 是城市物流仓单。文件不一定在主城，可能在远程分馆；FileFetcher 负责调货。`Base64Memo` 像档案馆把照片、录音、附件复印成模型能直接看的随身材料。

### 24.6 远程分馆：WebSocket 分布式网络

VCP 的分布式不是附属功能，而是城市网络的一部分。远程节点可以注册工具，主服务器像中央调度站一样把工具请求派发过去。

WebSocket 里有几类客户端：

| 客户端类型 | 城市类比 | 作用 |
|---|---|---|
| `VCPLog` | 城市日志广播 | 接收日志、审批请求等 |
| `VCPInfo` | 城市信息大屏 | 接收 RAG、工具、状态信息 |
| `DistributedServer` | 外地分馆 | 注册远程工具并执行 |
| `ChromeObserver` | 浏览器观察哨 | 上报网页状态 |
| `ChromeControl` | 浏览器遥控信使 | 发送浏览器控制命令 |
| `AdminPanel` | 市政控制台屏幕 | 接收后台状态 |

源码位置：

- `WebSocketServer.js:20`：核心客户端 Map。
- `WebSocketServer.js:133`：各种 WebSocket 路径识别。
- `WebSocketServer.js:197`：分布式节点连接后登记。
- `WebSocketServer.js:242`：连接确认消息。
- `WebSocketServer.js:468`：`broadcastVCPInfo()`。
- `WebSocketServer.js:560`：处理 `register_tools`。
- `WebSocketServer.js:603`：处理远程 `tool_result`。
- `WebSocketServer.js:623`：`executeDistributedTool()`。
- `Plugin.js:1265`：注册分布式工具到 PluginManager。
- `Plugin.js:1292`：分布式节点下线时注销工具。
- `docs/DISTRIBUTED_ARCHITECTURE.md:1`：分布式架构文档。

城市类比：主城不需要自己拥有所有设备。GPU、浏览器、文件、专用工具都可以在外地分馆，中央只维护地图、身份、调度和回执。

### 24.7 市政门禁：认证、审批和权限

VCP 权限很大，所以它有多层门禁：

```text
API Bearer Token
  保护 /v1/* 对话接口。

Admin Basic Auth / Cookie
  保护 /admin_api 和后台。

VCP_Key
  保护 WebSocket 节点。

toolApprovalConfig
  对敏感工具调用做人工审批。

requiresAdmin
  给部分插件注入解密后的管理员验证码。

ShowVCP / chatvcp
  控制工具执行过程是否展示给用户。
```

源码位置：

- `server.js:613`：Admin 鉴权中间件。
- `server.js:806`：通用 API Bearer Token 鉴权。
- `server.js:370`：读取 `ShowVCP`。
- `server.js:1153`：`/v1/chatvcp/completions` 强制显示 VCP 输出。
- `Plugin.js:791`：工具调用审批决策。
- `Plugin.js:819`：广播 `tool_approval_request`。
- `Plugin.js:1188`：处理审批结果。
- `Plugin.js:985`：`requiresAdmin` 插件注入管理员验证码。
- `modules/toolApprovalManager.js:116`：审批规则判断入口。
- `routes/admin/config.js:26`：后台读取工具审批配置。

城市类比：VCP 不是一个普通工具箱，而是一座能调动文件、浏览器、外部 API、远程机器的城市。所以它需要城门、后台门禁、施工许可、危险作业审批。

### 24.8 外部口岸：MCPO / MCP 兼容

VCP 自己有原生插件协议，但也预留了 MCP 兼容口岸。`MCPO` 插件当前是 `.block` 禁用态，但代码和说明都在，代表 VCP 可以通过 mcpo 把 MCP 工具转译成 VCP 工具。

源码位置：

- `README.md:360`：MCPO / MCP 兼容端口说明。
- `Plugin/MCPO/plugin-manifest.json.block:3`：MCPO 插件处于禁用态。
- `Plugin/MCPO/mcpo_plugin.py:3`：MCPO 插件实现说明。
- `Plugin/MCPO/mcpo_plugin.py:306`：向 MCPO 服务器发送 HTTP 请求。
- `Plugin/MCPOMonitor/plugin-manifest.json.block:3`：MCPO 监控插件禁用态。

城市类比：MCPO 是外贸口岸。VCP 城市内部有自己的营业执照和物流单，但也可以接收外城 MCP 商队，把它们转成 VCP 城内可调度的店铺。

### 24.9 市政控制台：AdminPanel 和热调参

AdminPanel 不只是网页后台，它是 VCP 城市的控制室：配置、插件、预处理器顺序、RAG 参数、工具审批、动态工具索引，都可以在这里管理。

源码位置：

- `server.js:787`：挂载 Admin 鉴权。
- `server.js:1343`：创建并注入 `adminPanelRoutes`。
- `server.js:1447`：service 插件注册路由后挂载 Admin API。
- `routes/adminPanelRoutes.js:75`：挂载配置模块。
- `routes/adminPanelRoutes.js:76`：挂载插件和预处理器模块。
- `routes/admin/config.js:99`：读取主配置。
- `routes/admin/config.js:126`：写入主配置。
- `routes/admin/dynamicTools.js:91`：后台重建动态工具索引。
- `docs/API_ROUTES.md:1`：API 路由文档。

城市类比：如果提示词是城市公告，插件是店铺，AdminPanel 就是市政大厅。它不是给模型看的，而是给城市管理员调度和维护用的。

### 24.10 模型专用车道：ModelRedirect 和 SpecialModelRouter

VCP 既要兼容各种前端请求，又要适配后端模型供应商，所以模型名和模型类型有一层路由。

```text
ModelRedirect
  客户端请求 public model name
  -> VCP 转成后端真实 model name

SpecialModelRouter
  图像模型 / embedding 模型白名单
  -> 绕过 VCP 工具循环
  -> 直接透传后端
```

源码位置：

- `server.js:399`：初始化 `ModelRedirectHandler`。
- `server.js:1542`：加载 `ModelRedirect.json`。
- `modules/chatCompletionHandler.js:453`：请求模型重定向。
- `server.js:602`：挂载特殊模型路由。
- `routes/specialModelRouter.js:68`：特殊模型 chat completions 透传。
- `routes/specialModelRouter.js:90`：转发到上游 `/v1/chat/completions`。

城市类比：普通货车走主城道路，图像生成和 embedding 这种专车走专用车道，不进入工具循环，避免被不必要的城市流程拦住。

---

## 25. 从理解到造工具：一张设计检查表

如果目标是以后基于 VCP 造自己的工具，可以用这张检查表。它比“我写一个脚本”更接近 VCP 的真实开发方式。

### 25.1 先判断工具属于哪类城市机构

```text
只是定时生成一段提示词？
  -> static 插件。

每次被模型调用，马上返回结果？
  -> synchronous 插件。

任务很慢，先返回任务号，稍后回调？
  -> asynchronous 插件。

需要常驻服务、注册路由、维护连接？
  -> service 插件。

既要常驻，又要能被工具调用？
  -> hybridservice 插件。

要改写消息、做 RAG、注入上下文？
  -> messagePreprocessor 插件。
```

源码对照：

- `Plugin.js:885`：同步/异步 stdio 插件执行约束。
- `Plugin.js:872`：hybridservice direct 工具调用。
- `Plugin.js:1204`：service 插件初始化。
- `Plugin.js:367`：messagePreprocessor 执行入口。

### 25.2 再判断工具需要哪种上下文

| 需求 | 推荐机制 |
|---|---|
| 只需要当前参数 | 普通工具参数 |
| 需要最近对话 | `river:last:N` |
| 需要完整对话 | `river:full` |
| 需要语义相关历史消息 | `river:semantic:N` |
| 需要相关知识库文件 | `vref:N` |
| 需要 RAG 召回附件 | `::Base64Memo` |
| 需要全局上下文向量 | `requiresContextBridge` |
| 需要动态工具说明 | `{{VCPDynamicTools}}` |
| 需要外部 Skill 目录 | `{{VCPSkillBridge}}` |

这一步很重要。很多工具不需要自己做复杂记忆，只要正确选择 `river`、`vref` 或 ContextBridge，就能借用 VCP 已经做好的上下文能力。

### 25.3 再决定放在哪里

```text
放在系统提示词
  适合：稳定身份、长期规则、RAG 占位符、DynamicTools。

放在 TVStxt
  适合：长提示词、工具蓝图、可编辑模板。

放在 Agent
  适合：角色人格、角色专属工作流。

放在 Plugin
  适合：真正要执行代码、访问文件、联网、调用外部 API 的能力。

放在 dailynote / RAG
  适合：可被语义召回的知识、历史、样例、说明书。

放在 SkillBridge
  适合：大量按需读取的开发技能和外部教程。
```

城市类比：不是所有东西都要开新店。有些只是公告，有些是档案，有些是工具说明，有些才需要真正雇一个工坊干活。

### 25.4 最后设计反馈和治理

一个成熟的 VCP 工具，最好提前想清楚：

```text
结果是否要给模型看？
  -> 普通返回 / messageForAI / ShowVCP / ink。

执行是否危险？
  -> toolApprovalConfig / requiresAdmin / 参数白名单。

是否耗时？
  -> asynchronous / archery。

是否需要被人类直接调用？
  -> /v1/human/tool + manifest invocationCommands。

是否需要后台配置？
  -> configSchema + Plugin/config.env.example + Admin API。

是否需要远程运行？
  -> distributed 工具注册或 WebSocket 节点。

是否需要可观测？
  -> VCPInfo / VCPLog / AdminPanel dashboard。
```

这就是 VCP 造工具的核心心智：

> 不是“写一个脚本给 AI 调用”，而是“给 AI 城市增加一家有营业执照、有菜单、有物流、有门禁、有反馈的店铺”。

### 25.5 一句话总图

```text
入口层
  server.js / ChatCompletionHandler / SpecialModelRouter

翻译层
  messageProcessor / AgentManager / TVStxt / static placeholders

记忆层
  RAGDiaryPlugin / KnowledgeBaseManager / TagMemoEngine / FoldingStore

工具层
  PluginManager / toolCallParser / toolExecutor / DynamicTools

物流层
  River / vref / Base64Memo / FileFetcher / WebSocket distributed

治理层
  AdminPanel / Auth / ToolApproval / ShowVCP / RoleValve

外部口岸
  MCPO / SkillBridge / ChromeBridge / distributed nodes
```

这张图可以作为后续读源码和造工具的导航图。每次遇到新功能，先把它放进这七层之一，再去找对应入口文件，理解速度会快很多。

---

## 26. 分布式 VCP：主城和外地分馆如何协同

前面第 24.6 只是把分布式当作“远程分馆”简单带过，但从源码看，VCP 的分布式是一个完整的城市级网络。它不是把请求转发到另一台机器那么简单，而是让远程节点成为 VCP 主城的一部分。

### 26.1 一句话心智模型

```text
VCP 主服务器
  是主城：负责身份认证、路由、插件目录、工具调度、广播、审批、文件缓存。

VCPDistributedServer
  是外地分馆：可以带着自己的工具、文件、算力、浏览器或特殊环境接入主城。

WebSocketServer
  是城际铁路调度中心：维护连接、登记分馆、分发工单、回收结果。

PluginManager
  是营业执照管理局：把远程工具临时登记成 VCP 插件。

DynamicToolRegistry
  是全城工具导览牌：远程工具上线/下线后，自动更新可见工具目录。

FileFetcherServer
  是跨城物流仓：当主城插件需要读取外地文件时，自动回源拉取并缓存。
```

所以分布式 VCP 的重点不是“远程执行”，而是：

> 远程节点带着工具和资源接入后，会被主城纳入同一套插件、工具说明、审批、调用、文件和广播体系。

### 26.2 星型拓扑：主城调度，多处分馆执行

VCP 分布式采用星型结构：

```text
             VCP 主服务器
          WebSocketServer.js
                  |
    --------------------------------
    |              |               |
 GPU 分馆       文件分馆       浏览器观察端
 分布式工具      远程文件       ChromeObserver
```

主服务器维护几张关键表：

| 表 | 源码变量 | 作用 |
|---|---|---|
| 普通客户端 | `clients` | `VCPLog`、`VCPInfo` 等 |
| 分布式节点 | `distributedServers` | 保存 `serverId -> { ws, tools, ips, serverName }` |
| 节点 IP | `distributedServerIPs` | 用 IP 反查文件来源服务器 |
| Chrome 控制端 | `chromeControlClients` | 浏览器控制命令发送端 |
| Chrome 观察端 | `chromeObserverClients` | 页面状态上报端 |
| AdminPanel | `adminPanelClients` | 后台实时状态推送 |
| 待处理远程工具 | `pendingToolRequests` | `requestId -> resolve/reject/timeout` |

源码位置：

- `WebSocketServer.js:20`：各种客户端 Map。
- `WebSocketServer.js:134`：分布式节点路径 `/vcp-distributed-server/VCP_Key=...`。
- `WebSocketServer.js:194`：节点连接后生成 `dist-<clientId>` 形式的 `serverId`。
- `WebSocketServer.js:246`：给分布式节点发送连接确认和 `serverId`。
- `docs/DISTRIBUTED_ARCHITECTURE.md:24`：官方分布式架构说明。

城市类比：分馆不直接和模型说话，而是先接入主城铁路网。主城给它一个站点编号 `serverId`，以后所有工单都按这个编号调度。

### 26.3 节点注册：远程工具拿到临时营业执照

分布式节点接入后，会发送 `register_tools` 消息，把自己能提供的工具 manifest 发给主服务器。

流程：

```text
分布式节点发送 register_tools
  -> WebSocketServer 过滤 internal_request_file
  -> PluginManager.registerDistributedTools(serverId, tools)
  -> 每个远程工具被标记 isDistributed=true
  -> 写入 toolManifest.serverId
  -> displayName 加上 [云端]
  -> 插入 pluginManager.plugins
  -> buildVCPDescription()
  -> emit tools_changed
  -> DynamicToolRegistry 同步工具目录
```

源码位置：

- `WebSocketServer.js:560`：处理 `register_tools`。
- `WebSocketServer.js:564`：过滤内部工具 `internal_request_file`，不让它出现在插件列表。
- `Plugin.js:1264`：`registerDistributedTools()`。
- `Plugin.js:1277`：标记 `toolManifest.isDistributed = true`。
- `Plugin.js:1278`：记录 `toolManifest.serverId = serverId`。
- `Plugin.js:1281`：显示名加 `[云端]`。
- `Plugin.js:1288`：触发 `tools_changed`。
- `modules/dynamicToolRegistry.js:648`：识别 manifest 是否来自 distributed。
- `modules/dynamicToolRegistry.js:650`：为远程工具生成 `distributed:${originId}:${manifest.name}` 的来源 key。

这里有一个使用上很重要的细节：如果远程工具名和主城已有工具名冲突，主城会跳过注册。

源码位置：

- `Plugin.js:1272`：远程工具名冲突时 skip。

城市类比：外地分馆开进主城时，会提交自己的营业执照。主城认可后，把它贴到全城工具地图上，并标注“云端”。但如果已经有同名店铺，主城不会让它覆盖本地店。

### 26.4 远程工具执行：同一张工具单，不同城市办事

模型调用远程工具时，工具协议本身不变，仍然是：

```text
<<<[TOOL_REQUEST]>>>
tool_name:「始」某个云端工具「末」,
...
<<<[END_TOOL_REQUEST]>>>
```

区别发生在 `PluginManager.processToolCall()` 内部：

```text
工具调用进入 PluginManager
  -> 找到 plugin manifest
  -> 如果 plugin.isDistributed=true
  -> WebSocketServer.executeDistributedTool(plugin.serverId, toolName, args)
  -> 生成 requestId
  -> 写入 pendingToolRequests
  -> 发送 execute_tool 给远程节点
  -> 远程节点执行后回传 tool_result
  -> 主城按 requestId resolve/reject
  -> 返回给 VCP 工具循环
```

源码位置：

- `Plugin.js:854`：判断 `plugin.isDistributed`。
- `Plugin.js:860`：调用 `executeDistributedTool()`。
- `WebSocketServer.js:623`：`executeDistributedTool(serverIdOrName, toolName, toolArgs, timeout)`。
- `WebSocketServer.js:647`：构造 `execute_tool` 消息。
- `WebSocketServer.js:656`：设置超时。
- `WebSocketServer.js:661`：写入 `pendingToolRequests`。
- `WebSocketServer.js:603`：收到 `tool_result`。
- `WebSocketServer.js:606`：按 `requestId` 找回 pending 请求。

城市类比：模型只知道“我要找这家店办事”，主城发现这家店在外地分馆，就把同一张工单通过城际铁路发过去。办完以后，分馆把回执寄回主城，主城再交给模型。

### 26.5 分布式异步回调：远程长工单也能回主城

远程节点不只支持同步结果，还支持异步插件回调转发。远程节点可以发送 `plugin_callback_forward`，主城会把结果保存到 `VCPAsyncResults`，并按插件 manifest 的 `webSocketPush` 配置广播。

流程：

```text
远程异步任务完成
  -> 分布式节点发送 plugin_callback_forward
  -> WebSocketServer.handleDistributedPluginCallback()
  -> 写入 VCPAsyncResults/<pluginName>-<taskId>.json
  -> 如果插件配置 webSocketPush
  -> broadcast 给目标客户端
```

源码位置：

- `WebSocketServer.js:51`：`handleDistributedPluginCallback()`。
- `WebSocketServer.js:67`：收到远程异步回调日志。
- `WebSocketServer.js:75`：保存到 `VCPAsyncResults`。
- `WebSocketServer.js:87`：读取插件 manifest 的 `webSocketPush`。
- `WebSocketServer.js:95`：广播异步回调通知。
- `WebSocketServer.js:615`：处理 `plugin_callback_forward`。

城市类比：外地工坊接了一个慢活，比如渲染视频。它先开工，完成后把成品和回执寄回主城档案柜，主城再通知对应的信息大屏或用户界面。

### 26.6 分布式静态占位符：远程分馆也能贴公告

分布式节点可以发送 `update_static_placeholders`，把远程产生的静态内容注入主城的静态占位符系统。这个能力很关键，因为它意味着远程节点不只是“工具执行器”，还可以成为系统提示词信息源。

流程：

```text
分布式节点发送 update_static_placeholders
  -> WebSocketServer 收到 placeholders
  -> PluginManager.updateDistributedStaticPlaceholders()
  -> 写入 staticPlaceholderValues
  -> 每个占位符记录 serverId
  -> messageProcessor 后续照常替换占位符
  -> 节点断开时清理该 serverId 的占位符
```

源码位置：

- `WebSocketServer.js:589`：处理 `update_static_placeholders`。
- `WebSocketServer.js:600`：调用 `updateDistributedStaticPlaceholders()`。
- `Plugin.js:1325`：更新分布式静态占位符。
- `Plugin.js:1347`：兼容 JSON 动态折叠对象。
- `Plugin.js:1362`：写入 `staticPlaceholderValues` 并附带 `serverId`。
- `Plugin.js:1375`：`clearDistributedStaticPlaceholders()`。
- `Plugin.js:1380`：按 `serverId` 清理远程占位符。
- `modules/messageProcessor.js:465`：静态占位符统一替换入口。

城市类比：外地分馆不只能办事，还能把“今日库存”“远程 GPU 状态”“远程监控报告”贴到主城公告栏。分馆下线后，主城会把它贴的公告撕掉。

### 26.7 跨节点文件物流：file:// 不是本地路径那么简单

VCP 分布式里最容易低估的是文件。工具参数里出现 `file://` 时，这个文件可能不在主服务器，而在某个远程节点上。

本地插件调用前，PluginManager 会预拉取异地文件：

```text
本地插件收到参数
  -> 参数里有 file://
  -> FileFetcherServer.resolveFileUrl(fileUrl, requestIp)
  -> 本地存在：原样返回
  -> 本地缓存存在：返回缓存 file://
  -> 都不存在：根据 requestIp 找来源分布式服务器
  -> executeDistributedTool(serverId, internal_request_file, { fileUrl })
  -> 远程返回 base64
  -> 主城写入 .file_cache
  -> 把参数替换为主城可读的缓存 file://
```

源码位置：

- `Plugin.js:752`：分布式插件跳过本地预拉取，直接把 `file://` 透传给远程端。
- `Plugin.js:759`：本地插件参数里的 `file://` 会被拦截。
- `Plugin.js:761`：调用 `FileFetcherServer.resolveFileUrl()`。
- `FileFetcherServer.js:43`：`fetchFile()`。
- `FileFetcherServer.js:109`：根据 `requestIp` 反查来源服务器。
- `FileFetcherServer.js:118`：调用远程内部工具 `internal_request_file`。
- `FileFetcherServer.js:127`：写入本地 `.file_cache`。
- `FileFetcherServer.js:154`：`resolveFileUrl()`。
- `FileFetcherServer.js:186`：缓存命中时直接返回缓存 URL。

这里的关键设计是：`internal_request_file` 是内务工具，不展示给模型，也不注册成普通工具。

源码位置：

- `WebSocketServer.js:564`：过滤 `internal_request_file`。

城市类比：你在主城要用一份外地文件，不能假装它就在本地。FileFetcher 像跨城物流员：先查本地仓库，没有就按发件 IP 找分馆，让分馆把文件打包成 base64 寄回来，主城落库缓存后再交给本地店铺。

### 26.8 DynamicTools 的分布式感知：工具地图会标记上下线

远程工具上线或下线后，DynamicTools 不是静态不变的。`PluginManager` 会发事件，`DynamicToolRegistry` 会同步工具目录，并保留远程工具的在线/离线状态。

流程：

```text
远程工具注册
  -> PluginManager.emit('tools_changed')
  -> DynamicToolRegistry.syncFromPluginManager()
  -> 工具出现在 {{VCPDynamicTools}} 可选范围

远程节点断开
  -> PluginManager.emit('distributed_tools_offline')
  -> DynamicToolRegistry.markDistributedOffline()
  -> 对应工具 online=false / available=false
  -> 再 emit tools_changed
  -> 工具导览牌更新
```

源码位置：

- `Plugin.js:1288`：远程注册后 `tools_changed`。
- `Plugin.js:1303`：远程下线前发 `distributed_tools_offline`。
- `Plugin.js:1319`：远程注销后 `tools_changed`。
- `modules/dynamicToolRegistry.js:337`：`markDistributedOffline()`。
- `modules/dynamicToolRegistry.js:365`：离线快照进入分类队列。
- `modules/dynamicToolRegistry.js:648`：抽取工具时区分 `local` / `distributed`。
- `modules/dynamicToolRegistry.js:1220`：绑定 `tools_changed` 和 `distributed_tools_offline` 事件。
- `modules/dynamicToolRegistry.js:1231`：分布式离线事件处理。

城市类比：城市导览牌不是印刷海报，而是电子地图。外地分馆上线，地图上出现云端店铺；分馆断线，地图会把它标成不可用，避免模型继续去敲一扇关着的门。

### 26.9 ChromeBridge 也是分布式思想的一部分

ChromeBridge 虽然不是 `DistributedServer`，但它走同一个 WebSocket 城际通信体系。Chrome 扩展作为 `ChromeObserver` 持续上报页面状态，控制端作为 `ChromeControl` 发命令，主服务器负责路由命令与结果。

流程：

```text
ChromeObserver 接入
  -> WebSocketServer 保存连接
  -> 优先交给 ChromeBridge.handleNewClient()
  -> Observer 上报 pageInfoUpdate / command_result

ChromeControl 发命令
  -> WebSocketServer 添加 sourceClientId
  -> 转发给 Observer
  -> Observer 执行后 command_result 回来
  -> WebSocketServer 按 sourceClientId 路由给控制端
```

源码位置：

- `WebSocketServer.js:163`：识别 `ChromeObserver`。
- `WebSocketServer.js:167`：识别 `ChromeControl`。
- `WebSocketServer.js:204`：优先接入 `ChromeBridge`。
- `WebSocketServer.js:275`：处理 ChromeObserver 心跳和命令结果。
- `WebSocketServer.js:362`：处理 ChromeControl 命令。
- `WebSocketServer.js:372`：记录等待页面信息的控制端。
- `Plugin/ChromeBridge/ChromeBridge.js:22`：ChromeBridge 初始化。

城市类比：Chrome 是一辆装着传感器和机械臂的外勤车。它一边回传街景，一边接受主城指令去点击、输入、查询 DOM 或执行 CDP 操作。

### 26.10 分布式造工具的设计要点

如果你要造适合自己的分布式工具，先按下面的问题设计：

```text
工具必须跑在主服务器吗？
  如果依赖 GPU、本地浏览器、特定文件盘、内网服务，可以放到分布式节点。

工具是否要展示给模型？
  普通工具写进 register_tools；内部工具如 internal_request_file 不应暴露。

工具名会不会和主城已有工具冲突？
  冲突会被主城跳过注册，需要提前命名。

远程工具是否会产出静态上下文？
  可以通过 update_static_placeholders 把状态、报告、远程资源说明贴进主城。

远程工具是否要处理文件？
  尽量使用 file://，并理解本地插件会预拉取，分布式插件会直接透传。

工具是否耗时？
  可以走远程异步回调 plugin_callback_forward，或者结合 archery。

工具是否敏感？
  即使是远程工具，也会进入主城 toolApprovalConfig 审批链。

工具是否希望被 DynamicTools 自动选中？
  manifest 的 displayName、description、invocationCommands 要写清楚。
```

一句话总结：

> VCP 的分布式不是“远程 RPC”，而是“外地分馆加入主城治理体系”。远程工具上线后，会被注册、被描述、被审批、被调度、被广播、被下线清理；远程文件也会通过 FileFetcher 进入主城物流缓存。

这也是 VCP 适合扩展的关键：你可以把不同机器、不同环境、不同权限、不同算力，统一纳入同一个 AI 城市。
