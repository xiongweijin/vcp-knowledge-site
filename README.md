# 熊的 AI 项目札记 · 源码仓库

这是个人网站 **https://xiongweijin.github.io/** 的源码。网站用 [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) 构建，内容是学习 AI 与 GitHub 开源项目的记录，目前主要是「01-VCP 系统解读」。

| 仓库 | 放什么 |
|---|---|
| `vcp-knowledge-site`（本仓库） | Markdown 原稿、站点配置 —— **改文章在这里改** |
| [`xiongweijin.github.io`](https://github.com/xiongweijin/xiongweijin.github.io) | 构建出来的网页，由部署命令自动覆盖，不要手动改 |

## 目录

| 路径 | 作用 |
|---|---|
| `方案B-MkDocs-Material/mkdocs.yml` | 站点配置：标题、导航、主题、Giscus 留言区 |
| `方案B-MkDocs-Material/docs/` | 所有文章（Markdown）、样式和脚本 |
| `方案B-MkDocs-Material/requirements.txt` | 构建所需的 Python 依赖 |
| `.github/workflows/build-check.yml` | 每次推送自动检查网站能否正常构建（只检查，不发布） |
| `AGENTS.md` | 给 AI 助手看的交接说明（部署步骤、踩过的坑） |
| `两种方案对比.md`、`对比预览.html`、`启动-Hugo预览.ps1` | 早期 Hugo 与 MkDocs 方案对比的历史资料。方案 A（Hugo）只保留在本地，未上传 |

## 常用命令

在 `方案B-MkDocs-Material` 目录下：

```powershell
# 安装依赖（第一次）
python -m pip install -r requirements.txt

# 本地预览，浏览器打开 http://127.0.0.1:8000/
python -m mkdocs serve

# 发布到 https://xiongweijin.github.io/
python -m mkdocs gh-deploy --force --clean --remote-name homepage --remote-branch main
```

`homepage` 是指向 `xiongweijin.github.io` 仓库的 git remote，详见 `AGENTS.md`。中文路径导致本地预览异常时，可以用 `启动-MkDocs预览.ps1`。
