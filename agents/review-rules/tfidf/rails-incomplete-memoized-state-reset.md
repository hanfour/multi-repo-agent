---
id: rails-incomplete-memoized-state-reset
layer: rails
frameworks: ["rails@>=5.0"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中修改了具備「重置全部衍生狀態」語意的方法（例如 `CollectionProxy#reset`、`#reload`、或任何清除 memoized/cache 的方法），且該次改動新增了一個新的快取用 instance variable（如 `@offsets`）卻沒有把它一併加進既有的 reset/reload 方法；或者反過來，reset 方法本身被修改，但只涵蓋了部分快取欄位。

## 判準
`reset`/`reload` 這類方法對呼叫端的隱含契約是「呼叫後所有衍生/快取狀態都視為未計算，下次存取會重新計算」。只清除部分欄位會讓呼叫端誤以為狀態已完全重置，但其實舊的快取值仍殘留，之後被讀到就是難以追蹤的 stale data bug。這種遺漏特別容易發生在後續開發者新增一個新的快取欄位時——因為 reset 方法通常宣告在檔案的另一處，離新欄位很遠，容易忘記同步更新。

## 嚴重度
CRITICAL：殘留的舊快取值會被寫回資料庫、或直接影響金額／權限判斷等資料正確性
HIGH：reset 後讀到錯誤的筆數／物件（例如 offset-based 分頁快取沒被清除，導致下一頁筆數算錯或重複）
MEDIUM：遺漏的快取只影響效能（該重新計算卻沿用舊值，但輸出本身不受影響），或只在少數呼叫路徑才會觸發

## 反例（不該報）
- 新增欄位是在建構子中賦值、沒有獨立的 setter 或 lazy-load 路徑，本來就不需要被 reset 清除
- reset 方法本來就明確只負責重置某一個子系統的職責（例如 `reset_scope` 只重置 scope、不負責清 association 快取），呼叫端另有專責方法負責清另一部分，職責分離是刻意設計
- 新增欄位在下一次讀取路徑中必定會被重新賦值覆蓋（例如每次呼叫前都先 `@offsets ||= {}` 後立即整批覆寫），不存在讀到舊值的路徑

## 出處
- https://github.com/rails/rails/pull/56350#discussion_r2615453582
- https://github.com/rails/rails/pull/40592#discussion_r523463350
- https://github.com/rails/rails/pull/33829#discussion_r216880151
- https://github.com/rails/rails/pull/29511#discussion_r123357452
- https://github.com/rails/rails/pull/15608#discussion_r13595884
