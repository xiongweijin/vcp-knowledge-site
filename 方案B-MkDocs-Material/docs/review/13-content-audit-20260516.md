# VCP 功能及源码解读文档审核报告

**审核日期**：2026-05-16  
**审核范围**：`更新日志/vcp功能及源码解读/` 主文档与 `agent提示词/` 样本  
**审核方式**：只读核验；对照当前工作区源码、插件 manifest 与关键运行链路。  

---

## 一、结论摘要

这套文档的总体结构是可用的：`01-07` 解释静态机制，`08-10` 补足动态联动，`11-12` 把机制转成 Agent 配置与提示词架构建议，`99` 作为盲区回顾。文档的主脉络清晰，尤其是变量替换、TagMemo+、VCPTavern 优先执行、消息管线等方向基本抓住了 VCP 的关键。

但当前文档已经出现几处需要优先修正的硬事实偏差：

1. `<thinking>` 与 `<think>` 标签混用，且工具解析安全语义被写反。
2. 插件数量、插件类型统计明显过期。
3. `VCPTavern` 的插件类型表述不准确。
4. 分布式/Chrome/hybridservice 路由说明引用了错误代码段。
5. `11-Agent配置建议.md` 与当前样本文档版本有明显时序错位。

建议先修正文档事实，再进入提示词优化建议落地。否则后续 Agent 配置会建立在不稳定口径上。

---

## 二、高优先级问题

### P0：`<thinking>` 工具调用隔离结论与源码不一致

**涉及文档**
- `05-工具调用协议.md:132-143`
- `08-消息处理管线.md:42`
- `07-Agent提示词工程.md:89-131`
- `12-提示词架构优化方案.md:35-37, 226-271, 472-500`
- `agent提示词/*.txt` 中大量 `<thinking>` 规则与 Few-Shot

**文档当前说法**

文档说工具解析前会移除 `<thinking>` 块，因此 LLM 不能在 `<thinking>` 中做工具调用。

**源码事实**

`modules/vcpLoop/toolCallParser.js:28` 实际代码是：

```js
const contentWithoutThink = content.replace(/<think>[\s\S]*?<\/think>/g, '');
```

也就是说，当前工具解析器只移除 `<think>...</think>`，不移除 `<thinking>...</thinking>`。

**风险**

如果 Agent 按文档使用 `<thinking>`，并在其中误写 `<<<[TOOL_REQUEST]>>>`，当前 parser 仍可能解析并执行该工具调用。这不是纯文档风格问题，而是工具执行边界问题。

**建议**

二选一，建议优先方案 A：

- 方案 A：修源码，让 parser 同时移除 `<think>` 与 `<thinking>`。然后文档保持 `<thinking>` 规范。
- 方案 B：统一文档与 Agent 提示词，全部改成 `<think>`，并说明 VChat 渲染是否支持该标签。

在未修正前，`05` 和 `08` 不能继续声称 `<thinking>` 内工具调用会被忽略。

---

### P1：插件数量与类型统计过期

**涉及文档**
- `01-系统全景.md:30-31`
- `06-插件生态.md:9, 18-29, 228`
- `99-系统联动全景与盲区分析.md:16`
- `00-总索引.md:197`

**文档当前口径**

文档中混用了这些数字：

- 87 个插件目录、79 个活跃插件、8 个禁用插件
- 95+ 活跃插件
- 54 插件分类
- 8 份文档约 2500 行

**当前工作区核验结果**

实际扫描 `Plugin/` 得到：

```text
PluginDirs=107
ActiveManifests=96
BlockedManifests=11

asynchronous=2
hybridservice=10
messagePreprocessor=4
service=5
static=14
synchronous=61
```

**风险**

插件生态文档是后续审核工具能力、权限边界和 Agent 工具挂载的基础。如果数量口径不统一，会导致“哪些插件可用”“哪些是禁用态”“哪些类型需要安全审查”都失真。

**建议**

在 `06-插件生态.md` 中新增“统计时间/统计命令”，统一当前口径：

```text
截至 2026-05-16 当前工作区：
107 个 Plugin 子目录，96 个活跃 manifest，11 个禁用 manifest。
按 pluginType：synchronous 61、static 14、hybridservice 10、service 5、messagePreprocessor 4、asynchronous 2。
```

同时在 `01`、`00`、`99` 中避免写死旧数量，或标注“历史快照”。

---

### P1：`VCPTavern` 类型表述不准确

**涉及文档**
- `09-多Agent协同体系.md:57`
- `06-插件生态.md:178`
- `08-消息处理管线.md:55-69`

**文档当前说法**

`09` 称 `VCPTavern` 类型是 `messagePreprocessor`，`06` 将其列为 `service`。

**源码事实**

`Plugin/VCPTavern/plugin-manifest.json:7`：

```json
"pluginType": "hybridservice"
```

`Plugin.js:494-497`：

```js
const isPreprocessor = manifest.pluginType === 'messagePreprocessor' || manifest.pluginType === 'hybridservice';
const isService = manifest.pluginType === 'service' || manifest.pluginType === 'hybridservice';
```

即：`VCPTavern` 是 `hybridservice`，并因加载器规则同时进入 `messagePreprocessors` 与 service 初始化路径。

**建议**

统一改成：

> `VCPTavern` 的 manifest 类型是 `hybridservice`。加载器会将 `hybridservice` 同时视作可直接调用服务与消息预处理器，因此它能作为硬编码优先预处理器执行。

这样比直接写 `messagePreprocessor` 更精确。

---

### P1：分布式路由说明引用了错误代码段

**涉及文档**
- `10-分布式与安全.md:24-35`

**文档当前说法**

文档称 `Plugin.js:870-872` 表示 distributed 协议会转发到远程节点，并引用了：

```js
if (plugin.pluginType === 'hybridservice' && plugin.communication?.protocol === 'direct') {
    resultFromPlugin = await this.webSocketServer.forwardCommandToChrome(command, args);
}
```

**源码事实**

`Plugin.js:854-860` 才是分布式工具：

```js
if (plugin.isDistributed) {
    resultFromPlugin = await this.webSocketServer.executeDistributedTool(plugin.serverId, toolName, pluginSpecificArgs);
}
```

`Plugin.js:862-870` 是 `ChromeControl` 特殊路径。  
`Plugin.js:872+` 是本地 `hybridservice + direct` 调用路径。

**风险**

这会误导安全审查：分布式工具、Chrome 控制、hybridservice direct 是三个不同执行面，权限和攻击面不同，不能混写。

**建议**

`10` 中拆成三段：

1. 分布式：`plugin.isDistributed` → `executeDistributedTool()`
2. ChromeControl：工具名为 `ChromeControl` 且 `direct` → `forwardCommandToChrome()`
3. 本地 hybridservice：`pluginType === 'hybridservice' && protocol === 'direct'`

---

## 三、中优先级问题

### P2：`11-Agent配置建议.md` 与当前样本版本错位

**涉及文档**
- `11-Agent配置建议.md`
- `agent提示词/小娜_v4.0_20260514.txt`
- `agent提示词/小程 3.7.2.txt`
- `agent提示词/小绝 3.7.3.txt`
- `agent提示词/Weiming - 副本.txt`

**现象**

`11` 仍按 v3.1.x / 固定 `TagMemo0.65/0.5/0.55` 的状态描述 6 个 Agent。  
但当前样本中，小娜 v4.0、小程 3.7.2、小绝 3.7.3、Weiming 副本都已经大量使用 `TagMemo+`、聚合日记引用与新的模块化结构。

**建议**

将 `11` 改成“历史审查快照”，或升级为两栏：

| Agent | 旧版问题 | 当前样本状态 | 仍待处理 |

例如小程：

- 旧版建议：缺 `{{VCPTavern::dailychat}}`
- 当前样本：仍未发现 `{{VCPTavern::dailychat}}`
- 当前样本：已迁移 `TagMemo+`
- 当前样本：仍未发现 `<<VCP开发日记本>>`

这样可以保留历史价值，同时避免读者以为所有问题仍是当前事实。

---

### P2：`AIMemo:0.6` 的“语义标注”写法容易误导维护者

**涉及文档**
- `12-提示词架构优化方案.md:118-138`
- `agent提示词/*.txt`

**源码事实**

`RAGDiaryPlugin.js:1492` 等位置使用：

```js
modifiers.match(/::AIMemo(?::([\w-]+))?/)
```

这个正则不会把 `0.6` 作为完整预设名捕获，文档对此已有说明。

**风险**

虽然 `12` 已说明 `0.6/0.3` 不是机器阈值，但模板仍继续推荐 `::AIMemo:0.6`。维护者可能误以为这是可执行阈值配置。

**建议**

推荐模板中改成更不易误解的写法：

```markdown
[[...::AIMemo]] <!-- 语义目标：公共记忆高相关度 -->
```

或使用真实预设名：

```markdown
[[...::AIMemo:PublicHigh]]
```

如果坚持保留 `AIMemo:0.6`，必须在模板旁边加粗注明：**该小数不会被系统解析为阈值**。

---

### P2：`TagMemo+` 建议方向正确，但“不再使用 Rerank”表述偏绝对

**涉及文档**
- `12-提示词架构优化方案.md:306-320`

**源码事实**

`RAGDiaryPlugin.js:2358-2363` 支持 `Rerank` / `Rerank+`。  
`RAGDiaryPlugin.js:2371-2384` 支持 `TagMemo+` 测地线重排。  
两者不是互斥机制，源码也支持叠加。

**建议**

把“通常 `TagMemo+` 单独使用已足够”保留为经验建议，但避免写成原则性替代。更稳妥表述：

> 默认优先 `TagMemo+`；当召回候选质量高但排序仍不稳定，或需要 cross-encoder 语义精排时，再叠加 `::Rerank` / `::Rerank+`。

---

### P2：`00-总索引.md` 的文档数量描述过期

**涉及文档**
- `00-总索引.md:197`

**问题**

文末仍写“8 份文档总计约 2500 行”，但当前目录已有 14 个主 Markdown 文档，另有多份 Agent 提示词样本。

**建议**

改成：

> 当前目录包含 14 个主 Markdown 文档与若干 Agent 提示词样本；行数以当前文件统计为准。

---

## 四、确认基本可靠的内容

以下内容经过第一轮抽查，方向基本可靠：

1. **VCPTavern 优先执行顺序**  
   `chatCompletionHandler.js:531-541` 确实在变量替换前优先调用 `VCPTavern`。

2. **变量替换串行处理**  
   `chatCompletionHandler.js:565` 与 `576` 附近逐条调用 `messageProcessor.replaceAgentVariables()`，文档关于串行处理的描述成立。

3. **hybridservice 可进入预处理器集合**  
   `Plugin.js:494-497` 支持该判断，这解释了 `VCPTavern` 的特殊行为。

4. **`TagMemo+` 启用测地线重排**  
   `RAGDiaryPlugin.js:2371-2384` 明确支持 `::TagMemo+` 和 `useGeodesicRerank`。

5. **动态 TagMemo 默认权重范围**  
   `RAGDiaryPlugin.js:610-612` 默认 `tagWeightRange` 是 `[0.05, 0.45]`，文档中关于 `TagMemo0.65` 超出默认动态上限的判断成立。

6. **AIMemo 全局许可证**  
   `RAGDiaryPlugin.js:1121-1124` 检测 `[[AIMemo=True]]`，文档说明成立。

7. **聚合日记本 `|` 语法**  
   `RAGDiaryPlugin.js:2012-2024` 支持按 `|` 拆分多个日记本名。

---

## 五、建议修订顺序

建议按以下顺序修文档：

1. `05-工具调用协议.md`  
   修正 `<thinking>` / `<think>` 工具隔离说明。

2. `08-消息处理管线.md`  
   同步修正“先移除 `<thinking>` 块”的说法。

3. `10-分布式与安全.md`  
   拆清 distributed、ChromeControl、hybridservice direct 三条路径。

4. `06-插件生态.md`  
   更新插件数量、类型统计，并修正 `VCPTavern` 类型。

5. `09-多Agent协同体系.md`  
   修正 `VCPTavern` 类型为 `hybridservice`，说明其作为预处理器的来源是加载器规则。

6. `11-Agent配置建议.md`  
   改为历史快照或升级成“旧版问题 / 当前样本状态 / 待处理”表。

7. `12-提示词架构优化方案.md`  
   调整 `AIMemo:0.6` 与 `Rerank` 的表述，避免维护者误会。

8. `00-总索引.md` / `01-系统全景.md` / `99-系统联动全景与盲区分析.md`  
   同步修正数量口径与目录状态。

---

## 六、后续可执行项

如果要进入下一阶段，建议拆成两类任务：

### A. 纯文档修订

只改 `更新日志/vcp功能及源码解读/*.md`，不碰源码。目标是让文档准确描述当前源码。

### B. 源码安全修正

修 `modules/vcpLoop/toolCallParser.js`，让工具解析器同时移除 `<think>` 和 `<thinking>`。随后再回头统一文档和 Agent 提示词规范。

当前最推荐先做 B，因为它影响工具调用边界；修完后文档就可以稳定采用 `<thinking>` 规范。
