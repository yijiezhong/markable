# 发布到 GitHub

本仓库的公开版本通过**脱敏快照**发布：本地开发历史（含内部交接日志）留在私有仓库，
GitHub 上只放清理后的代码与文档。

## 1. 生成快照

```bash
scripts/export-github.sh            # 默认输出 dist/github/
```

脚本会：

1. 用 `git archive HEAD` 导出**已提交**的文件（不含 `.git`、未提交改动）；
2. 剔除内部文件：`HANDOVER.md`（含内网地址的交接日志）、`samples/deepseek-logo.png`（第三方商标）；
3. 校验快照中不含内网地址、本机路径与用户名，命中即失败；
4. 检查 `README.md` / `LICENSE` / `THIRD-PARTY-NOTICES.md` / `Package.swift` 是否存在。

## 2. 推送到 GitHub

```bash
cd dist/github
git init -b main
git add -A
git commit -m "Markable 1.5.2"
git remote add origin git@github.com:<账号>/<仓库>.git
git push -u origin main
```

## 3. 打标签与发布包

```bash
git tag -a v1.5.2 -m "Markable 1.5.2"
git push origin v1.5.2
```

发布包由 `scripts/make-app-bundle.sh --release --zip` 生成（`dist/Markable-<版本>.zip`），
在 GitHub Release 里附上该 zip，并粘贴 `CHANGELOG.md` 对应段落。

## 4. 每次更新的流程

```bash
# 1) 本地改完、测试通过、提交
swift test && scripts/lint.sh --strict
git commit -am "Markable x.y.z：…"

# 2) 重新生成脱敏快照（覆盖）
scripts/export-github.sh

# 3) 在快照仓库里同步
cd dist/github
git add -A && git commit -m "Markable x.y.z" && git push

# 4) 打 tag + Release（附 zip）
```

> 不要直接把开发仓库的完整历史推到 GitHub：历史提交里的 `HANDOVER.md` 旧版本含内网地址。
