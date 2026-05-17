# VCP 知识站交接说明

> 本文件用于新窗口或新 Agent 快速接手当前项目。

## 项目定位

这是一个个人学习型博客站，当前部署在 GitHub Pages 根域名：

- 线上地址：https://xiongweijin.github.io/
- 个人主页仓库：https://github.com/xiongweijin/xiongweijin.github.io
- 源码仓库：https://github.com/xiongweijin/vcp-knowledge-site

站点主题参考：https://cygnusyang.github.io/

用户想要的是“个人项目记录站”，不是单纯技术文档站。结构目标：

- 顶部导航：`研究项目`、`关于熊`
- 左侧：所有文章/项目目录，可展开收起
- 中间：文章正文
- 右侧：当前文章目录
- 评论区：使用 Giscus，当前已经可留言

## 当前目录结构

工作目录：

```text
F:\kimicode\VCP知识站
```

主要实现目录：

```text
F:\kimicode\VCP知识站\方案B-MkDocs-Material
```

重要文件：

- `方案B-MkDocs-Material/mkdocs.yml`：站点配置、导航、GitHub Pages URL、Giscus 配置
- `方案B-MkDocs-Material/docs/index.md`：首页“研究项目”
- `方案B-MkDocs-Material/docs/about.md`：关于熊
- `方案B-MkDocs-Material/docs/stylesheets/extra.css`：自定义样式
- `方案B-MkDocs-Material/docs/javascripts/giscus.js`：留言区注入脚本
- `方案B-MkDocs-Material/docs/vcp-system/`：当前主要项目文章

## 当前站点状态

已经完成：

- MkDocs Material 方案作为正式方案
- 首页改为“研究项目”
- 顶部导航包含 `研究项目`、`关于熊`
- 首页只展示一个项目：`01-VCP 系统解读`
- `关于熊` 页面已写入用户背景和联系方式
- Giscus 评论已配置并可用
- 已发布到 `https://xiongweijin.github.io/`

当前主要内容：

```text
01-VCP 系统解读
技术文档与源码导读
```

## 用户背景与关于页信息

关于页核心描述：

- 用户昵称：熊
- 身份：学习 AI 和 GitHub 开源项目的体外诊断试剂研发工程师
- 博客用途：记录学习 AI、GitHub 项目、开源工具、工程化工作流和个人知识管理的过程
- GitHub：https://github.com/xiongweijin
- Email：1091104795@qq.com

## 本地构建

进入 MkDocs 项目目录：

```powershell
cd F:\kimicode\VCP知识站\方案B-MkDocs-Material
python -m mkdocs build --clean
```

本地预览可用：

```powershell
python -m mkdocs serve
```

如果中文路径导致本地服务异常，可以用已有的 junction：

```text
F:\kimicode\vcp-knowledge-mkdocs
```

或先构建再静态预览：

```powershell
python -m mkdocs build --clean
python -m http.server 8000 --bind 127.0.0.1 --directory F:\kimicode\vcp-knowledge-mkdocs\site
```

## 部署方式

源码推送到当前仓库：

```powershell
cd F:\kimicode\VCP知识站
git push origin main
```

发布到根域名仓库：

```powershell
cd F:\kimicode\VCP知识站\方案B-MkDocs-Material
python -m mkdocs gh-deploy --force --clean --remote-name homepage --remote-branch main
```

当前 Git remote：

- `origin` -> `https://github.com/xiongweijin/vcp-knowledge-site.git`
- `homepage` -> `https://github.com/xiongweijin/xiongweijin.github.io.git`

注意：`mkdocs gh-deploy` 可能会临时把当前工作树切成发布状态。部署后建议回到源码仓库根目录检查：

```powershell
cd F:\kimicode\VCP知识站
git status --short
git branch --show-current
```

如果工作树被发布产物污染，且确认源码已推送到 `origin/main`，可恢复：

```powershell
git reset --hard origin/main
```

只在确认无未保存源码改动时使用。

## 验证线上

发布后检查：

```powershell
Invoke-WebRequest -Uri https://xiongweijin.github.io/ -UseBasicParsing
Invoke-WebRequest -Uri https://xiongweijin.github.io/about/ -UseBasicParsing
Invoke-WebRequest -Uri https://xiongweijin.github.io/vcp-system/01-system-overview/ -UseBasicParsing
```

应能看到：

- 首页包含 `熊的 AI 项目札记`
- 首页包含 `研究项目`
- 关于页包含 `1091104795@qq.com`
- 文章页包含 `javascripts/giscus.js`

## 已踩过的坑

1. `https://xiongweijin.github.io/vcp-knowledge-site/` 是项目页，不是最终想要的根域名。
2. 根域名必须使用仓库 `xiongweijin.github.io`。
3. 新建 `xiongweijin.github.io` 仓库后，需要启用 GitHub Pages：`main /`。
4. `mkdocs gh-deploy` 对用户主页仓库会提示类似 `https://xiongweijin.github.io/xiongweijin.github.io/`，这个提示可以忽略；真实线上地址是 `https://xiongweijin.github.io/`。
5. PowerShell 读取中文文件时可能显示乱码，但文件本身是 UTF-8。用 Python `Path(...).read_text(encoding="utf-8")` 检查更可靠。
6. `navigation.expand` 已去掉，让左侧目录更接近可展开/收起。
7. 评论区不是模板 override，而是通过 `docs/javascripts/giscus.js` 注入。

## 后续建议

如果继续优化，优先做这些：

1. 把 `01-VCP 系统解读` 的章节标题整理成更像博客文章标题。
2. 首页逐步增加新的研究项目卡片，例如 OpenClaw、Claude Code、MCP、Codex 等。
3. 给每个研究项目建立独立目录，保持左侧文章树清晰。
4. 给关于页加一张轻量头像或个人标识，但不要做成营销落地页。
5. 如果继续参考 Cygnus 风格，重点参考信息架构和阅读体验，不要照搬内容。
