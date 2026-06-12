# mra analyze — 專案知識庫（PKB）

把一個專案蒸餾成可重複使用的知識文件，不必每個 session 都重讀整個 codebase。

```bash
mra analyze my-api               # generate
mra analyze my-api --model haiku # cheaper for module summaries
```

## 會產生什麼

| 文件 | 內容 |
|------|------|
| `identity.md` | 名稱、類型、一句話目的（約 50 tokens） |
| `sitemap.md` | 檔案樹 + 模組用途索引 |
| `architecture.md` | 設計模式、資料流、技術棧 |
| `conventions.md` | 程式碼風格、`[CONVENTION]`/`[PATTERN]`/`[DECISION]` 標籤 |
| `api-surface.md` | Endpoint、export、事件契約 |
| `tunnels.md` | 跨模組實體引用（自動偵測） |
| `modules/*.md` | 每個模組的深度摘要 |

## 4 層記憶堆疊

靈感來自 [mempalace](https://github.com/milla-jovovich/mempalace)。

| 層 | 內容 | Tokens | 載入時機 |
|----|------|--------|----------|
| L0 Identity | 名稱 + 類型 + 目的 | ~50 | 永遠 |
| L1 Essential | 帶標籤的慣例 + 模式 | ~200 | 永遠 |
| L2 Room Recall | Sitemap + 架構 + 相關模組 | ~500 | review/ask 時 |
| L3 Deep Search | 完整 API surface + 所有模組 | ~800+ | orchestrator 啟動時 |

**結果：** review 的喚醒成本從約 150K tokens 降到約 250。

## 自動更新

每次 review 之後：
- 有變動的模組會更新摘要（背景執行，用 haiku）
- 新檔案會更新 sitemap
- CRITICAL/HIGH 發現會以 `[DECISION]` 標籤收進 `conventions.md`
- Tunnel 連結重新生成

`mtime` 偵測會跳過未變動的模組。
