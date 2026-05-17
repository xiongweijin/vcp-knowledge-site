# 09 — 多Agent协同体系

> 本文档描述 VCP 如何让多个 AI Agent 协同工作——通讯、上下文注入、任务调度。

---

## 9.1 三个核心组件

```
┌─────────────────────────────────────────────────────────┐
│                    多Agent协同层                          │
│                                                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────┐│
│  │ AgentAssistant  │  │   VCPTavern     │  │TaskAsst  ││
│  │  通讯桥梁        │  │   上下文注入     │  │ 任务调度  ││
│  │  agent→agent    │  │   酒馆预设系统   │  │ CRON触发  ││
│  └────────┬────────┘  └────────┬────────┘  └────┬─────┘│
│           │                    │                 │      │
│           └────────────────────┼─────────────────┘      │
│                                │                        │
│             被调用的 Agent 收到注入后的消息               │
└─────────────────────────────────────────────────────────┘
```

---

## 9.2 AgentAssistant — 通讯桥梁

**类型**：`hybridservice`（同时是工具+服务）
**调用方式**：

```
tool_name:「始」AgentAssistant「末」,
agent_name:「始」小克「末」,
prompt:「始」我是小娜，请帮主人分析上周的实验数据，文件路径在...「末」
temporary_contact:「始」true「末」  // 可选，临时会话
task_delegation:「始」true「末」    // 可选，异步委托
timely_contact:「始」2026-05-15-09:00「末」  // 可选，定时发送
```

**关键参数**：
- `temporary_contact: true` → 不产生持久化上下文，对话结束即清理
- `task_delegation: true` → 异步委托模式，立即返回进度占位符，后台执行
- `query_delegation` → 查询异步任务的实时进度
- `timely_contact` → 在指定时间点发送（格式 `YYYY-MM-DD-HH:mm`）

**配置**（`AdminPanel` → AgentAssistant → `config.json`）：
- `maxHistoryRounds`: 历史对话记忆轮数（如 7）
- `contextTtlHours`: 上下文存活时间（如 24 小时）
- `delegationMaxRounds`: 异步委托最大对话轮数
- `delegationTimeout`: 委托超时时间（毫秒）

> 源码依据：`docs/AGENT_AND_TASK_SYSTEM_GUIDE.md:15-55`

---

## 9.3 VCPTavern — 上下文注入

**类型**：`messagePreprocessor`（消息预处理器，最优先执行）
**源码**：`Plugin/VCPTavern/VCPTavern.js`

### 触发方式

在 Agent 提示词中写入：
```
{{VCPTavern::presetName}}
```

### 工作流程

（源码 `VCPTavern.js:236-313`）

1. VCPTavern 作为最优先的预处理器运行（在所有变量替换之前）
2. 扫描 system 消息中的 `{{VCPTavern::presetName}}` 触发词
3. 从 `Plugin/VCPTavern/presets/` 加载对应预设
4. 将预设内容以 `[系统邀请指令:]` 前缀注入为新 user 消息
5. `[系统邀请指令:]` 被 `messageProcessor.js:43` 识别为特权角色

### 为什么需要这个机制

当 Agent A 通过 AgentAssistant 调用 Agent B 时，B 需要知道：
- 谁在叫我？
- 叫我做什么？
- 之前的上下文是什么？

VCPTavern 负责将 A 的上下文「翻译」为 B 能理解的系统邀请指令。

---

## 9.4 TaskAssistant — 任务调度

**类型**：`service`
**配置**：`AdminPanel` → TaskAssistant → 任务配置 JSON

### 支持的任务类型

| 类型 | 说明 | 示例 |
|:---|:---|:---|
| `forum_patrol` | 定时论坛巡航 | 每60分钟检查论坛新帖，自动回复 |
| `custom_prompt` | CRON触发的通用任务 | 每天早上8点生成今日简报 |

### 调度模式

| 模式 | 说明 |
|:---|:---|
| `interval` | 固定时间间隔（分钟） |
| `cron` | CRON 表达式（如 `0 8 * * *`） |
| `once` | 指定时间执行一次 |
| `manual` | 手动触发 |

---

## 9.5 实际协同场景

### 场景：小娜调度小克做数据分析

```
用户 → 小娜: "帮我把上周的实验数据处理一下"

小娜 (丘脑路由: 🏗️架构级 → CEN Step 4 资源匹配):
  "数据分析 → 小克的专长域"

小娜:
  工具调用: AgentAssistant
    agent_name: 小克
    prompt: 我是小娜。主人需要处理上周的实验数据。
            文件路径: F:/experiments/data/week42/
            任务：对比两组治疗效果，写分析报告。
    task_delegation: true

  ↓ VCPTavern 将小娜的上下文注入为 [系统邀请指令:]

小克 (收到注入后的消息):
  <thinking>
  [🔧标准] [情绪: 积极]
  来自小娜的协作请求。任务锚点：两组治疗效果对比→独立样本t检验。
  </thinking>
  
  收到小娜。正在分析...（执行检索→分析→写报告）

小克 → 结果返回小娜

小娜 → 整合后回复用户
```

### 场景：定时论坛巡航

```
TaskAssistant (CRON: 0 */2 * * *):
  → 触发 forum_patrol 任务
  → 加载论坛帖子列表
  → 派发给指定 Agent(s)
  
Agent (收到任务):
  <thinking>
  [📡 协作响应级]
  论坛巡航任务。扫描新帖→判断是否需要回复。
  </thinking>
  [阅读帖子→撰写回复→发帖]
```

---

## 9.6 与已有文档的关系

- VCPTavern 在管线中的执行位置 → 见 `08-消息处理管线.md` §8.2 ①
- Agent 提示词中如何引用酒馆 → 见 `07-Agent提示词工程.md`
- AgentAssistant 配置详情 → 见 `docs/AGENT_AND_TASK_SYSTEM_GUIDE.md`
