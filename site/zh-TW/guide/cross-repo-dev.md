# 跨 Repo 開發

`mra` 的核心出發點：現代軟體散布在多個 repo，但 Claude 一次只看得到一個目錄。

## 問題

在 `my-api` 改了一個 API — 三個前端悄悄壞掉。你開三個 Claude session、每次重講 context、還得祈禱 reviewer 抓得到。

## mra 的解法

```bash
mra my-api --with-deps
```

這條指令會：

1. 載入 `my-api` 以及 `dep-graph.json` 中所有宣告的 consumer
2. 以共享的 context window 讓 Claude 一次看見所有相關 repo
3. 依相依順序派發 sub-agent 到各 repo 協調改動
4. 每次 commit 後跑 code review

## 相依偵測

5 個內建 scanner 自動推導圖形：

| Scanner | 偵測 | 可信度 |
|---------|------|-------|
| `docker-compose` | 服務關係 | 高 |
| `shared-db` | 共用資料庫的專案 | 高 |
| `gateway-routes` | API gateway 路由 | 中 |
| `shared-packages` | 內部 npm/gem 套件 | 高 |
| `api-calls` | 環境變數裡的 API host | 低 |

手動覆寫放在 `.collab/manual-deps.json`。

## 延伸閱讀

- [快速開始](/zh-TW/guide/getting-started)
- [指令總覽](/zh-TW/commands/)
