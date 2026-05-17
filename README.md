# VCP 知识站

> 生成日期：2026-05-17  
> 源资料目录：`F:\VCP\VCPToolBox\更新日志`  
> 目标：把 VCP 更新日志、源码解读、Agent 提示词演化资料整理成可浏览、可检索、可持续维护的知识站。

本目录包含两套可对比方案：

| 方案 | 目录 | 定位 | 推荐程度 |
|---|---|---|---|
| 方案 A | `方案A-Hugo-FixIt/` | 更接近 Cygnus Tech Blog，偏博客/专栏风格 | 适合公开展示 |
| 方案 B | `方案B-MkDocs-Material/` | 更像工程文档中心，偏项目手册/知识库 | 更推荐作为主力 |

## 我的建议

- 原始目录 `更新日志/` 不动，继续作为资料源。
- `VCP知识站/` 作为发布目录，所有内容都从资料源整理/复制而来。
- 先比较两套目录结构，再决定长期维护哪一种。
- 如果目标是给自己和 Agent 查资料，优先用 MkDocs Material。
- 如果目标是对外展示、写系列文章、沉淀公开博客，优先用 Hugo + FixIt。

## 当前样板包含

- VCP 新手阅读路线
- Agent 维护路线
- VCP 系统解读核心文档
- 更新日志入口
- Agent 提示词档案入口
- 审核与复盘入口

## 注意

当前机器尚未安装 Hugo / MkDocs。两个方案都已生成源码结构和配置文件；安装对应工具后即可预览。

## 部署与分享

- MkDocs 版已经预留 GitHub Pages 工作流：`.github/workflows/deploy-mkdocs.yml`
- 部署说明见：`方案B-MkDocs-Material/docs/deploy/github-pages.md`
- 留言区使用 Giscus 方案，先在 `mkdocs.yml` 的 `extra.giscus` 中保持关闭；等 GitHub 仓库、Discussions 和 Giscus 配好后再启用。
- 本地预览建议运行 `启动-MkDocs预览.ps1`。脚本会先构建静态站，再用 `http://127.0.0.1:8000/` 预览，效果更接近 GitHub Pages。
