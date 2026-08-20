---
id: common-missing-state-case
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 修改或新增了一個判斷式，而該判斷式所依賴的欄位/旗標本質上有三種（或以上）可能值 — 例如「尚未執行過」vs「執行過且無異動」vs「執行過且有異動」、或「未設定」vs「設定為 A」vs「設定為 B」— 但新程式碼用 `if (flag)` / `!flag` 這種二分法處理，或用 `!== 某個閒置值` 的排除法代替列舉所有可能值；同樣要留意：當 diff 為某個既有旗標（如 noCheck、noEmit）新增了語意相近的判斷邏輯，卻只更新了其中一處判斷式（例如快取失效條件、diagnostics 重算條件），而程式裡另一個處理相同語意的判斷式沒有跟著涵蓋新狀態時。

## 判準
這類欄位的第三態通常代表「還沒發生」或「發生了但走的是另一條路徑」，二分法會把第三態誤併入其中一支，造成快取沒有被正確標記為過期、診斷沒有被正確重新計算、或狀態被誤判為已完成。這種缺陷在單元測試裡不容易被抓到，因為單獨測試兩個「乾淨」的狀態都會通過，只有在特定操作序列（例如先以某個 flag 跑過一次，再不帶該 flag 跑第二次）才會觸發，因此特別容易在 review 被漏掉，也是回測顯示 reviewer 最大的盲區。

## 嚴重度
CRITICAL：遺漏的第三態會讓 build/cache 產出的結果被下游當作可信但實際上是過期或不完整的（例如 incremental build info 沒有正確標記為 pending，導致下次建置漏掉語意層級的錯誤）。
HIGH：遺漏的第三態只在特定操作順序（先執行模式 A 再執行模式 B）下才會出錯，難以被單次獨立測試發現。
MEDIUM：遺漏的第三態只影響顯示或診斷訊息的一致性，不影響最終建置/執行結果的正確性。

## 反例（不該報）
- 文件或型別系統已明確保證該欄位只會有兩種值（例如第三態在更早的步驟已被 assert 或 normalize 排除），此時二分法沒有問題。
- 重構把多個獨立的 boolean 參數合併成一個更明確的 enum/union type（如把多個旗標收斂成 `TypePrintMode`），這是在消除模糊的二分法、增加狀態清晰度，方向相反，不該報。
- 三態雖然存在，但兩個分支對應的處理邏輯本來就相同（不管落在哪一支結果都一致），此時二分法只是程式碼精簡，不是遺漏。

## 出處
- https://github.com/microsoft/TypeScript/pull/61263#discussion_r1974209339
- https://github.com/microsoft/TypeScript/pull/58839#discussion_r1639039188
- https://github.com/microsoft/TypeScript/pull/58839#discussion_r1638984383
- https://github.com/microsoft/TypeScript/pull/57934#discussion_r1567928971
- https://github.com/microsoft/TypeScript/pull/57934#discussion_r1567789825
- https://github.com/microsoft/TypeScript/pull/50974#discussion_r981706113
- https://github.com/microsoft/TypeScript/pull/60122#discussion_r1786068330
