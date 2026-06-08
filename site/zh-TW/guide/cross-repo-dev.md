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

## 跨 repo 出貨

當改動橫跨多個 repo，branch-aware 指令會依相依順序一起搬動它們：

```bash
mra branch new feature/login    # 在每個 repo 建立同一條分支
# ...各 repo 開發、commit...
mra sync --safe                 # 把所有 repo pull 到最新
mra branch status               # 一眼看 ahead/behind/dirty/PR 狀態
mra branch pr                   # push 分支 + 開 PR（上游先）
mra branch merge --wait-ci      # 每個 PR 等 CI 綠燈後合併
```

`branch pr` 與 `branch merge` 都接受 `[repos…]` 子集，`merge` 以 mergeable + CI 狀態為門檻。詳見 [`mra branch`](/zh-TW/commands/branch) 與 [`mra sync`](/zh-TW/commands/sync)。

## 延伸閱讀

- [快速開始](/zh-TW/guide/getting-started)
- [分支感知同步與 PR](/zh-TW/commands/branch)
- [指令總覽](/zh-TW/commands/)
