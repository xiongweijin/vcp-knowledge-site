# 部署到 GitHub Pages

网站地址是 `https://xiongweijin.github.io/`，由两个仓库配合完成：

| 仓库 | 作用 |
|---|---|
| `xiongweijin/vcp-knowledge-site` | 源码：Markdown 文章和 `mkdocs.yml` |
| `xiongweijin/xiongweijin.github.io` | 成品：构建好的网页，GitHub Pages 从它的 `main` 分支根目录发布 |

## 发布步骤

1. 在源码仓库改好文章，提交并推送：

```powershell
git add .
git commit -m "更新文章"
git push origin main
```

2. 在 `方案B-MkDocs-Material` 目录下构建并发布到主页仓库：

```powershell
python -m pip install -r requirements.txt
python -m mkdocs gh-deploy --force --clean --remote-name homepage --remote-branch main
```

`homepage` 是指向 `https://github.com/xiongweijin/xiongweijin.github.io.git` 的 git remote。第一次使用前需要添加：

```powershell
git remote add homepage https://github.com/xiongweijin/xiongweijin.github.io.git
```

## 自动构建检查

源码仓库的 `.github/workflows/build-check.yml` 会在每次推送后自动构建一遍网站，只检查有没有出错，不会发布。如果它变红，说明这次修改让网站构建失败了，先修好再发布。

## 留言区

留言区使用 Giscus（GitHub Discussions 驱动），配置在 `mkdocs.yml` 的 `extra.giscus`，由 `docs/javascripts/giscus.js` 注入到每篇文章底部。留言保存在源码仓库的 Discussions 里。
