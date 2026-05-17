# VCP 源码导航与运维手册 V1.2（Agent版）

生成日期：2026-05-17  
定位：给 Agent / 维护者读的源码导航、排障和扩展手册  
来源：基于 `14-VCP系统深度导读-20260516.md`、VCPToolBox 源码与 `docs/` 文档重组  

## 0. Agent 阅读原则

进入这个仓库后，先记住四件事：

1. 这是扁平根目录项目，不要假设存在 `src/` 分层。
2. 插件生态很大，先按职责定位文件，不要全仓漫游。
3. `dailynote/`、`image/`、插件 `state/`、缓存、数据库多是运行数据，默认不要当源码改。
4. 高风险面集中在工具执行、Admin API、WebSocket 分布式、文件回源、shell 类插件。

推荐优先用：

```text
rg -n "关键字" 文件或目录
rg --files
git status --short
```

不要先大范围重构。VCP 的很多行为由 `config.env`、插件 `config.env`、manifest、运行状态共同决定。

## 1. 90 秒源码地图

| 职责 | 入口文件 |
|---|---|
| HTTP/API 入口、鉴权、启动编排 | `server.js` |
| 聊天主流程 | `modules/chatCompletionHandler.js` |
| 变量、Agent、ToolBox、静态占位符注入 | `modules/messageProcessor.js` |
| 插件发现、生命周期、工具执行 | `Plugin.js` |
| 工具块解析与执行回路 | `modules/vcpLoop/toolCallParser.js`, `modules/vcpLoop/toolExecutor.js` |
| RAG/TagMemo/向量库总控 | `KnowledgeBaseManager.js`, `Plugin/RAGDiaryPlugin/` |
| DynamicTools 动态工具说明 | `modules/dynamicToolRegistry.js` |
| 分布式节点、ChromeBridge WebSocket | `WebSocketServer.js` |
| 跨节点文件回源 | `FileFetcherServer.js` |
| 管理面板后端 | `routes/adminPanelRoutes.js`, `routes/admin/*.js` |
| 特殊模型白名单透传 | `routes/specialModelRouter.js` |
| Rust 向量引擎 | `rust-vexus-lite/` |

## 2. 启动序列 Runbook

主入口是 `server.js`。排查启动问题先看这里。

关键节点：

| 阶段 | 源码定位 | 说明 |
|---|---|---|
| 加载 `config.env` | `server.js:4` | 根配置入口 |
| 解析 Agent 目录 | `server.js:30` | `AGENT_DIR_PATH` 或默认 `Agent/` |
| 解析 TVStxt 目录 | `server.js:74` | `TVSTXT_DIR_PATH` 或默认 `TVStxt/` |
| API Key | `server.js:606` | 普通 API 鉴权 |
| Admin Auth | `server.js:613` | AdminPanel/Admin API 鉴权 |
| special router | `server.js:602` | 早于标准聊天接口挂载 |
| 标准聊天接口 | `server.js:1139` | `/v1/chat/completions` |
| Admin 路由挂载 | `server.js:1343`, `server.js:1449` | `routes/adminPanelRoutes.js` |
| 插件服务初始化 | `server.js:1447` | service 插件挂载 |
| Agent 初始化 | `server.js:1545` | `agentManager.initialize()` |
| ModelRedirect | `server.js:1542` | 加载 `ModelRedirect.json` |
| WebSocket 注入 PluginManager | `server.js:1604` | 分布式与审批依赖 |

排查命令：

```text
rg -n "app.post\\('/v1/chat/completions'|initializeServices|setPluginManager|ModelRedirect|adminAuth" server.js
```

常见问题：

| 症状 | 优先检查 |
|---|---|
| AdminPanel 进不去 | `AdminUsername` / `AdminPassword`，`server.js:613` 鉴权逻辑 |
| API 401 | `API_Key`，Bearer Header |
| 特定模型不走 VCP 主链路 | `routes/specialModelRouter.js` 是否白名单接管 |
| WebSocket / 分布式无效 | `VCP_Key`、`server.js:1600`、`WebSocketServer.js` 初始化 |

## 3. 聊天请求链路 Runbook

标准聊天流：

```text
POST /v1/chat/completions
  -> modules/chatCompletionHandler.js
  -> messageProcessor.replaceAgentVariables()
  -> messagePreprocessor 插件链
  -> 上游 LLM API
  -> vcpLoop 解析工具块
  -> PluginManager.processToolCall()
  -> 工具结果回灌模型
```

关键源码：

| 节点 | 位置 |
|---|---|
| 聊天处理类 | `modules/chatCompletionHandler.js:312` |
| 主处理方法 | `modules/chatCompletionHandler.js:324` |
| ShowVCP 判断 | `modules/chatCompletionHandler.js:353` |
| 模型重定向 | `modules/chatCompletionHandler.js:453` |
| 变量处理 | `modules/chatCompletionHandler.js:565` |
| 请求上游 API | `modules/chatCompletionHandler.js:676` |
| stream 工具回路 | `modules/handlers/streamHandler.js` |
| non-stream 工具回路 | `modules/handlers/nonStreamHandler.js` |

排查重点：

| 症状 | 优先看 |
|---|---|
| system prompt 展开不对 | `modules/messageProcessor.js` |
| 模型名被换了 | `modelRedirectHandler.js`, `ModelRedirect.json`, `chatCompletionHandler.js:453` |
| 工具结果没展示 | `ShowVCP`、`ink: mark_history`、stream/non-stream handler |
| 请求根本没进主链路 | `routes/specialModelRouter.js` |

## 4. 变量与提示词注入 Runbook

变量处理主入口：

- `modules/messageProcessor.js:37`：`resolveAllVariables()`。
- `modules/messageProcessor.js:41`：Agent/ToolBox 特权角色限制。
- `modules/messageProcessor.js:60`：一个上下文只允许展开一个 Agent。
- `modules/messageProcessor.js:98`：Agent 后处理 ToolBox。
- `modules/messageProcessor.js:372`：`replaceOtherVariables()`。
- `modules/messageProcessor.js:423`：处理 `Tar` / `Var`。
- `modules/messageProcessor.js:467`：静态插件占位符注入。
- `modules/messageProcessor.js:490`：`{{VCPDynamicTools}}`。
- `modules/messageProcessor.js:553`：异步结果占位符。
- `modules/messageProcessor.js:590`：优先变量。

Agent 管理：

- `modules/agentManager.js:9`：类定义。
- `modules/agentManager.js:25`：初始化。
- `modules/agentManager.js:66`：watcher。
- `modules/agentManager.js:272`：读取 Agent prompt。
- `modules/agentManager.js:322`：判断别名是否是 Agent。

SarPrompt：

- `modules/sarPromptManager.js:9`：管理器。
- `server.js:1561`：初始化。

ToolBox：

- `modules/toolboxManager.js`：TVStxt/ToolBox 映射。
- `routes/admin/toolbox.js`：管理面板读写。

排查表：

| 症状 | 优先检查 |
|---|---|
| `{{agent:xxx}}` 没展开 | `Agent/agent_map.json`、`agentManager.isAgent()`、角色是否特权 |
| 多个 Agent 只展开一个 | 这是设计，见 `messageProcessor.js:60` |
| `{{VarX}}` 没替换 | `config.env` 或 TVStxt 文件路径 |
| `{{VCPDynamicTools}}` 为空 | DynamicToolRegistry 状态、插件是否加载、配置是否禁用 |
| 异步任务占位符不更新 | `VCPAsyncResults/` 与 `messageProcessor.js:553` |

## 5. 插件系统 Runbook

插件总控：

- `Plugin.js:19`：`PluginManager`。
- `Plugin.js:35`：初始化 `ToolApprovalManager`。
- `Plugin.js:431`：插件发现入口。
- `Plugin.js:488`：读取插件 `config.env`。
- `Plugin.js:492`：读取 manifest。
- `Plugin.js:537`：messagePreprocessor 顺序。
- `Plugin.js:551`：检查 VectorDBManager。
- `Plugin.js:581`：为 `requiresContextBridge` 插件注入依赖。
- `Plugin.js:603`：LightMemo 特殊依赖注入。
- `Plugin.js:621`：插件发现完成。
- `Plugin.js:630`：构建 VCP 工具说明。
- `Plugin.js:709`：工具不存在时报错。
- `Plugin.js:791`：工具审批。
- `Plugin.js:857`：分布式工具前置检查。
- `Plugin.js:874`：hybrid service direct 调用。
- `Plugin.js:895`：本地 stdio 工具执行。
- `Plugin.js:959`：`executePlugin()`。
- `Plugin.js:1206`：service 插件初始化。
- `Plugin.js:1265`：注册分布式工具。
- `Plugin.js:1398`：热加载。
- `Plugin.js:1417`：manifest watcher。

插件类型判断：

| 类型 | 代码路径 |
|---|---|
| `static` | `executeStaticPlugin()`、`initializeStaticPlugins()` |
| `messagePreprocessor` | `executeMessagePreprocessor()` |
| `synchronous` | `executePlugin()` |
| `asynchronous` | `executePlugin()` + 初始 JSON + 后台回调 |
| `service` | `initializeServices()` |
| `hybridservice` | service 初始化 + `processToolCall()` |
| distributed | `registerDistributedTools()` + `executeDistributedTool()` |

排查表：

| 症状 | 优先检查 |
|---|---|
| 插件没加载 | manifest 文件是否 `.block`、JSON 是否有效、`Plugin.js:431` 日志 |
| 工具说明没出现 | `capabilities.invocationCommands`、`Plugin.js:630`、DynamicTools |
| service 路由 404 | `initializeServices()` 是否执行、`routes/adminPanelRoutes.js` 挂载顺序 |
| 插件调用超时 | manifest `communication.timeout`，`Plugin.js:1044` |
| Python 插件无响应 | entryPoint、工作目录、stdout 是否输出合法 JSON |
| 热更新没生效 | resident 插件、watcher 是否跳过，`Plugin.js:1417` |

## 6. 工具协议与执行回路 Runbook

解析器：

- `modules/vcpLoop/toolCallParser.js:4`：工具块标记。
- `modules/vcpLoop/toolCallParser.js:74`：工具块解析结果结构。
- `modules/vcpLoop/toolCallParser.js:94`：`archery`。
- `modules/vcpLoop/toolCallParser.js:97`：`ink`。
- `modules/vcpLoop/toolCallParser.js:98`：`river`。
- `modules/vcpLoop/toolCallParser.js:100`：`vref`。
- `modules/vcpLoop/toolCallParser.js:166`：中文 `「始」「末」`。
- `modules/vcpLoop/toolCallParser.js:223`：normal/archery 分流。

执行器：

- `modules/vcpLoop/toolExecutor.js:48`：vref 不额外触发 embedding 的约束说明。
- `modules/vcpLoop/toolExecutor.js:118`：解析 vref。
- `modules/vcpLoop/toolExecutor.js:188`：执行入口。
- `modules/vcpLoop/toolExecutor.js:190`：river 注入。
- `modules/vcpLoop/toolExecutor.js:197`：`river: full`。
- `modules/vcpLoop/toolExecutor.js:199`：`river: text`。
- `modules/vcpLoop/toolExecutor.js:203`：`river: last:N`。
- `modules/vcpLoop/toolExecutor.js:209`：`river: semantic:N`。
- `modules/vcpLoop/toolExecutor.js:302`：vref 文件引用注入。

排查表：

| 症状 | 优先检查 |
|---|---|
| 工具块没执行 | 标记是否完整、字段是否用 `「始」「末」`、是否被包在不解析区域 |
| 参数解析错 | 是否字段内需要 ESCAPE 标记 |
| 异步工具没等结果 | 是否使用了 `archery: no_reply` |
| 工具需要上下文但拿不到 | 是否声明并使用 `river` |
| 工具需要相关文件但为空 | `vref` 依赖上下文向量缓存和 RAGDiaryPlugin |

## 7. RAG / TagMemo / 记忆系统 Runbook

总入口：

- `KnowledgeBaseManager.js:26`：知识库管理器。
- `KnowledgeBaseManager.js:144`：初始化 TagMemoEngine。
- `KnowledgeBaseManager.js:417`：搜索选项结构。
- `KnowledgeBaseManager.js:517`：`TagMemo+` geodesic rerank。
- `KnowledgeBaseManager.js:723`：对外代理 `geodesicRerank()`。
- `TagMemoEngine.js`：标签脉冲、能量场、测地线重排。

RAGDiaryPlugin 关键点：

- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:49`：ContextVectorManager。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:106`：AIMemoHandler。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:168`：FoldingStore 初始化。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1043`：RoleValve。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1108`：同步上下文到 FoldingStore。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1111`：Base64Memo 附件收集。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1496`：聚合模式 RoleValve。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:1868`：AIMemoHandler 初始化检查。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2365`：TimeDecay。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2380`：TagMemo+。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2392`：Expand。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2395`：Associate。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2567`：后处理顺序。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:2686`：Base64Memo。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:3279`：TimeDecay 实现。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4087`：getContextBridge。

子模块：

| 模块 | 位置 |
|---|---|
| AIMemo | `Plugin/RAGDiaryPlugin/AIMemoHandler.js:16` |
| ContextVectorManager | `Plugin/RAGDiaryPlugin/ContextVectorManager.js:12` |
| FoldingStore | `Plugin/RAGDiaryPlugin/FoldingStore.js:10` |
| MetaThinking | `Plugin/RAGDiaryPlugin/MetaThinkingManager.js` |

排查表：

| 症状 | 优先检查 |
|---|---|
| RAG 无结果 | rag_tags、索引、embedding 配置、VectorDB 状态 |
| `::TagMemo+` 效果像普通 RAG | `TagMemoEngine.lastEnergyField` 是否存在，`KnowledgeBaseManager.js:517` 是否触发 |
| `::AIMemo` 无效 | system 是否有 `[[AIMemo=True]]`，AIMemo 配置是否完整 |
| `::TimeDecay` 不生效 | 修饰符格式，`RAGDiaryPlugin.js:2365` |
| 附件没进模型 | `::Base64Memo`、附件 URL、`RAGDiaryPlugin.js:2686` |
| ContextFolding 不工作 | RAGDiaryPlugin 是否成功暴露 ContextBridge |

## 8. ContextBridge / Folding Runbook

ContextBridge 是 RAGDiaryPlugin 对外暴露的上下文接口。依赖注入链路：

```text
RAGDiaryPlugin.getContextBridge()
  -> PluginManager 检查 manifest.requiresContextBridge
  -> dependencies.contextBridge
  -> ContextFoldingV2 / LightMemo / 其他插件
```

关键源码：

- `Plugin.js:581`：注入 ContextBridge。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4087`：生成 Bridge。
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js:4250`：Bridge 内 FoldingStore getter。
- `Plugin/RAGDiaryPlugin/FoldingStore.js:84`：表结构附近。
- `Plugin/ContextFoldingV2/plugin-manifest.json`：`requiresContextBridge`。
- `Plugin/ContextFoldingV2/ContextFoldingV2.js:74`：FoldingStore 可用性检查。

排查表：

| 症状 | 优先检查 |
|---|---|
| 插件拿不到 Bridge | manifest 是否声明 `requiresContextBridge: true` |
| FoldingStore 不可用 | SQLite 初始化、路径权限、RAGDiaryPlugin 初始化日志 |
| 折叠没有触发 | system 中是否有激活占位符，如 `[[ContextFoldingV2]]` |
| 折叠太激进 | EPA/LRS 参数、ContextFolding 配置 |

## 9. DynamicTools Runbook

DynamicTools 负责把工具说明从“静态全量注入”变成“按任务动态注入”。

关键源码：

- `modules/dynamicToolRegistry.js:15`：默认占位符 `{{VCPDynamicTools}}`。
- `modules/dynamicToolRegistry.js:212`：类定义。
- `modules/dynamicToolRegistry.js:280`：从 PluginManager 同步。
- `modules/dynamicToolRegistry.js:337`：分布式工具离线标记。
- `modules/dynamicToolRegistry.js:450`：`buildInjection()`。
- `modules/dynamicToolRegistry.js:588`：手动重建。
- `modules/dynamicToolRegistry.js:975`：分类强制展开指令。
- `modules/dynamicToolRegistry.js:976`：单工具强制展开指令。
- `modules/dynamicToolRegistry.js:1216`：绑定 PluginManager 事件。
- `modules/dynamicToolRegistry.js:1231`：分布式离线事件。
- `routes/admin/dynamicTools.js:59`：Admin 状态接口。

触发链路：

```text
system 中出现 {{VCPDynamicTools}}
  -> messageProcessor.replaceOtherVariables()
  -> dynamicToolRegistry.buildInjection()
  -> 按规则/分类/模型/向量筛选工具说明
  -> 注入 prompt
```

排查表：

| 症状 | 优先检查 |
|---|---|
| 动态工具为空 | 插件是否加载、DynamicTools 是否启用、`syncFromPluginManager()` |
| 某个工具永远不出现 | manualOverrides、分类、工具描述质量 |
| 分布式工具下线后还显示 | `distributed_tools_offline` 事件、`markDistributedOffline()` |
| 强制展开失败 | 语法是否为 `[[VCPDynamicTools:tool=工具名]]` |

## 10. 分布式 / WebSocket Runbook

VCP 分布式是星型拓扑：主服务器调度，远程节点注册工具并执行。

关键源码：

- `WebSocketServer.js:21`：`distributedServers`。
- `WebSocketServer.js:22`：`chromeControlClients`。
- `WebSocketServer.js:23`：`chromeObserverClients`。
- `WebSocketServer.js:134`：分布式路径。
- `WebSocketServer.js:163`：ChromeObserver。
- `WebSocketServer.js:167`：ChromeControl。
- `WebSocketServer.js:197`：登记分布式节点。
- `WebSocketServer.js:204`：ChromeBridge 优先接入。
- `WebSocketServer.js:560`：`register_tools`。
- `WebSocketServer.js:589`：`update_static_placeholders`。
- `WebSocketServer.js:603`：`tool_result`。
- `WebSocketServer.js:615`：`plugin_callback_forward`。
- `WebSocketServer.js:623`：`executeDistributedTool()`。
- `WebSocketServer.js:696`：导出接口。
- `Plugin.js:1265`：注册分布式工具。
- `Plugin.js:1292`：分布式下线注销。
- `Plugin.js:1325`：更新分布式静态占位符。
- `Plugin.js:1376`：清理分布式静态占位符。

远程执行链路：

```text
分布式节点连接 /vcp-distributed-server/VCP_Key=...
  -> 发送 register_tools
  -> PluginManager.registerDistributedTools()
  -> DynamicTools 收到 tools_changed
  -> 模型调用工具
  -> PluginManager.processToolCall()
  -> WebSocketServer.executeDistributedTool()
  -> 远程节点返回 tool_result
```

文件回源：

- `Plugin.js:752`：分布式插件跳过本地 file 预拉取。
- `Plugin.js:761`：本地工具参数里的 file URL 走 `FileFetcherServer.resolveFileUrl()`。
- `FileFetcherServer.js:43`：`fetchFile()`。
- `FileFetcherServer.js:118`：调用远程 `internal_request_file`。
- `FileFetcherServer.js:154`：`resolveFileUrl()`。

排查表：

| 症状 | 优先检查 |
|---|---|
| 节点连不上 | `VCP_Key`、WebSocket 路径、防火墙 |
| 工具注册了但看不到 | 工具名冲突、`register_tools` 被过滤、DynamicTools 未同步 |
| 远程工具调用超时 | `pendingToolRequests`、远程节点日志、timeout |
| 远程异步结果没回主城 | `plugin_callback_forward`、`VCPAsyncResults/` |
| 远程 file:// 读取失败 | `requestIp` 映射、`internal_request_file`、`.file_cache/` |
| ChromeBridge 无响应 | `ChromeObserver` / `ChromeControl` 连接类型和 sourceClientId 路由 |

## 11. Admin / 治理 / 可观测 Runbook

鉴权：

- `server.js:613`：Admin Auth。
- `server.js:789`：挂载 Admin 鉴权。
- `server.js:806`：普通 API 鉴权。

Admin 路由：

- `routes/adminPanelRoutes.js:34`：Admin Router。
- `routes/adminPanelRoutes.js:73`：system 路由。
- `routes/adminPanelRoutes.js:75`：config 路由。
- `routes/adminPanelRoutes.js:76`：plugins 路由。
- `routes/adminPanelRoutes.js:88`：dynamicTools 路由。
- `routes/admin/config.js:26`：读取工具审批配置。
- `routes/admin/config.js:57`：读取主配置。
- `routes/admin/plugins.js:15`：插件列表。
- `routes/admin/plugins.js:93`：插件启停。
- `routes/admin/plugins.js:375`：preprocessor 顺序。
- `routes/admin/rag.js:9`：RAG tags。
- `routes/admin/rag.js:39`：RAG params。
- `routes/admin/agents.js:26`：Agent map。
- `routes/admin/toolbox.js:107`：ToolBox map。

审批：

- `modules/toolApprovalManager.js:5`：类定义。
- `modules/toolApprovalManager.js:114`：审批规则决策。
- `Plugin.js:791`：工具执行前检查。
- `Plugin.js:819`：构造审批请求。
- `Plugin.js:829`：广播到 `VCPLog`。
- `Plugin.js:1187`：处理审批响应。

可观测点：

| 能力 | 位置 |
|---|---|
| ShowVCP | `server.js:370`, stream/non-stream handlers |
| VCPLog 推送 | `Plugin.js:1239`, `WebSocketServer.js` |
| Server log | `routes/admin/logs.js` |
| DynamicTools state | `routes/admin/dynamicTools.js` |
| VectorDB status | `routes/admin/rag.js:95` |

排查表：

| 症状 | 优先检查 |
|---|---|
| 管理端接口 401/503 | Admin 账号密码、basic auth cookie、IP 阻断 |
| 审批请求没弹出 | WebSocketServer 是否注入 PluginManager，VCPLog 是否在线 |
| 插件启停后没变化 | manifest `.block` 状态、hot reload 日志 |
| 配置改了没生效 | 该配置是否支持热加载，是否需要重启 |

## 12. 特殊模型与外部生态 Runbook

特殊模型：

- `routes/specialModelRouter.js:41`：middleware 判断是否接管。
- `routes/specialModelRouter.js:68`：chat completions 透传。
- `routes/specialModelRouter.js:121`：embeddings 透传。

ModelRedirect：

- `server.js:399`：初始化 handler。
- `server.js:1542`：加载 `ModelRedirect.json`。
- `modules/chatCompletionHandler.js:453`：客户端请求模型映射到后端模型。

MCPO / MCP：

- `Plugin/MCPO/plugin-manifest.json.block`：当前禁用态 manifest。
- `Plugin/MCPO/mcpo_plugin.py:23`：MCPO 插件类。
- `Plugin/MCPO/mcpo_plugin.py:154`：启动 MCPO server。
- `Plugin/MCPO/mcpo_plugin.py:306`：向 MCPO server 发 HTTP 请求。
- `Plugin/MCPOMonitor/plugin-manifest.json.block`：监控插件禁用态。
- `README.md:360`：MCP 兼容端口说明。

排查表：

| 症状 | 优先检查 |
|---|---|
| 特定模型不经过工具链 | 是否被 special router 白名单接管 |
| 模型名和请求不同 | `ModelRedirect.json` |
| MCPO 不可用 | 插件是否 `.block`，mcpo server 是否安装/启动，端口和 API Key |

## 13. 状态、配置和风险边界

配置优先级通常涉及：

1. 根 `config.env`。
2. 插件目录 `Plugin/*/config.env`。
3. manifest 默认值。
4. AdminPanel 写入的 JSON 配置。
5. 运行期缓存和数据库。

不要随意改：

| 路径 | 原因 |
|---|---|
| `config.env` | 可能含真实密钥 |
| `Plugin/UserAuth/code.bin` | 认证码状态 |
| `VCPAsyncResults/` | 异步任务结果 |
| `.file_cache/` | 跨节点文件缓存 |
| `dailynote/` | 用户知识/日记内容 |
| `image/` | 运行媒体资源 |
| `Plugin/*/state/` | 插件运行状态 |
| `Plugin/RAGDiaryPlugin/*.db` | RAG/折叠数据库 |

新增工具时必须检查：

| 检查项 | 要点 |
|---|---|
| manifest | name、displayName、pluginType、communication、capabilities |
| 描述 | 工具说明要让 DynamicTools 可分类、可召回 |
| 参数 | 不要让模型猜字段名 |
| 超时 | sync 短、async 长，明确 manifest timeout |
| 输出 | stdout 必须是 VCP 预期 JSON |
| 安全 | 高风险工具接入 ToolApproval |
| 文件 | 支持 `file://` 时考虑 FileFetcher 和分布式 |
| 上下文 | 需要对话就用 `river`，需要文件引用就用 `vref` |
| 分布式 | 远程环境依赖明确，工具名避免冲突 |

## 14. 常见故障总表

| 故障 | 第一入口 | 第二入口 |
|---|---|---|
| API 请求失败 | `server.js` | `modules/chatCompletionHandler.js` |
| 模型没按预期路由 | `routes/specialModelRouter.js` | `ModelRedirect.json` |
| Agent 没展开 | `modules/messageProcessor.js` | `modules/agentManager.js` |
| ToolBox 没展开 | `modules/messageProcessor.js` | `modules/toolboxManager.js` |
| DynamicTools 为空 | `modules/dynamicToolRegistry.js` | `Plugin.js` |
| 插件没加载 | `Plugin.js` | `Plugin/*/plugin-manifest.json` |
| 工具块不执行 | `modules/vcpLoop/toolCallParser.js` | stream/non-stream handlers |
| 工具执行失败 | `Plugin.js:709` 后 | 对应 `Plugin/<name>/` |
| 审批卡住 | `modules/toolApprovalManager.js` | `Plugin.js:791`, WebSocketServer |
| RAG 为空 | `Plugin/RAGDiaryPlugin/` | `KnowledgeBaseManager.js` |
| TagMemo+ 不明显 | `TagMemoEngine.js` | `KnowledgeBaseManager.js:517` |
| ContextFolding 不生效 | `Plugin/ContextFoldingV2/` | `RAGDiaryPlugin.getContextBridge()` |
| 分布式掉线 | `WebSocketServer.js` | `Plugin.js:1292`, `dynamicToolRegistry.js:337` |
| 远程文件不可用 | `FileFetcherServer.js` | `Plugin.js:752` |
| ChromeBridge 不响应 | `WebSocketServer.js` | `Plugin/ChromeBridge/` |
| Admin 配置无效 | `routes/admin/*.js` | 是否需要重启 |
| 异步结果不更新 | `VCPAsyncResults/` | `modules/messageProcessor.js:553` |

## 15. 扩展新能力的最小流程

### 15.1 本地同步工具

1. 新建 `Plugin/YourTool/`。
2. 写 `plugin-manifest.json`，类型设为 `synchronous`。
3. 写脚本，从 stdin 读 JSON，向 stdout 输出 JSON。
4. 在 manifest 里写清楚 `invocationCommands`。
5. 重启或触发插件热加载。
6. 用 `[[VCPDynamicTools:tool=YourTool]]` 强制展开测试。

### 15.2 长任务工具

1. 类型设为 `asynchronous`。
2. 初始响应要快，后台任务稍后回调。
3. 确认 `CALLBACK_BASE_URL`。
4. 检查 `VCPAsyncResults/` 和 WebSocket 推送。
5. 需要展示时配合 `ink` 或 ShowVCP。

### 15.3 service / hybridservice

1. manifest 类型设为 `service` 或 `hybridservice`。
2. 模块导出路由注册或初始化函数。
3. 需要 Admin 管理时挂到 `adminApiRouter`。
4. hybridservice 同时实现 `processToolCall()`。
5. 注意服务插件热加载和 shutdown。

### 15.4 分布式工具

1. 远程节点连接 `/vcp-distributed-server/VCP_Key=...`。
2. 发送 `register_tools`。
3. 主服务器注册成 `isDistributed` 工具。
4. 工具调用走 `executeDistributedTool()`。
5. 文件使用 `file://`，必要时远程实现 `internal_request_file`。
6. 下线时确认 `distributed_tools_offline` 清理 DynamicTools。

## 16. Agent 维护时的安全提示

做代码变更时：

- 先读 `AGENTS.md`、相关子目录 `AGENTS.md`。
- 先 `git status --short`，识别用户已有改动。
- 只改与任务直接相关的文件。
- 不碰真实密钥和运行数据。
- 不新增不受控 shell 执行路径。
- 插件 manifest 字段不要随意改名。
- 修改工具协议时同步检查 parser、executor、README、插件示例。
- 修改 RAG 修饰符时同步检查 RAGDiaryPlugin、KnowledgeBaseManager、TagMemoEngine、Admin RAG 配置。
- 修改分布式时同步检查 WebSocketServer、PluginManager、DynamicToolRegistry、FileFetcherServer。

## 17. 最短排障路线

如果不知道从哪下手，按这个顺序：

```text
1. 这是入口问题吗？
   -> server.js / specialModelRouter / auth

2. 这是提示词展开问题吗？
   -> messageProcessor / agentManager / toolboxManager

3. 这是工具可见性问题吗？
   -> DynamicToolRegistry / PluginManager descriptions

4. 这是工具执行问题吗？
   -> toolCallParser / toolExecutor / PluginManager / 具体插件

5. 这是记忆召回问题吗？
   -> RAGDiaryPlugin / KnowledgeBaseManager / TagMemoEngine

6. 这是上下文折叠问题吗？
   -> ContextBridge / FoldingStore / ContextFoldingV2

7. 这是分布式问题吗？
   -> WebSocketServer / PluginManager distributed / FileFetcherServer

8. 这是治理/审批/可见性问题吗？
   -> ToolApprovalManager / ShowVCP / VCPLog / Admin routes
```

一句话给 Agent：

> VCP 的维护关键不是记住所有插件，而是先判断问题落在哪条链路：入口、变量、工具、记忆、上下文、分布式、治理。

