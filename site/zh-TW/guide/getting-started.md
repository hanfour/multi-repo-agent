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

## 下一步

- [跨 Repo 開發](/zh-TW/guide/cross-repo-dev)
- [Code Review](/zh-TW/commands/)
