# 狀態與維運

觀察工作區、查詢程式碼、產生 CI,以及跨領域檢查。

```bash
mra status                     # 工作區總覽(各 repo 分支 / 狀態)
mra diff                       # 跨 repo diff 摘要
mra ask my-api "auth 在哪處理?"   # 透過 Claude 一次性查詢程式碼
mra lint --all                 # 跨 repo 檢查 JS/TS BLOCKER 規則
```

## 觀察

| 指令 | 用途 |
|------|------|
| `mra status` | 跨所有 repo 的工作區狀態總覽。 |
| `mra log [project]` | 檢視操作歷史(mra 動作稽核)。 |
| `mra diff` | 跨 repo diff 摘要。 |
| `mra cost [--reset]` | 顯示 Claude API 用量 / 成本;`--reset` 歸零計數。 |
| `mra dashboard` | 互動式終端機儀表板。 |

## 查詢與匯出

| 指令 | 用途 |
|------|------|
| `mra ask <project> "<question>"` | 透過 Claude 一次性查詢程式碼(非互動 session)。 |
| `mra export [project]` | 匯出專案 context 檔(供分享或外部工具)。 |

## 品質與自動化

| 指令 | 用途 |
|------|------|
| `mra lint <project\|--all>` | 檢查 JS/TS BLOCKER 規則。 |
| `mra ci <project> [--with-review]` | 產生 GitHub Actions workflow;`--with-review` 接入 mra review。 |
| `mra eval-review <project> --pr <N> [--baseline <file>] [--strategy S]` | 以人工 baseline 評分 AI review;報告存於 `.collab/eval/` 供趨勢追蹤。 |
| `mra notify [setup\|status\|test]` | 管理通知(設定、檢查、送測試)。 |
| `mra federation <subcommand>` | 多工作區契約管理(見 `mra federation --help`)。 |
