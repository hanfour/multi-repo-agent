---
id: common-unguarded-default-behavior-change-in-snapshot
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 修改了 snapshot/golden file 或其他自動產生的測試輸出，其中某個「預設值」欄位在沒有相關程式碼邏輯變更說明的情況下被改動（例如 `"relationOnDelete": "NONE"` → `"Cascade"`），且該欄位對應的功能在 PR 描述或程式碼中標示為 preview feature / 未預設啟用 / 尚未 GA。同時 diff 中看不到任何 feature flag、config 判斷或條件式 gate 保護這個新預設值。

## 判準
Snapshot 測試的價值在於偵測「非預期的行為變化」；當一個標示為 preview/opt-in 的功能改動，卻悄悄改變了所有使用者共用路徑的預設輸出，代表該功能實際上沒有被正確 gate，會在使用者不知情、未主動選用該功能的情況下影響到 production 行為。Reviewer 看到這種 snapshot diff 時必須先確認：這個值的改變是否只發生在 preview flag 開啟時；如果 flag 關閉時仍然改變，就是一個會外溢到既有使用者的破壞性變更，必須在合併前查清楚原因，而不是視為測試更新照過。

## 嚴重度
CRITICAL：該預設值變更會直接改變 production 資料行為（如 cascade delete、權限、金額計算等有副作用/不可逆的操作），且未被任何 flag 保護。
HIGH：確認 preview flag 未啟用時 snapshot 仍然改變，但影響範圍是唯讀輸出或可回復的行為（如產生的 schema/DSL 文字、回傳格式）。
MEDIUM：不確定變更是否受 flag 保護，需要作者澄清用途與觸發條件，但看起來屬於低風險欄位（如格式化、命名）。

## 反例（不該報）
- Snapshot 變更明確對應到 PR 中新增的 feature flag 判斷式，且該 flag 預設為關閉（即未啟用時走原本邏輯，可驗證）。
- 純粹新增測試案例、新增 snapshot 檔案，而非既有 snapshot 的既有欄位值被改動。
- 變更欄位是純粹的內部識別碼、時間戳、或明確標示為 non-semantic 的測試 fixture，不影響任何對外行為。
- 這是一次性的、明確在 commit message/PR 描述中說明「刻意調整預設值並升版本」的 breaking change，且已走過對應的 deprecation/公告流程。

## 出處
- https://github.com/prisma/prisma/pull/7796#discussion_r657112617
- https://github.com/prisma/prisma/pull/7796#discussion_r657095951
