---
id: nestjs-cache-invalidation-stale-derived-artifacts
layer: nestjs
frameworks: ["typescript@*", "@prisma/client@*", "esbuild@*"]
severity_default: CRITICAL

---
## 觸發訊號

diff 中出現下列任一種變更時，要去確認對應的下游衍生物是否也被同步更新／重新產生／失效：

- 修改了 schema、contract、型別定義、API 形狀、或 generator 的來源檔案 → 檢查是否有對應的「已產生」檔案（`*.d.ts`、fixture、snapshot、codegen 輸出）沒有被重新 emit，導致舊產物繼續存在於 repo 或 CI 產物中。
- 新增或修改了任何以 `Map`/`WeakMap`/模組層變數做 memoization 或快取的邏輯（build 快取、compile 快取、descriptor 快取）→ 檢查快取的 key/scope 是否涵蓋所有會使其失效的輸入（例如同一 key 在不同來源檔案間被重用、或快取跨越多次呼叫未依 invocation/build 重新建立）。
- 修改了「用版本號/commit 比對來決定是否重新下載或重新產生」的邏輯（例如 binary 下載、engine 版本檢查）→ 檢查比對條件在版本升級、平台切換、或版本字串格式改變時是否仍然正確觸發失效。
- 修改了被其他檔案（README、ADR、SKILL.md、測試名稱、註解）以具體事實（symbol 名稱、數量、行為描述、API 存在與否）引用的程式碼或設定 → 檢查那些引用處是否也一併更新，尤其當該符號被刪除、改名、或行為改變時。
- 新增/移除了套件、匯出、或 API 後 → 全域搜尋是否還有文件、註解、或測試假設舊 API 仍存在（而非只改動當下這個檔案裡看得到的地方）。

## 判準

這類問題的共通點是「衍生物看起來沒壞，但已經跟來源真相脫鉤」：CI 可能是綠的（因為衍生的 `.d.ts`/快取/文件從未被要求重新驗證），但實際執行時型別、行為、或說明文字已經對不上最新的來源。這比「這行寫錯了」更危險，因為它不會在當下這次變更就爆炸，而是在下一個依賴這份衍生物的人身上炸——例如引用了過期型別而寫出看似合法但執行期會錯的程式碼，或依照過期文件操作而選錯步驟。resenior reviewer 會特別注意的是：只改了來源、卻沒有連帶掃過「誰在消費這個來源產生的衍生物」，因為這通常需要跨檔案搜尋才會發現，不會出現在當前 diff 的可見範圍內。

## 嚴重度
CRITICAL：衍生物直接影響執行期正確性——例如記憶化的 build/compile 快取在同一 process 中被跨呼叫重用、未依來源變動重新編譯，導致產出裝進發布產物的程式碼是舊的；或下載/版本比對邏輯本身判斷錯誤，導致該裝新版卻沿用舊 binary。
HIGH：衍生物影響型別安全或測試正確性但尚未直接進到執行期輸出——例如 generated `.d.ts`/fixture 沒有跟著來源 contract 重新 emit，導致靜態型別與實際 runtime 回傳值不一致，測試斷言其實是在斷言一個錯誤的型別。
MEDIUM：衍生物是文件、註解、ADR、測試名稱等說明性內容，引用了已經改變或刪除的具體事實（symbol 名稱、數量、API 存在性），會誤導後續開發者但不影響執行期行為。

## 反例（不該報）
- diff 已經把來源變更與對應的衍生物更新（重新 emit 的 fixture、同步修改的文件）一起包進同一個 PR——這正是應該做的事，不是漏做。
- 快取有明確設計的 TTL、手動刷新機制、或已知的過期容忍策略，且該策略本身沒有被這次 diff 破壞——不是「忘記失效」，是刻意設計。
- 被引用的事實本身沒有隨這次變更改變（例如只是格式調整、重新排版，內容語意不變），沒有任何下游衍生物需要跟著動。
- 純粹新增獨立、無人依賴其具體事實的檔案或模組，沒有任何現存的生成物/文件/快取指向它。

## 出處
- https://github.com/nestjs/nest/pull/12218#discussion_r1293053482
- https://github.com/prisma/prisma/pull/29997#discussion_r3767170268
- https://github.com/prisma/prisma/pull/29930#discussion_r3740024845
- https://github.com/prisma/prisma/pull/29918#discussion_r3735228024
- https://github.com/prisma/prisma/pull/29912#discussion_r3734402450
- https://github.com/prisma/prisma/pull/29912#discussion_r3734392857
- https://github.com/prisma/prisma/pull/29864#discussion_r3702914933
- https://github.com/prisma/prisma/pull/29864#discussion_r3702913594
- https://github.com/prisma/prisma/pull/29864#discussion_r3702913362
- https://github.com/prisma/prisma/pull/29844#discussion_r3683586655
- https://github.com/prisma/prisma/pull/29844#discussion_r3682835784
- https://github.com/prisma/prisma/pull/29315#discussion_r3644139252
- https://github.com/prisma/prisma/pull/28028#discussion_r3623557259
- https://github.com/prisma/prisma/pull/29619#discussion_r3348936718
- https://github.com/prisma/prisma/pull/28455#discussion_r2498646507
- https://github.com/prisma/prisma/pull/14645#discussion_r939440014
- https://github.com/prisma/prisma/pull/13868#discussion_r901471480
- https://github.com/prisma/prisma/pull/12271#discussion_r826856038
