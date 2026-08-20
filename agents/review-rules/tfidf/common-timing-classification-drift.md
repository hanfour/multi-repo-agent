---
id: common-timing-classification-drift
layer: common
frameworks: ["react@*", "@tanstack/query-core@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中出現下列任一種型態：
- 重新命名或新增分類旗標（例如 `isCascadingUpdate` → `isPingedUpdate`、新增/改寫 `'Cascading Update'`、`'Update Blocked'`、`'Promise Resolved'` 這類文字標籤），且該標籤是靠比較兩個時間戳（`updateTime`、`renderStartTime`、`commitTime`）或簡單的計數（`commitCountInCurrentWorkLoop > 1`）來決定，而不是靠實際發生的事件邊界（render 中 vs. commit 後、effect 觸發 vs. render 中觸發）。
- 為重複執行的計時器/interval 新增「值沒變就不重設」的提前 return（例如 `if (prevInterval === current && timerId) return`），但沒有把「新資料到達」這類應該重新定錨（re-anchor）的事件納入判斷。
- 在畫面空間有限的地方（狀態列、trace label）新增一則新的警告/標籤，卻沒檢查它與既有警告的優先序或共存邏輯。
- 使用了瀏覽器 Performance API 較新的參數形式（如 `performance.measure` 的 options 物件、`detail`/`start`/`end`），卻沒有針對專案仍支援的舊環境做 feature-detect 或 polyfill。

## 判準
這類程式碼的共同陷阱是：分類/排程邏輯用的是「時間差」「次數」這種廉價 proxy，而不是真正定義該分類的事件本身，所以重構時很容易保留舊的分支結構、卻悄悄改變了分支背後的語意。測試通常不會覆蓋這種邊界（同一 tick 內連續呼叫、interval 因新資料而應提前重置的情境），所以問題要到 production 才會被發現——工程師看著錯誤命名的 trace label 追查效能問題會查錯方向，或是背景 interval 因為漏掉重新定錨而在錯誤的時間點打出多餘/延遲的請求。

## 嚴重度
CRITICAL：排程/interval 的重設邏輯被靜默改壞，導致所有使用者都會多打或延遲關鍵的背景請求（例如 refetch interval 沒有在新資料抵達時重新定錨，造成過早或過晚的重新抓取）。
HIGH：效能追蹤/診斷用的分類標籤語意錯誤（例如把「render 中的 setState」誤標為「cascading update」），會直接誤導工程師對效能問題的判斷方向，浪費真實的除錯時間。
MEDIUM：純命名/顯示層面的問題，例如標籤用了內部才懂的術語（"ping" 而非公開語彙）、或新警告與既有警告在有限空間裡的優先序沒有處理好。

## 反例（不該報）
- 單純為了顯示措辭而改標籤文字，底層的分類判斷邏輯完全沒變、且原本邏輯已驗證正確。
- 新增的時間戳比較只出現在 `__DEV__`/debug-only 的診斷路徑，不影響 production 行為。
- 呼叫點本身保證兩個事件永遠發生在同一個 tick／同一個同步區塊內，因此新增的時間比較不會產生任何可觀察差異。
- 使用的 API 特性在專案實際支援的瀏覽器矩陣中已全面支援，不需要 polyfill。

## 出處
- https://github.com/react/react/pull/34463#discussion_r3148348615
- https://github.com/react/react/pull/35672#discussion_r2756008936
- https://github.com/react/react/pull/34123#discussion_r2260503825
- https://github.com/react/react/pull/11480#discussion_r149372351
- https://github.com/TanStack/query/pull/8096#discussion_r1787341459
