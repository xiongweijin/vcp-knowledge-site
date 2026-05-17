# 04 — 记忆系统

> 本系列文档每篇自洽，可独立阅读。末尾标注交叉引用指向关联模块。

---

## 4.1 概述

VCP 的记忆系统是给 AI 提供「长期记忆」的基础设施。核心文件：
- `KnowledgeBaseManager.js` — 向量库/RAG 总控
- `Plugin/RAGDiaryPlugin/RAGDiaryPlugin.js` — 消息预处理器，负责记忆召回
- `KnowledgeBaseManager.js:76-135` — 双索引初始化

技术栈：SQLite (持久化) + Vexus/Rust N-API (向量索引) + chokidar (文件监听热更新)

> 源码依据：`docs/MEMORY_SYSTEM.md:35-42`、`AGENTS.md:43`

---

## 4.2 双索引架构

（源码 `KnowledgeBaseManager.js:59-60、210-220、91-98`）

```
KnowledgeBaseManager
├── diaryIndices: Map<diaryName, VexusIndex>
│   └── 每个日记本一个独立向量索引
│   └── 懒加载，按需创建
│   └── md5(diaryName) → VectorStore/index_diary_{md5}.usearch
│
└── tagIndex: 单一 VexusIndex
    └── 全局 Tag 索引
    └── 容量 50000
    └── TagMemo 算法的核心查询对象
```

**物理存储结构**（`VectorStore/` 目录）：

```
VectorStore/
├── knowledge_base.sqlite        # 元数据+标签+chunk+向量
│   ├── files                    # 文件元数据
│   ├── chunks                   # 文本块 + 向量
│   ├── tags                     # 标签 + 向量
│   ├── file_tags                # 文件-标签关联
│   └── kv_store                 # 键值存储
├── index_global_tags.usearch    # 全局 Tag 向量索引
└── index_diary_{md5}.usearch    # 各日记本独立向量索引
```

> 源码依据：`docs/MEMORY_SYSTEM.md:66-131`

---

## 4.3 记忆引用语法 `[[...]]`

当 Agent 提示词中写下 `[[小克日记本::Time::Group::TagMemo+]]` 这行文字时，`RAGDiaryPlugin`（消息预处理器）会将其解析为**记忆召回指令**。

### 4.3.1 三种引用形式

（源码 `RAGDiaryPlugin.js:1396-1399`）

| 语法 | 含义 | RAG 行为 |
|:---|:---|:---|
| `[[日记本名::参数]]` | 标准引用 | 语义检索 + 向量排序，注入上下文 |
| `<<日记本名>>` | 只读引用 | 直接注入日记内容，不经过 RAG 语义过滤 |
| `《《日记本名::参数》》` | 低优先级引用 | 语义检索但阈值更低，作为背景参考 |

### 4.3.2 核心参数

| 参数 | 含义 | 示例 |
|:---|:---|:---|
| `Group` | 按分组组织记忆条目 | `::Group` |
| `Time` | 时间衰减排序（越近权重越高） | `::Time` |
| `TagMemo+` | 启用浪潮 RAG 标签增强（默认阈值） | `::TagMemo+` |
| `TagMemo0.65` | 指定浪潮 RAG 阈值为 0.65 | `::TagMemo0.65` |
| `AIMemo:0.6` | AI 自动记忆召回阈值 | `::AIMemo:0.6` |
| `Rerank` | 启用重排序（Cross-encoder 二次精排） | `::Rerank` |
| `Truncate0.25` | 截断阈值，低于该分数的结果丢弃 | `::Truncate0.25` |

### 4.3.3 聚合检索语法

（源码 `RAGDiaryPlugin.js:2012-2032`）

用 `|` 连接多个日记本名，一次检索多个知识库：

```
[[物理|政治|python::Time::Group::TagMemo+]]
```

被 `_parseAggregateSyntax()` 解析为：
```js
{
  diaryNames: ['物理', '政治', 'python'],
  isAggregate: true,
  kMultiplier: 1.0
}
```

### 4.3.4 特殊语法

`[[VCP元思考:链名称::Group]]` — 触发 VCP 元思考链（独立于 `<thinking>` 思维链的**系统层**预研机制，在 Agent 收到请求前后台执行语义检索和知识整理）。

`[[AIMemo=True]]` — 全局 AIMemo 许可证，必须存在此行，所有 `::AIMemo:0.6` 修饰符才会生效。

> 源码依据：`RAGDiaryPlugin.js:1114-1132`（AIMemo 许可证检测）、`RAGDiaryPlugin.js:1402-1474`（元思考链处理）

---

## 4.4 浪潮 RAG 算法 (TagMemo)

核心思想（源自 `docs/MEMORY_SYSTEM.md:29-33`）：**标签是语义空间中的引力源**。查询向量被标签引力「拉扯」和「扭曲」，穿透表层文字直达语义核心。

### 算法组件

| 组件 | 文件 | 作用 |
|:---|:---|:---|
| TagMemo 引擎 | `TagMemoEngine.js` | 标签引力场计算 |
| EPA 模块 | `EPAModule.js` | 语义空间定位 (Embedding Projection Analysis) |
| 残差金字塔 | `ResidualPyramid.js` | 能量精细拆解，多粒度语义匹配 |
| 结果去重器 | `ResultDeduplicator.js` | SVD 智能结果去重 |
| 浪潮 V8 | 测地线向量检测 | 非 KNN 的语义空间路由算法 |

### tag_boost 参数

当 Agent 调用 LightMemo 时指定 `tag_boost:「始」0.6「末」`，会启用浪��� V8 测地线向量检测系统——在向量空间中以标签为锚点沿测地线寻路，而非简单 KNN。

> 源码依据：`docs/MEMORY_SYSTEM.md:1-19`（章节索引）

---

## 4.5 记忆工具链

### LightMemo — 主动语义检索

补足 RAG 自动召回不全的情况。让 Agent 主动提问去搜索记忆库。

```
maid:「始」Nova「末」,
tool_name:「始」LightMemo「末」,
query:「始」关于上次A项目会议的讨论内容「末」,
k:「始」3「末」,
rerank:「始」true「末」,
tag_boost:「始」0.6「末」
```

> 源码文件：`Plugin/LightMemo/`

### DeepMemo — 历史聊天回溯

基于 Rust Tantivy 全文检索引擎 + 向量语义检索的**双重混合检索**。搜索本地聊天历史文件。

```
tool_name:「始」DeepMemo「末」,
maid:「始」你的名字「末」,
keyword：「始」VCP服务器, 配置, [闲聊]「末」
```

检索词支持高级语法（来源 `VCP记忆管理系统.md:57-62`）：
- 精确短语：`"VCP服务器"`
- 正向加权：`(重要概念:1.5)`
- 负向排除：`[闲聊]`
- OR 逻辑：`{破解|渗透|测试}`

> 源码文件：`Plugin/DeepMemo/`

### TopicMemo — 话题级回忆

回忆 VChat 中特定话题的完整对话记录。

```
tool_name:「始」TopicMemo「末」,
command:「始」GetTopicContent「末」,
topic_id:「始」topic_1766164936527「末」
```

---

## 4.6 日记系统

### 创建日记 (DailyNote)

```
<<<[TOOL_REQUEST]>>>
maid:「始」[Nova]Nova「末」,
tool_name:「始」DailyNote「末」,
command:「始」create「末」,
Date:「始」2026-05-14「末」,
Content:「始」[14:30] 今日讨论了VCP的折叠体系。
Tag: 上下文折叠, vcp_fold, RAG语义检索「末」,
archery:「始」no_reply「末」
<<<[END_TOOL_REQUEST]>>>
```

**maid 格式**：`[日记本名]Agent名`
- `[Nova]Nova` → 写入 Nova 日记本
- `[Nova的知识]Nova` → 写入 Nova 知识日记本
- `[公共]Nova` → 写入跨 Agent 共享索引

**日记分类原则**：
- 日常/经历 → `[角色名]`
- 知识/方法论 → `[角色名的知识]`
- 跨 Agent 共享 → `[公共]`

### 更新日记 (DailyNote update)

```
tool_name:「始」DailyNote「末」,
command:「始」update「末」,
target:「始」日记中需被替换的旧内容，至少15字符「末」,
replace:「始」替换后写入的新内容「末」,
archery:「始」no_reply「末」
```

一次调用只改一处匹配。target 至少 15 字符。

### 整理日记 (DailyNoteManager)

```
// 列出日记
tool_name:「始」DailyNoteManager「末」,
command:「始」list「末」,
folder:「始」Nova「末」,
startDate:「始」2026-04-01「末」,
endDate:「始」2026-04-30「末」

// 整理合并
tool_name:「始」DailyNoteManager「末」,
command:「始」organize「末」,
urls:「始」Nova/2026-04-18-14_52_57.txt
Nova/2026-04-18-15_30_22.txt「末」

// 浪潮联想
tool_name:「始」DailyNoteManager「末」,
command:「始」associate「末」,
url:「始」Nova/2026-04-18-14_52_57.txt「末」,
range:「始」Nova, Nova的知识「末」,
k:「始」10「末」,
minScore:「始」0.65「末」
```

### 联想锚定

在回复正文中落下语义锚点，为下一次 RAG 召回铺设联想通路：
- `[@分支锚点]` — 开辟新联想通路，不干扰已有拓扑
- `[@!核心锚点]` — 写入记忆主干，产生语义引力

---

## 交叉引用

- 折叠体系中向量计算依赖 RAGDiaryPlugin → 见 `03-上下文折叠体系.md`
- 日记创建/更新/整理的完整语法 → 见 `05-工具调用协议.md`
- Agent 提示词中的日记本引用规范 → 见 `07-Agent提示词工程.md`
