---
id: rails-widened-type-or-value-acceptance
layer: rails
frameworks: ["rails@*", "activesupport@*", "activejob@*"]
severity_default: MEDIUM
---
## 觸發訊號
- diff 把 `case X when SpecificClass` 或 `is_a?(SpecificClass)` 改成更寬的父類別/模組（例如 `Integer` → `Numeric`、具體型別 → `Enumerable`），但沒有列出新型別集合裡實際會出現哪些成員（例如 `Numeric.subclasses` 含 `Complex`、`Rational`）。
- diff 在 case/when 或 symbol dispatch 新增一個接受值（例如新增 `:with_polynomial_backoff` 這個 algorithm symbol），但沒有同時保留舊值、deprecate 舊值，或處理呼叫端仍傳入舊值的相容性。
- diff 把某個 keyword 參數的預設值語意從「未傳入視為 sentinel」改成「可傳 `nil` 覆蓋 sentinel」（或反過來），尤其是像 `jitter: nil` 這種同時代表「用預設」和「明確關閉」兩種意圖的參數。
- diff 改寫判斷「集合是否為空／是否唯一一個元素」的邊界邏輯（例如把 `first(1) == []` 換成 enumerator + `StopIteration`、或用 `found` flag 判斷 `sole`），改變了 `nil` 元素是否算作「有元素」的語意。

## 判準
- 型別檢查放寬到共同父類別，常常只是為了少寫一個 `when`，但父類別的完整成員清單很少被實際檢查過，容易誤放行語意不合理的子型別（`Complex`、`Rational` 進入純數值 delay/金額運算會直接拋例外或給出無意義結果）。
- Rename 或新增 dispatch value 而不 deprecate 舊值，會讓下游還在用舊 symbol／舊型別的呼叫端悄悄失效或行為改變；這類 dispatch 通常是已發布的 public API（如 `retry_on` 的 `seconds_or_duration_or_algorithm:`），相容性要求高。
- kwarg 用 `nil` 同時表達「沒傳」與「明確傳 nil」，是常見的 nil-punning 陷阱，fallback 邏輯在有無明確傳值時行為不一致，呼叫端難以預期。
- 空集合／唯一元素判斷的邊界（`nil` 算不算一個元素）如果改變語意卻沒有對應測試涵蓋，會在下游依賴此行為的程式碼中製造細微 regression。

## 嚴重度
CRITICAL：型別放寬後，新放行的子型別在後續運算中會拋例外或造成資料錯誤（例如 delay/金額計算收到 `Complex`、`Rational`）。
HIGH：dispatch 新增值卻沒有相容舊值，導致既有呼叫端（尤其是已發布的 public API）行為改變或報錯；或 nil-punning kwarg 改變了現有呼叫端在未顯式傳值時的實際行為。
MEDIUM：空集合／`nil` 元素邊界判斷的語意改變，但已有測試涵蓋主要路徑、只是語意不夠直覺，或影響範圍侷限在內部私有方法。

## 反例（不該報）
- 型別放寬後，父類別所有實際子型別都已被呼叫端明確排除或有額外 guard clause 過濾（例如已加上檢查排除 `Complex`/`Rational`）。
- dispatch 新增值時舊值仍完整保留，且新增值與舊值語意互斥（不是 rename），純粹新增一個全新選項而未動舊選項的行為。
- kwarg 預設值改變只是把「隱含預設」寫成「顯式預設值常數」的純重構，呼叫端在未傳值時的實際行為完全不變，未引入 nil 覆蓋語意。
- 空集合／唯一元素判斷的重寫有對應測試（涵蓋 `nil` 元素、空集合、單一元素三種案例）同步更新並驗證新語意正確。

## 出處
- https://github.com/rails/rails/pull/57727#discussion_r3420741025
- https://github.com/rails/rails/pull/49292#discussion_r1327645638
- https://github.com/rails/rails/pull/48720#discussion_r1269735541
- https://github.com/rails/rails/pull/40914#discussion_r615769175
- https://github.com/rails/rails/pull/40914#discussion_r613866052
- https://github.com/rails/rails/pull/39697#discussion_r443600025
- https://github.com/rails/rails/pull/38545#discussion_r388077883
- https://github.com/rails/rails/pull/37923#discussion_r357436613
- https://github.com/rails/rails/pull/20556#discussion_r32660668
