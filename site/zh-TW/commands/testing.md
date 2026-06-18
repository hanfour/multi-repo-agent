# 測試與 Docker

在隔離的 Docker 環境跑測試、監看變更、管理資料庫。專案在 mra 執行其容器前,須先 **trust** 一次。

```bash
mra trust my-api               # 授權 Docker(每專案一次)
mra db setup                   # 啟動 DB 容器並匯入 dump
mra test my-api                # 跑測試(自動偵測策略)
mra watch my-api               # 檔案變更時自動重跑測試
```

## 指令

| 指令 | 用途 |
|------|------|
| `mra trust <project>` | 授權專案的 Docker 信任;記錄於 `.collab/trusted-projects.json`。執行其容器前必做。 |
| `mra db [setup\|status\|import]` | 管理資料庫:`setup` 啟動容器並匯入 dump、`status` 顯示狀態、`import` 載入 dump。 |
| `mra test <project> [--integration\|--mock]` | 在 Docker 跑專案測試。`--integration` 跑整合測試;`--mock` 用 mock 相依。 |
| `mra watch <project\|--all>` | 監看檔案,變更時自動跑測試。 |

## 資料庫 dump

把 dump 檔放在 `<workspace>/dumps/`(例如 `myapp_db.sql.bz2`);`mra db setup` 會匯入啟動的容器。dump 設定在 `<workspace>/.collab/db.json`。

::: tip
`trust` 是刻意的安全閘門 —— 未明確 trust 前,mra 不會執行專案的 Docker 容器。理由見 repo 的 threat model。
:::
