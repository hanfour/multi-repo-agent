---
id: common-swallowed-error-in-async-cleanup
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現「操作失敗 → 執行非同步清理（rollback/commit/release/close）」的路徑，且符合下列任一形態：
- `try { await op() } finally { await cleanup() }`，其中 `cleanup()`（如 `tx.rollback()`、`tx.commit()`、connection release）本身可能 reject，且沒有把原始錯誤保留下來（沒有 `{ cause: err }`、沒有用 `Promise.allSettled`/顯式 `finally(() => throw err)` 模式）
- `.then(onFulfilled, async (err) => { await cleanup(); throw err })` 這種鏈式寫法，但 `cleanup()` reject 時會直接把新錯誤丟出去，蓋掉外層的 `err`
- 對多個獨立資源做批次清理（例如「rollback 所有還開著的 transaction」「關閉所有連線」）時用 `Promise.all(items.map(cleanup))`，而不是 `Promise.allSettled`
- cleanup 失敗被 `.catch(() => {})` 或只 `debug(err)` 吞掉，而該 cleanup 動作本身承載資料一致性語意（不是單純 best-effort 收尾）

## 判準
失敗操作本身的錯誤，才是呼叫端/使用者真正需要知道的診斷訊號；如果收尾動作（rollback/commit/release）失敗時把它的錯誤直接蓋過原始錯誤，等於把最有意義的錯誤資訊丟掉，留下一個誤導性的次要錯誤。更嚴重的是：用 `Promise.all` 對多個獨立資源做清理時，只要其中一個 reject，其餘資源的清理就不會執行——對「on shutdown 把所有 transaction rollback 掉」這種語意來說，代表其他 transaction 會直接洩漏、連線池被占滿卻沒人發現，而且看起來程式碼「有處理清理」，實際上只清了一部分。

## 嚴重度
CRITICAL：清理涉及多個獨立資源（例如逐一 rollback 所有 outstanding transaction、逐一釋放連線池成員），用 `Promise.all` 導致單一失敗擋住其餘資源的清理，造成連線洩漏或多筆交易未回滾。
HIGH：單一資源的收尾動作（rollback/commit）失敗時，直接取代或蓋掉原始操作的錯誤，讓呼叫端/log 看到的不是真正失敗原因。
MEDIUM：收尾失敗被靜默吞掉（`.catch(() => {})` 且無任何 log），但該收尾動作本身涉及狀態一致性（不是單純 best-effort）。

## 反例（不該報）
- 主要操作已經成功並回報給呼叫端之後，才做的真正 best-effort 收尾（例如關閉測試用的輔助 process、debug socket），失敗與否不影響資料正確性，用 `.catch(() => {})` 是合理的。
- 清理失敗確實有被保留：新錯誤把原始錯誤放進 `{ cause: err }`，或明確 log 兩者、或用 `Promise.allSettled` 收集所有結果後再統一處理——這是正確作法，不是缺陷。
- 只有單一資源、沒有 fan-out 的情況，直接 `await cleanup()` 而非 `Promise.all([cleanup()])`，沒有並行清理的需求，不適用本規則。

## 出處
- https://github.com/prisma/prisma/pull/28468#discussion_r2504898447
- https://github.com/prisma/prisma/pull/28468#discussion_r2504615567
- https://github.com/prisma/prisma/pull/28468#discussion_r2504550826
- https://github.com/prisma/prisma/pull/26276#discussion_r1946838691
- https://github.com/prisma/prisma/pull/28492#discussion_r2508173689
