# 02 — 变量与占位符体系

> 本系列文档每篇自洽，可独立阅读。末尾标注交叉引用指向关联模块。

---

## 2.1 概述

VCP 的提示词不是静态的字符串。每个 `{{}}` 包裹的占位符在消息发送给 LLM **之前**被系统替换为实际内容。这套变量替换管线是 VCP 的「血脉系统」——Agent 提示词、工具箱、系统信息、用户身份、时间日期全部通过占位符动态注入。

核心处理文件：`modules/messageProcessor.js`，入口函数 `resolveAllVariables()`（源码行号：36-148）。

---

## 2.2 占位符的四种来源

VCP 的 `{{}}` 占位符根据前缀/来源分为四类：

### 第一类：Agent 占位符

**格式**：`{{AgentName}}` 或 `{{agent:AgentName}}`

**来源**：`Agent/` 目录下的 `.txt` 文件，通过 `agent_map.json` 映射。

**解析流程**（源码 `messageProcessor.js:55-94`）：
1. 正则 `/{{([a-zA-Z0-9_:...]+)}}/g` 匹配所有占位符
2. 对每个匹配的别名，调用 `agentManager.isAgent(alias)` 判断是否为 Agent
3. 如果是，调用 `agentManager.getAgentPrompt(alias)` 读取 Agent 文件内容
4. 对读到的内容**递归调用** `resolveAllVariables()`——Agent 文件中可以引用其他占位符
5. 替换回原文本

**安全保护（灵魂级）**（源码行号：59-73）：
- Agent 占位符**只在特权角色**中展开：`role === 'system'` 或 VCPTavern 注入的 `[系统提示:]` / `[系统邀请指令:]` 开头的 user 消息
- **整个上下文只允许展开一个 Agent**：如果已有 Agent 被展开，后续所有 Agent 占位符静默删除（替换为空串）
- 防止用户通过 `{{agent:XXX}}` 注入来读取其他 Agent 的提示词

> 源码依据：`messageProcessor.js:40-43`（特权角色判断）、`messageProcessor.js:59-73`（Agent 去重保护）

### 第二类：Toolbox 占位符

**格式**：`{{VCPXxxToolBox}}` 或 `{{toolbox:VCPXxxToolBox}}`

**来源**：`TVStxt/` 目录下的 `.txt` 文件，通过 `toolbox_map.json` 映射。

**解析流程**（源码 `messageProcessor.js:97-139`）：
1. 对每个匹配的别名，调用 `toolboxManager.isToolbox(alias)` 判断
2. 如果是 toolbox，调用 `toolboxManager.getFoldObject(alias)` → 读取文件并解析 `[===vcp_fold===]` 标记
3. 调用 `resolveDynamicFoldProtocol()` 用向量相似度决定展开哪些 block
4. 替换回原文本

**去重保护**（源码行号：101-109）：每种 toolbox 在整个上下文中只展开一次，重复出现时静默移除。

> 源码依据：`messageProcessor.js:97-139`；折叠机制详见 `03-上下文折叠体系.md`

### 第三类：环境变量占位符

**格式**：`{{Var*}}` 和 `{{Tar*}}`

**来源**：`config.env` 中以 `Var` 或 `Tar` 开头的环境变量。

**解析流程**（源码 `messageProcessor.js:422-441`）：
1. 仅在 `role === 'system'` 时处理
2. 遍历 `process.env` 中所有以 `Tar` 或 `Var` 开头的 key
3. 如果值以 `.txt` 结尾 → 从 `TVStxt/` 目录加载文件内容，并**递归解析**其中的变量
4. 否则直接替换为值
5. 未配置的变量替换为 `[未配置 VarXXX]`

> 源码依据：`messageProcessor.js:421-441`

### 第四类：静态插件占位符

**格式**：由插件的 `systemPromptPlaceholders` 字段声明

**来源**：插件的 `plugin-manifest.json` → `capabilities.systemPromptPlaceholders`

**解析流程**（源码 `messageProcessor.js:465-486`）：
1. `pluginManager.getAllPlaceholderValues()` 收集所有静态插件输出
2. 遍历占位符，检查当前文本是否包含
3. 如果值对象有 `vcp_dynamic_fold: true` → 走动态折叠协议
4. 否则直接替换

> 源码依据：`messageProcessor.js:465-486`

---

## 2.3 完整替换顺序

`resolveAllVariables()` 的内部执行顺序（源码行号：36-148）：

```
resolveAllVariables(text, model, role, context)
│
├── Step 1: 判断是否为特权角色
│   └── system 角色 或 VCPTavern 注入的 user 角色
│
├── Step 2: 展开 Agent 占位符（仅在特权角色）         [行55-94]
│   ├── 读取 agent_map.json → Agent 文件
│   ├── 递归展开 Agent 文件内的占位符
│   └── 去重保护（只展开一个 Agent）
│
├── Step 3: 展开 Toolbox 占位符（仅在特权角色）        [行97-139]
│   ├── 读取 toolbox_map.json → TVStxt 文件
│   ├── 解析 [===vcp_fold===] 标记
│   ├── 向量相似度判断 → 折叠/展开
│   └── 去重保护（每种 toolbox 只展开一次）
│
├── Step 4: replacePriorityVariables()              [行143]
│   ├── 表情包占位符替换（{{xxx表情包}}）
│   └── 其他优先变量
│
└── Step 5: replaceOtherVariables()                 [行144]
    ├── SarPrompt 变量（{{SarPrompt1}}, {{SarPrompt2}}...）
    ├── 环境变量（{{VarUser}}, {{TarSysPrompt}}...）[行422-441]
    ├── 时间变量（{{Date}}, {{Time}}, ...）         [行443-463]
    ├── 静态插件占位符                              [行465-486]
    ├── 个体插件描述                                [行503-507]
    ├── 动态工具 {{VCPDynamicTools}}               [行490-501]
    └── 全量工具 {{VCPAllTools}}                   [行509-518]
```

---

## 2.4 常用系统变量速查

### 用户/环境类（来自 config.env）

| 占位符 | 含义 | 来源 |
|:---|:---|:---|
| `{{VarUser}}` | 当前用户名 | `config.env` 中的 `VarUser` 变量 |
| `{{VarHome}}` | 家庭/环境描述 | `config.env` 中的 `VarHome` 变量 |
| `{{VarForum}}` | 论坛内容 | `config.env` 中的 `VarForum` 变量 |
| `{{VarSystemInfo}}` | 系统信息 | `config.env` 中的 `VarSystemInfo` 变量 |

### 系统/工具类

| 占位符 | 含义 | 来源 |
|:---|:---|:---|
| `{{VarToolList}}` | 系统工具列表 | `config.env`，值通常指向 `TVStxt/*.txt` |
| `{{VarRendering}}` | 渲染指令 | `config.env` |
| `{{TarSysPrompt}}` | 核心系统提示词 | `config.env` |
| `{{TarEmojiPrompt}}` | 表情包系统提示词 | `config.env` |
| `{{VarDailyNoteGuide}}` | 日记功能指南 | `config.env`，值指向 `TVStxt/Dailynote.txt` |

### 工具箱类（来自 toolbox_map.json）

| 占位符 | 对应文件 | 内容 |
|:---|:---|:---|
| `{{VCPSearchToolBox}}` | `TVStxt/SearchToolBox.txt` | VSearch, TavilySearch, BilibiliFetch, UrlFetch 等 |
| `{{VCPMemoToolBox}}` | `TVStxt/MemoToolBox.txt` | LightMemo, DeepMemo, TopicMemo |
| `{{VCPFileToolBox}}` | `TVStxt/FileToolBox.txt` | FileOperator, PowerShellExecutor, CodeSearcher 等 |
| `{{VCPMediaToolBox}}` | `TVStxt/MediaToolBox.txt` | DoubaoGen, SunoGen, GrokVideo 等 |
| `{{VCPContactToolBox}}` | `TVStxt/ContactToolBox.txt` | AgentAssistant, AgentMessage, ScheduleManager 等 |

### 时间类（系统自动计算）

| 占位符 | 示例值 | 来源 |
|:---|:---|:---|
| `{{Date}}` | `2026/5/14` | `new Date().toLocaleDateString('zh-CN')` |
| `{{Time}}` | `14:30:25` | `new Date().toLocaleTimeString('zh-CN')` |
| `{{Today}}` | `星期四` | `new Date().toLocaleDateString('zh-CN', {weekday:'long'})` |
| `{{Festival}}` | `丙午马年四月十八 立夏` | 农历 + 节气计算 |

> 源码依据：`messageProcessor.js:443-463`

### 表情包类（正则匹配 `{{xxx表情包}}` 格式）

由 `EmojiListGenerator` 静态插件生成，存储在 `Plugin/EmojiListGenerator/generated_lists/` 目录下。

> 源码依据：`messageProcessor.js:600-604`（replacePriorityVariables 中的表情包处理）

---

## 2.5 值解析的特殊规则

### .txt 后缀自动加载

当环境变量的值以 `.txt` 结尾时，系统会（源码 `messageProcessor.js:427-434`）：

1. 调用 `tvsManager.getContent(value)` 从 `TVStxt/` 加载文件内容
2. 加载后**递归解析**其中的变量（调用 `replaceOtherVariables()`）
3. 如果文件内容以 `[变量文件` 或 `[处理变量文件` 开头 → 视为错误，直接注入不递归

这意味着可以通过 `.txt` 文件构建**嵌套的变量引用链**。例如：
```
config.env:
  VarToolList=ToolListForAgent.txt
  VarDailyNoteGuide=Dailynote.txt

TVStxt/ToolListForAgent.txt:
  可用工具列表：{{VCPSearchToolBox}} {{VCPMemoToolBox}}
```

其中 `{{VCPSearchToolBox}}` 和 `{{VCPMemoToolBox}}` 是 toolbox 占位符，会进一步从 `toolbox_map.json` → `TVStxt/*.txt` → `[===vcp_fold===]` 折叠后注入。

### 占位符格式的白名单

占位符正则（源码 `messageProcessor.js:49`）：
```js
/\{\{([a-zA-Z0-9_:⺀-⿿぀-鿿]+)\}\}/g
```

支持的字符范围：
- `a-zA-Z0-9_` → 英文字母、数字、下划线
- `:` → 命名空间前缀（如 `agent:XXX`, `toolbox:XXX`）
- `⺀-⿿` → CJK 部首补充
- `぀-鿿` → 平假名 + CJK 统一汉字

这意味着 `{{小克日记本}}` 这样的中文占位符**也是合法的**。

---

## 交叉引用

- 工具箱文件的 `[===vcp_fold===]` 折叠机制 → 见 `03-上下文折叠体系.md`
- 记忆系统的 `[[...]]` 语法 → 见 `04-记忆系统.md`
- Agent 提示词的编写规范 → 见 `07-Agent提示词工程.md`
- Plugin 插件生态中静态插件如何输出占位符 → 见 `06-插件生态.md`
