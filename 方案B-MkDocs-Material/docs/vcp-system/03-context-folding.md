# 03 — 上下文折叠体系

> 本系列文档每篇自洽，可独立阅读。末尾标注交叉引用指向关联模块。

---

## 3.1 概述

VCP 的 Toolbox 文件（`TVStxt/*.txt`）可能包含大量工具说明。如果一次性全部注入，会吃掉很多 token。VCP 的解决方案是**两套折叠机制**：

| | `[===vcp_fold:阈值===]` | `<vcp_dynamic_fold trigger="...">` |
|:---|:---|:---|
| **执行层** | VCP 后端（向量计算） | LLM 自身（提示词理解） |
| **决策依据** | 余弦相似度 | trigger 关键词匹配 |
| **决策时机** | 提示词发送给 LLM **之前** | LLM 推理**过程中** |
| **节省 token** | ✅ 物理移除未命中文本 | ❌ 全部文本仍在上下文 |
| **用在哪里** | `TVStxt/*.txt` 工具箱文件 | `Agent/*.txt` 提示词文件 |
| **确定性** | 数学计算，结果确定 | LLM 理解，结果概率性 |

---

## 3.2 第一套：后端向量折叠

### 3.2.1 解析层 —— `foldProtocol.js`

核心正则（源码 `foldProtocol.js:1`）：

```js
const FOLD_REGEX = /^\[===vcp_fold:\s*([0-9.]+)(?:\s*::desc:\s*(.*?)\s*)?===\]\s*$/;
```

这个正则匹配两种格式：
- `[===vcp_fold:0.5===]` —— 基础格式，只设置阈值
- `[===vcp_fold:0.5::desc:科学计算与统计工具===]` —— 带独立描述

`parseFoldBlocks()` 将文本切分成 block 数组（源码 `foldProtocol.js:3-46`）：

```
原始文本:
  ## 1. VSearch (始终注入)
  ...内容...

  [===vcp_fold:0.3===]

  ## 2. SciCalculator
  ...内容...

  [===vcp_fold:0.5::desc:远程服务器脚本执行===]

  ## 3. LinuxShellExecutor
  ...内容...

解析后:
  [
    { threshold: 0.0, description: '', content: 'VSearch\n...' },
    { threshold: 0.3, description: '', content: 'SciCalculator\n...' },
    { threshold: 0.5, description: '远程服务器脚本执行', content: 'LinuxShellExecutor\n...' }
  ]
```

**注意**：第一个 `[===vcp_fold===]` 标记之前的内容自动成为阈值 0.0 的 block（始终注入）。

`buildDynamicFoldObject()` 将 `parseFoldBlocks` 的结果包装为统一对象（源码 `foldProtocol.js:53-70`）：

```js
{
  vcp_dynamic_fold: true,
  dynamic_fold_strategy: 'toolbox_block_similarity', // 默认策略
  plugin_description: '工具箱的描述文本',
  fold_blocks: [ /* ... */ ]
}
```

### 3.2.2 决策层 —— `resolveDynamicFoldProtocol()`

来源：`messageProcessor.js:151-370`。

**完整决策流程**：

```
1. 从最近的 user 消息和 assistant 回复中提取文本        [行169-194]
2. 清洗文本（去 HTML、去 Emoji、去工具标记）               [行201-230]
3. 向量化清洗后的用户上下文                                [行235-238]
   ├── user 消息 → uVec（权重 0.7，默认）
   └── assistant 消息 → aVec（权重 0.3）
4. 加权平均得到用户上下文向量 userVector                    [行240]
5. 根据策略决定展开哪些 block                               [行281-354]
```

### 3.2.3 两种决策策略

源码 `messageProcessor.js:281` 判断当前策略：

```js
const toolboxBlockStrategy = foldObj.dynamic_fold_strategy === 'toolbox_block_similarity';
```

**策略 A：单一阈值（非 toolbox_block_similarity）**

（源码行号：300-310）

```
1. 用 foldObj.plugin_description 做向量化 → descVector
2. cos_sim(descVector, userVector) → 得到整体相似度 sim
3. 从高阈值到低阈值遍历 block，找到第一个 sim >= threshold 的 block
4. 返回该 block 的内容
```

适用场景：当全部 block 共享同一个主题时（如 `template_matching` 策略）。

**策略 B：独立匹配（toolbox_block_similarity，默认）**

（源码行号：312-354）

```
1. 找出无 description 的 block（legacy blocks）：
   └── 用整体相似度统一判断，只展开命中的 legacy block
       └── 如果没有命中任何，则展开阈值最低的那个（fallback）

2. 对有 description 的 block（::desc: 语法指定）：
   └── 每个 block 的 description 独立向量化
   └── cos_sim(blockDescVector, userVector) ≥ blockThreshold → 展开
   └── 多个 block 命中时 → 合并在一起注入

3. 有隐藏 block 时，末尾附加提示：
   "(提示：当前上下文中还隐藏收纳了另外 N 个工具模块分组...)"
```

适用场景：当不同 block 有不同语义主题时。`toolbox_map.json` 中加载的 Toolbox 默认使用此策略。

### 3.2.4 实际效果示例

假�� `SearchToolBox.txt` 结构如下：

```
## VSearch（阈值 0.0，始终注入）
## TavilySearch（阈值 0.0，始终注入）

[===vcp_fold:0.3===]
## BilibiliFetch

[===vcp_fold:0.5===]
## FlashDeepSearch

[===vcp_fold:0.7===]
## SerpSearch（反向搜图）
```

**场景 1：用户说"帮我查一下最新 AI 论文"**
- 用户消息与 `plugin_description` 相似度 = 0.55
- VSearch + TavilySearch ✅（阈值 0.0）
- BilibiliFetch ✅（阈值 0.3，0.55 ≥ 0.3）
- FlashDeepSearch ✅（阈值 0.5，0.55 ≥ 0.5）
- SerpSearch ❌（阈值 0.7，0.55 < 0.7）
- 末尾提示：`*(提示：当前上下文中还隐藏收纳了另外 1 个工具模块分组...)*`

**场景 2：用户做反向搜图**
- 用户消息包含图片 URL，向量相似度 ≥ 0.75
- 所有 block 全部展开 ✅

### 3.2.5 异常降级

当 RAGDiaryPlugin 不可用或向量化失败时（源码行号：163-167、196-199、241-244）：
- 返回 fallback block（阈值最低的 block 或第一个有效 block）
- 确保 LLM 至少能获得基础工具说明

---

## 3.3 第二套：静态插件 JSON 折叠

某些静态插件也输出 `{ vcp_dynamic_fold: true, fold_blocks: [...] }` 格式的 JSON（如 `TagFolder` 插件）。

这些插件的 stdout 被 `Plugin.js` 检测到（源码 `Plugin.js:211-224`），如果包含 `[===vcp_fold===]` 标记或已经是 `vcp_dynamic_fold` 对象，会构建 `foldObj` 存入 `staticPlaceholderValues`。

当 Agent 提示词中的 `{{PluginPlaceholder}}` 被替换时，`messageProcessor.js:481-483` 检测到 `valueToInject.vcp_dynamic_fold === true`，调用同样的 `resolveDynamicFoldProtocol()` 处理。

**TagFolder 案例**（源码 `Plugin/TagFolder/TagFolder.js:44-77`）：

该插件根据 `list.md` 中的标签列表构建折叠规则，输出三层 block：
- 阈值 0.5 → 完整折叠规则（详细说明）
- 阈值 0.2 → 折叠提示（简短版）
- 阈值 0.0 → fallback（一行摘要）

---

## 3.4 第三套：`<vcp_dynamic_fold trigger="...">` —— LLM 注意力路由

### 3.4.1 本质

**VCP 后端完全不会解析这个标签**。在 `VCPToolBox` 和 `VCPChat` 的全部源码中，**不存在任何**解析 `<vcp_dynamic_fold trigger="...">` 的代码。

它是一种**纯提示词工程技巧**——利用 LLM 对 XML 标签的理解能力，引导 LLM 自己做注意力分配。

### 3.4.2 用法

在 Agent 提示词文件中直接写：

```
<vcp_dynamic_fold trigger="崩溃,受不了,放弃,不想活,自伤,绝望">
### 杏仁核 — 伤兵救护
当检测到自伤/自杀信号时：
1. 禁止继续分析
2. 只表达"我在，我听到了"
3. 建议寻求专业心理支持
</vcp_dynamic_fold>
```

LLM 读取到这段内容时，会理解为：「当用户消息中出现这些 trigger 关键词时，应该激活这个模块来指导我的回复；否则这只是低优先级的背景信息。」

### 3.4.3 教员的完整用法

教员提示词（`Agent/教员.txt`）有 7 个动态折叠模块：

| 模块 | trigger 关键词 | 作用 |
|:---|:---|:---|
| mPFC 社交子系统 | 心情,感受,开心,累了,闲聊,晚安... | 战友温度，先接住人 |
| 杏仁核 | 崩溃,受不了,放弃,不想活,自伤... | 危机处理，关怀优先 |
| CEN 矛盾分析 | 矛盾,分析,困境,问题,怎么办... | 主要矛盾→内因外因→统一战线 |
| dlPFC 战略推演 | 井冈山,长征,延安,进城,阶段,推演... | 历史阶段映射 + 五步推演 |
| 基底神经节 | 示例,怎么说,案例,类似,参考... | Few-Shot 程序性记忆 |
| 小脑红线 | 安全,红线,禁止,转义,权限... | 低频精细规则库 |
| DMN 复盘 | 复盘,反思,上次,进展,变化,跟进... | 复盘锚点 + 认知偏差自检 |

### 3.4.4 什么时候用这套

- ✅ 认知模块很大（几百行），不想每个请求都让 LLM 平等处理
- ✅ 希望引导 LLM 按场景激活不同的行为模式
- ✅ 不适合抽到 TVStxt 做向量折叠（因为内容高度依赖 Agent 角色）
- ❌ 想要物理节省 token——这套机制不减少 token，全部文本都在上下文中

---

## 交叉引用

- Toolbox 文件的占位符引用 → 见 `02-变量与占位符体系.md` §2.2 第二类
- 记忆系统的向量化基础 → 见 `04-记忆系统.md`
- Agent 提示词编写中的折叠策略选择 → 见 `07-Agent提示词工程.md`
