# 05 — 工具调用协议

> 本系列文档每篇自洽，可独立阅读。末尾标注交叉引用指向关联模块。

---

## 5.1 概述

VCP 不使用 OpenAI 的 function-calling JSON Schema。它有一套自创的工具调用语法，核心特征：
- 用 `<<<[TOOL_REQUEST]>>>` 包裹工具调用块
- 用 `「始」...「末」` 作为参数值定界符（避免与 JSON/XML 冲突）
- 支持批量调用、异步模式、转义写入

核心解析文件：`modules/vcpLoop/toolCallParser.js`

---

## 5.2 基础语法

### 5.2.1 工具调用块格式

（源码 `toolCallParser.js:3-6`）

```
<<<[TOOL_REQUEST]>>>
tool_name:「始」PluginName「末」,
param1:「始」value1「末」,
param2:「始」value2「末」
<<<[END_TOOL_REQUEST]>>>
```

解析器定义了两个定界标记（源码 `toolCallParser.js:3-6`）：
- `START`: `<<<[TOOL_REQUEST]>>>`
- `END`: `<<<[END_TOOL_REQUEST]>>>`

### 5.2.2 参数扫描逻辑

（源码 `toolCallParser.js:137-194`）

`_scanFields()` 逐字符扫描工具调用块：
1. 跳过空白和逗号
2. 提取 key（`[\w_]+` 正则匹配）
3. 跳过空白
4. 遇到 `:` → 进入值解析
5. 检测 `「始」` 或 `「始ESCAPE」` → 找到对应 `「末」` → 提取值
6. 遇到 `,` → 进入下一个字段

### 5.2.3 解析结果

（源码 `toolCallParser.js:76-108`）

```js
{
  name: 'PluginName',       // tool_name 的值
  args: {                   // 其他字段作为参数
    param1: 'value1',
    param2: 'value2'
  },
  archery: false,           // archery 字段 → 是否异步
  markHistory: false,       // ink 字段 → 是否记录到 history
  river: null,              // river 字段
  vref: null                // vref 字段
}
```

### 5.2.4 特殊字段

| 字段 | 作用 | 取值 |
|:---|:---|:---|
| `tool_name` | 插件名称 | 必须是已注册的插件名 |
| `archery` | 异步模式 | `true` 或 `no_reply`（不等待回执） |
| `ink` | 持久化结果 | `mark_history`（保存调查结果到上下文） |
| `river` | 河流标记 | Agent 内部引用 |
| `vref` | 向量引用 | 向量相关引用 |

---

## 5.3 转义机制

当文件**内容本身**包含 `「始」「末」` 或 `<<<[TOOL_REQUEST]>>>` 时，必须使用转义（源码 `toolCallParser.js:8-18`）。

### 转义语法

```
「始ESCAPE」包含VCP工具指令的内容「末ESCAPE」
```

### 转义映射表

（源码 `toolCallParser.js:13-18`）

| 转义形式 | 实际值 |
|:---|:---|
| `<<<[TOOL_REQUEST_ESCAPE]>>>` | `<<<[TOOL_REQUEST]>>>` |
| `<<<[END_TOOL_REQUEST_ESCAPE]>>>` | `<<<[END_TOOL_REQUEST]>>>` |
| `「始ESCAPE」` | `「始」` |
| `「末ESCAPE」` | `「末」` |

### 转义在块解析中的处理

（源码 `toolCallParser.js:110-135`）

`_findBlockEnd()` 在查找 `<<<[END_TOOL_REQUEST]>>>` 时，**会自动跳过** `「始ESCAPE」...「末ESCAPE」` 包裹的区域——确保转义块内的 `<<<[END_TOOL_REQUEST]>>>` 不会被误判为工具块的结束。

---

## 5.4 批量指令

（源码来自 `TVStxt/FileToolBox.txt:100-113`）

通过**数字后缀**区分参数组，一次调用执行多个操作：

```
<<<[TOOL_REQUEST]>>>
tool_name:「始」FileOperator「末」,
command1:「始」RenameFile「末」,
sourcePath1:「始」/path/to/old_name.txt「末」,
destinationPath1:「始」/path/to/new_name.txt「末」
command2:「始」RenameFile「末」,
sourcePath2:「始」/path/to/old_name2.txt「末」,
destinationPath2:「始」/path/to/new_name2.txt「末」
command3:「始」EditFile「末」,
filePath3:「始」/path/to/existing_file.txt「末」,
content3:「始」这是覆盖后的新内容。「末」
<<<[END_TOOL_REQUEST]>>>
```

同一组内的参数共享数字后缀（`command1` 对应 `sourcePath1`、`destinationPath1`）。

---

## 5.5 工具调用在 `<thinking>` 中的处理

（源码 `toolCallParser.js:28`）

```js
const contentWithoutThink = content.replace(/<think>[\s\S]*?<\/think>/g, '');
```

解析工具调用前，**先移除所有 `<thinking>` 块的内容**。这意味着：
- LLM 不能在 `<thinking>` 中做工具调用
- 工具调用必须位于 `<thinking>` 闭合之后的正文区域
- 这是 LLM 输出侧的约束，与 VChat 客户端渲染 `<thinking>` 气泡的行为一致

---

## 5.6 工具调用循环

VCP 的对话处理流程中，LLM 响应被解析后，如果包含 `<<<[TOOL_REQUEST]>>>`：

```
1. LLM 生成响应
2. ToolCallParser.parse(content) → 提取工具调用列表
3. ToolExecutor 逐个执行工具调用
4. 工具结果注入上下文（作为新的 assistant 消息）
5. 继续调用 LLM，让它基于结果继续推理
6. 重复直到无工具调用 或 达到 MaxVCPLoop 上限
```

循环上限通过 `config.env` 配置：
- `MaxVCPLoopStream` — 流式模式最大循环次数（默认 5）
- `MaxVCPLoopNonStream` — 非流式模式最大循环次数（默认 5）

> 源码依据：`docs/CONFIGURATION.md:128-129`

---

## 5.7 格式红线

**最重要的一条规则**（在所有 Agent 提示词中反复强调）：

> 工具调用必须使用 `<<<[TOOL_REQUEST]>>>` 语法，**绝对禁止** Markdown JSON 代码块（即 ````json` 包裹的 JSON）。

原因：VCP 的 `ToolCallParser` 只识别 `<<<[TOOL_REQUEST]>>>` 标记，不识别 OpenAI 的 function-calling JSON 格式。

---

## 交叉引用

- Toolbox 文件中定义的工具使用方法 → 见 `02-变量与占位符体系.md`
- 记忆系统工具（LightMemo, DeepMemo, DailyNote）→ 见 `04-记忆系统.md` §4.5-4.6
- 插件系统中 plugin-manifest.json 的 invocationCommands → 见 `06-插件生态.md`
