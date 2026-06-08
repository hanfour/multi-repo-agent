# 快速開始

## 前置需求

| 工具 | 安裝方式 |
|------|---------|
| `git` | macOS 內建 |
| `docker` | [Docker Desktop](https://docker.com) 或 [OrbStack](https://orbstack.dev) |
| `jq` | `brew install jq` |
| `gh` | `brew install gh` 後執行 `gh auth login` |
| `claude` | [claude.ai/code](https://claude.ai/code) |

## 安裝

```bash
git clone https://github.com/hanfour/multi-repo-agent.git ~/multi-repo-agent
cd ~/multi-repo-agent && bash install.sh && source ~/.zshrc
```

## 初始化工作區

```bash
mra init ~/workspace --git-org git@github.com:my-org
```

這會 clone `repos.json` 列出的 repo、掃描 docker-compose 服務關係、偵測相依關係。

## 驗證環境

```bash
mra doctor
```

## 第一次使用

```bash
mra my-api --with-deps
```

Claude 啟動時會把 `my-api` 以及所有使用它的 consumer repo 都載入 context。

## 跨 Repo 同步與出貨

```bash
mra sync --safe          # fast-forward pull 每個 repo
mra branch status        # 哪些 repo 需要注意
mra branch pr            # push 分支 + 開 PR（相依先）
mra branch merge --wait-ci   # 每個 PR 等 CI 綠燈後合併
```

完整流程見 [`mra sync`](/zh-TW/commands/sync) 與 [`mra branch`](/zh-TW/commands/branch)。

## 下一步

- [跨 Repo 開發](/zh-TW/guide/cross-repo-dev)
- [分支感知同步與 PR](/zh-TW/commands/branch)
- [Code Review](/zh-TW/commands/)
