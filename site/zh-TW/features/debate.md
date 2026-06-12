# Mailbox 投票辯論

`mra review` 預設的 debate 策略如何收斂出高精準度的發現。

## 第 1 輪 — 獨立分析

兩個 agent 以各自獨立的 context 平行執行：

- **Agent A（Impact Analyst）** — grep codebase 找壞掉的引用、死程式碼、API 破壞
- **Agent B（Quality Auditor）** — 檢查設計模式、安全性、edge case

## 第 2 輪 — mailbox 投票

兩邊的發現池合併後統一編號。每個 agent 對每一條編號的發現投 KEEP / DROP。只有獲得雙方淨正向票數的發現才能存活。

## 最終 — 綜整

綜整器接收存活的發現、去除重複，輸出結構化 JSON，供終端機輸出或 PR inline comment 使用。

## Token 最佳化

- 模型分層 — 投票用 Haiku，分析用 Sonnet
- 聚焦 context — 非搜尋回合用 `--add-file` 而非 `--add-dir`
- 快速收斂 — 發現為 0 或少於 5 條時跳過辯論
- PKB 整合 — 用知識文件取代載入整個 codebase
- 精簡 prompt — review 準則在各回合間維持 DRY

## 與 `--personas` 的比較

| 模式 | Agents | 成本 | 時機 |
|------|--------|------|------|
| Debate | 2 位通用 + 2 位投票者 | 較低 | 預設 |
| Personas | 5 位具名專家 | 較高 | 安全關鍵或跨 repo |

兩者收斂到同一種 JSON 格式 — PR inline comment 的運作完全相同。
