# 部署到 GitHub Pages

这里推荐把 `F:\kimicode\VCP知识站` 作为一个单独仓库推到 GitHub，然后用 GitHub Actions 自动部署 MkDocs 版知识站。

## 推荐方式：GitHub Actions

1. 在 GitHub 新建一个公开仓库，例如 `vcp-knowledge-site`。
2. 本地进入 `F:\kimicode\VCP知识站`。
3. 初始化并推送仓库：

```powershell
git init
git add .
git commit -m "init vcp knowledge site"
git branch -M main
git remote add origin https://github.com/<你的用户名>/vcp-knowledge-site.git
git push -u origin main
```

4. 打开 GitHub 仓库的 `Settings -> Pages`。
5. Source 选择 `GitHub Actions`。
6. 后续每次 push 到 `main`，工作流会自动构建并发布。

仓库根目录已经预留了 `.github/workflows/deploy-mkdocs.yml`，默认构建 `方案B-MkDocs-Material`。

## 开启留言区

留言区使用 Giscus，也就是 GitHub Discussions 驱动的评论系统。

前置条件：

- 仓库必须是公开仓库。
- 在仓库 `Settings -> Features` 里启用 Discussions。
- 安装 Giscus GitHub App。
- 到 `https://giscus.app/zh-CN` 生成配置。

然后修改 `方案B-MkDocs-Material/mkdocs.yml`：

```yaml
extra:
  giscus:
    enabled: true
    repo: "<你的用户名>/vcp-knowledge-site"
    repo_id: "<giscus 生成的 repo-id>"
    category: "General"
    category_id: "<giscus 生成的 category-id>"
```

## 手动部署方式

如果暂时不想用 GitHub Actions，也可以在 `方案B-MkDocs-Material` 目录下运行：

```powershell
python -m mkdocs gh-deploy
```

这个命令会构建站点，并把生成结果推送到 `gh-pages` 分支。运行前建议先执行：

```powershell
python -m mkdocs build --clean
```

确认本地构建没有错误。
