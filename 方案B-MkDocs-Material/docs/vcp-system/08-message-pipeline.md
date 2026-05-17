# 08 — 完整消息处理管线

> 本文档从**运行时动态视角**描述一条用户消息从到达 VCP 到返回响应的完整处理流程。
> 已有文档 01-07 是「零件视角」，本文档是「装配视角」。

---

## 8.1 管线全景

源码主线：`modules/chatCompletionHandler.js:531-701` + 后续工具循环。

```
用户消息 POST /v1/chat/completions
│
├─ ① VCPTavern 优先预处理器      [chatCompletionHandler.js:534]
│   └─ 扫描 {{VCPTavern::presetName}} → 注入预设内容为 user 消息
│
├─ ② 变量替换 (逐条消息串行)       [chatCompletionHandler.js:562-589]
│   ├─ Agent 占位符 → Agent/*.txt 递归展开（整个上下文仅展开一个）
│   ├─ Toolbox 占位符 → TVStxt/*.txt → 向量折叠 → 注入
│   ├─ 环境变量 ({{Var*}} {{Tar*}}) → config.env → .txt 递归加载
│   ├─ SarPrompt ({{SarPrompt*}}) → sarPromptManager
│   ├─ 时间变量 ({{Date}} {{Time}}...) → 系统时钟
│   └─ 静态插件占位符 → pluginManager.getAllPlaceholderValues()
│
├─ ③ 媒体处理器                   [chatCompletionHandler.js:593-617]
│   └─ ImageProcessor / MultiModalProcessor（图片/视频预处理）
│
├─ ④ 通用消息预处理器              [chatCompletionHandler.js:619-630]
│   ├─ RAGDiaryPlugin — [[...]] 记忆召回
│   ├─ ContextFoldingV2 — 对话楼层摘要折叠
│   └─ 其他已注册的 messagePreprocessor
│
├─ ⑤ TransBase64+ 清理与恢复       [chatCompletionHandler.js:633-666]
│   └─ 多媒体 base64 数据恢复
│
├─ ⑥ 发送给 AI API               [chatCompletionHandler.js:675-701]
│   └─ fetchWithRetry（指数退避，Keep-Alive 长连接池）
│
└─ ⑦ 工具调用循环 (LLM 响应中)     [后续流程]
    ├─ ToolCallParser.parse(content)
    │   └─ 先移除 <thinking> 块 → 再解析 <<<[TOOL_REQUEST]>>>
    ├─ ToolExecutor 执行工具
    │   └─ 本地 stdio / 远程分布式 / 异步委托
    ├─ 结果注入上下文（作为 assistant 消息）
    └─ 继续 LLM 推理（最多 MaxVCPLoopStream/NonStream 次）
```

> 源码依据：`modules/chatCompletionHandler.js:531-701`

---

## 8.2 各步骤详解

### ① VCPTavern 优先预处理器

**执行时机**：在所有变量替换**之前**。

（源码 `chatCompletionHandler.js:531-541`）

```javascript
if (pluginManager.messagePreprocessors.has('VCPTavern')) {
    tavernProcessedMessages = await pluginManager.executeMessagePreprocessor(
        'VCPTavern', originalBody.messages
    );
}
```

VCPTavern 是唯一硬编码优先执行的预处理器。它扫描 system 消息中的 `{{VCPTavern::presetName}}` 触发词，将预设内容以 `[系统邀请指令:]` 前缀注入为新 user 消息。

`[系统邀请指令:]` 这个前缀被 `messageProcessor.js:43` 识别为特权角色，允许这些注入消息中的 Agent/Toolbox 占位符正常展开。

### ② 变量替换

**执行方式**：逐条消息**串行**处理。

（源码 `chatCompletionHandler.js:559-590`）

```javascript
for (const msg of tavernProcessedMessages) {
    newMessage.content = await messageProcessor.replaceAgentVariables(
        newMessage.content, originalBody.model, msg.role, processingContext
    );
}
```

串行处理确保 Agent/Toolbox 的「首次展开」语义正确——如果并行处理，多条消息可能同时展开不同 Agent。

**展开顺序**（`messageProcessor.js:36-148`）：
1. Agent 占位符（先到先得，后续全部忽略）
2. Toolbox 占位符（每种只展开一次）
3. SarPrompt + 环境变量 + 时间 + 静态插件

### ③④ 预处理器链

消息预处理器在变量替换**之后**执行。这意味着预处理器收到的消息中，Agent/Toolbox/时间等占位符已经全部替换完毕。

**RAGDiaryPlugin**（最关键的预处理器）：
- 扫描已替换后的 system 消息中的 `[[...]]` 记忆引用
- 执行语义检索
- 将召回的记忆内容替换占位符

### ⑤ TransBase64+ 清理

多媒体消息（图片/视频 base64）在预处理期间被备份到 `__vcp_media_backup__` 字段，预处理完成后恢复。避免 base64 数据被预处理器修改。

### ⑥⑦ 发送与工具循环

处理完的消息发往 AI API。LLM 响应中如果包含 `<<<[TOOL_REQUEST]>>>`，则进入工具调用循环。

---

## 8.3 预处理器执行顺序

（源码 `chatCompletionHandler.js:534, 611, 622`）

```
VCPTavern                    (硬编码优先)
    ↓
变量替换全部完成
    ↓
ImageProcessor/MultiModalProcessor  (硬编码其次)
    ↓
RAGDiaryPlugin               (按注册顺序)
ContextFoldingV2
CapturePreprocessor
ToolBoxFoldMemo
...其他预处理器
```

---

## 8.4 关键时序约束

| 约束 | 原因 |
|:---|:---|
| VCPTavern 必须最先执行 | 注入的多Agent上下文必须先于变量替换，否则注入内容中的占位符无法展开 |
| 变量替换必须串行 | Agent/Toolbox 去重保护依赖「先到先得」语义 |
| RAGDiaryPlugin 在变量替换后 | 需要 Agent 提示词中的 `[[...]]` 已被展开为完整日记本名 |
| ImageProcessor 在通用预处理器前 | 图片预处理可能影响后续文本处理 |

---

## 8.5 与已有文档的关系

- ① VCPTavern → 详见 `09-多Agent协同体系.md`
- ② 变量替换 → 详见 `02-变量与占位符体系.md`
- ② 折叠协议 → 详见 `03-上下文折叠体系.md`
- ④ RAGDiaryPlugin → 详见 `04-记忆系统.md`
- ⑦ 工具循环 → 详见 `05-工具调用协议.md`
