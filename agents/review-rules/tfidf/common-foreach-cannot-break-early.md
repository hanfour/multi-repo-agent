---
id: common-foreach-cannot-break-early
layer: common
frameworks: ["javascript"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中出現使用 `Array.prototype.forEach`（或專案自製的 forEach-style 迭代 helper，例如 `forEach(collection, callback)`）走訪集合，且符合下列任一情況：
- callback 內寫了 `return`（或 `return () => {}`）想藉此中止後續迭代，但外層是 `forEach`。
- 迴圈本質是「找到符合條件的元素/累積條件不成立就該停」（如陣列逐項比較、first-match 搜尋），卻用 `forEach` 實作。
- 該處程式碼原本是 `for` / `for...of` / `.some()` / `.every()`，這次改動把它換成了 `forEach`。

## 判準
`Array.prototype.forEach` 及多數同名 helper 沒有辦法用 `return`/`break` 中止迭代——callback 的回傳值會被忽略，迴圈保證跑完整個集合。表面上看起來是「提早結束」的程式碼，實際上後面所有元素都還是會被處理。這會造成兩種問題：一是效能浪費（本可 O(1)/提前終止的操作變成固定 O(n)）；二是更嚴重的功能性錯誤——如果 callback 內含副作用（註冊 observer、觸發某個一次性動作、修改共用狀態），對「不該再處理」的後續元素仍然會被執行到，造成重複觸發或狀態污染。

## 嚴重度
CRITICAL：forEach 內的副作用會對不該處理的元素也執行，導致執行期正確性錯誤（例如已經處理過的項目仍持續被監聽/觸發，或比較結果被後面元素的迭代覆寫）。
HIGH：迴圈語意上是「找到符合條件就該停」，用 forEach 改寫後结果仍然正確，但在大集合或熱路徑（渲染、hydration、reactivity 追蹤）上造成不必要的完整遍歷。
MEDIUM：單純把可提早退出的 `.some()`/`for` 改成 `forEach`，目前資料量小、無明顯副作用風險，但破壞了「可中斷」的介面契約，資料量增長後容易變成效能或正確性問題。

## 反例（不該報）
- forEach 本身就是要無條件跑完全部元素（例如渲染所有子節點、清空所有 entry、對每個元素做互不影響且必須全部執行的操作），沒有提早退出的語意需求。
- 使用的是 `.some()` / `.every()` / `.find()` 本身，這些方法設計上就支援提早退出，只是外觀類似 forEach，不適用本規則。
- 改動方向是把 forEach 換成 for-of 或自製可 break 的迭代器（這是本規則建議的正確修法），不該被誤報為問題。

## 出處
- https://github.com/vuejs/core/pull/11639#discussion_r1756426473
- https://github.com/vuejs/core/pull/10664#discussion_r1556726239
- https://github.com/vuejs/core/pull/7676#discussion_r1101385674
