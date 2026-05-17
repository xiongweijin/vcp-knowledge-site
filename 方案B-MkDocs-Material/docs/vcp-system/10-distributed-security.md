# 10 — 分布式与安全

> 本文档覆盖 VCP 的跨节点执行能力和安全边界。

---

## 10.1 WebSocket 分布式架构

（源码 `WebSocketServer.js:19-28`）

VCP 的 WebSocket 服务管理 **6 种客户端类型**：

| 客户端类型 | 存储 Map | 用途 |
|:---|:---|:---|
| 普通客户端 | `clients` | VCPLog 等日志上报 |
| 分布式服务器 | `distributedServers` | **跨节点工具透明代理执行** |
| ChromeControl | `chromeControlClients` | 浏览器控制（自动化操作） |
| ChromeObserver | `chromeObserverClients` | 浏览器观察（只读监控） |
| 管理面板 | `adminPanelClients` | AdminPanel 实时状态推送 |
| 待处理工具请求 | `pendingToolRequests` | 跨节点异步回调追踪 |

### 工具调用的节点路由

（源码 `Plugin.js:870-872`）

```javascript
// 如果插件配置了 distributed 协议，转发到远程节点
if (plugin.pluginType === 'hybridservice' && plugin.communication?.protocol === 'direct') {
    resultFromPlugin = await this.webSocketServer.forwardCommandToChrome(command, args);
}
```

工具可能被透明路由到：
- 本地进程（`stdio` 协议）
- VCPChat Chrome 扩展（`direct` 协议 → ChromeControl）
- 远程分布式节点（WebSocket 转发）

---

## 10.2 ContextBridge — 插件间向量共享

（源码 `docs/CONTEXT_BRIDGE.md`）

ContextBridge 是 RAGDiaryPlugin 暴露给其他插件的**只读查询接口**，允许任意插件访问：
- 会话历史的衰减聚合向量
- 语义分段后的主题向量
- EPA 指标计算（逻辑深度 L、语义宽度 S）
- 带缓存的向量化工具
- 文本净化器和向量数学工具

**接入方式**：
1. 插件 manifest 中声明 `"requiresContextBridge": true`
2. 在 `initialize(config, dependencies)` 中接收 `dependencies.contextBridge`

**设计原则**：只读、懒计算、零拷贝、安全（`Object.freeze()` 冻结）

---

## 10.3 鉴权体系

### API 密钥架构

（来源 `docs/CONFIGURATION.md:107-122`）

| 密钥 | 作用域 | 风险等级 |
|:---|:---|:---|
| `Key` | 聊天 API 访问密钥 | 🔴 高 |
| `Image_Key` | 图片服务访问密钥 | 🔴 高 |
| `File_Key` | 文件服务访问密钥 | 🔴 高 |
| `VCP_Key` | WebSocket 鉴权密钥 | 🔴 高 |

**安全建议**：不同服务使用不同密钥，避免单点泄露影响全局。所有 Key 至少 16 位强随机字符串。

### IP 黑名单

（源码 `server.js:122-134`）

- 15 分钟内错误凭据尝试 ≥ 5 次 → 封禁 30 分钟
- 15 分钟内无凭据访问 ≥ 100 次 → 封禁 15 分钟（防 DDoS 探测）
- 黑名单持久化到 `ip_blacklist.json`

### 管理面板鉴权

`AdminUsername` / `AdminPassword` —— 必须修改默认值。密码应包含大小写字母、数字、特殊字符，长度 ≥ 12 位。

---

## 10.4 优雅关闭

（源码 `server.js:141-166`）

VCP 服务器支持优雅关闭（graceful shutdown）——收到 SIGTERM/SIGINT 信号后：
1. 进入 `DRAINING` 状态，拒绝新请求
2. 等待活跃请求完成
3. 超时后强制退出

生命周期状态枚举：
```javascript
const SERVER_LIFECYCLE = {
    RUNNING: 'RUNNING',
    DRAINING: 'DRAINING',
    SHUTTING_DOWN: 'SHUTTING_DOWN',
    EXITING: 'EXITING'
};
```

---

## 10.5 安全注意事项汇总

| 关注点 | 措施 |
|:---|:---|
| API 密钥泄露 | 不提交 `config.env` 到 Git，使用强随机密钥 |
| 插件 Shell 执行 | 不新增 `spawn(..., shell: true)` 类路径，除非有严格输入约束 |
| 工具调用验证码 | `VCPToolCode: true` 启用二次确认 |
| 文件路径安全 | FileOperator 限定工作目录白名单 |
| Docker 根用户 | 已知权衡，已文档化风险 |

> 来源：`AGENTS.md:91-98`、`docs/CONFIGURATION.md`

---

## 交叉引用

- 系统启动流程 → 见 `01-系统全景.md`
- 折叠协议中的向量计算 → 见 `03-上下文折叠体系.md`
- 消息处理管线 → 见 `08-消息处理管线.md`
