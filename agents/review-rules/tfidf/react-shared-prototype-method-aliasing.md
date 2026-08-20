---
id: react-shared-prototype-method-aliasing
layer: react
frameworks: ["react@*"]
severity_default: HIGH
---
## 觸發訊號
- diff 中出現 `A.prototype.method = B.prototype.method = function(...) {...}` 這種把同一份函式實作同時指定給兩個不同 class（或 constructor）的 prototype 的寫法。
- diff 中出現 `Object.assign(Target.prototype, Source, {...})` 或 `assign({}, Source, {...})` 形式的 mixin 組合，其中 `Source` 是一個 class/constructor function 本身，而該 class 的方法實際定義在 `Source.prototype` 上。
- 新增一個與既有 class 行為相近的「姊妹」class（例如 `ReactAsyncComponent` 之於 `ReactComponent`）時，複製貼上既有 class 建構子裡的欄位初始化/方法邏輯，而不是透過 `extends`、共用 helper 或 mixin 明確表達「這兩者共享同一份行為」。

## 判準
- 把同一份實作直接 alias 給多個 class 的 prototype，等於假設這些 class 在該行為上的語意、生命週期完全相同。但常見情況是其中一個 class 多了一段狀態機（例如「hydration 尚未開始 vs 已開始才能呼叫」），導致該行為只在其中一支是安全的，另一支需要額外討論才能確認等價。
- `Object.assign` 的來源如果給錯（拿到 constructor function 本身而非 `.prototype`），會複製到一個幾乎空的物件，不會立即報錯，而是等到執行期呼叫該方法時才發現遺失 —— 屬於靠 review 才能攔下的靜態錯誤，測試也不一定覆蓋得到。
- 複製貼上建構子初始化程式碼而非透過繼承/共用 helper，會讓兩份程式碼日後各自漂移：其中一份修了 bug，另一份忘記同步，且此類 diff 很難靠 diff 本身看出「這是刻意重複還是漏改」。

## 嚴重度
CRITICAL：mixin/assign 的來源物件用錯（拿 class 本身而非 `.prototype`），導致目標方法完全遺失，只有在執行期呼叫時才會炸。
HIGH：把同一份行為 alias 給多個語意不完全相同的 class（例如同時掛在有/無額外狀態機的兩個 Root 變體上），且 PR 描述或討論中未確認過兩者行為等價、也未評估邊界情境（如已進入 hydration 中途）。
MEDIUM：新 class 複製貼上既有 class 的建構子初始化邏輯而非以繼承/共用 helper 表達，尚未造成可觀察 bug，但引入未來行為漂移風險。

## 反例（不該報）
- 兩個 class 的該方法本來就是純粹的 no-op 或完全對等的行為（例如都是單純 unmount/清理），且沒有任何狀態機差異 —— 不用報。
- `Object.assign` 的目的本來就是複製一般 plain object 的自身可列舉屬性（例如合併預設參數/選項物件），而不是要複製某個 class 的方法 —— 不用報。
- 使用 `class B extends A {}` 標準繼承語法，或呼叫明確命名的共用 helper 函式來初始化欄位 —— 這是規則想鼓勵的寫法，不是要抓的模式。

## 出處
- https://github.com/react/react/pull/18771#discussion_r422356908
- https://github.com/react/react/pull/18771#discussion_r422284002
- https://github.com/react/react/pull/10239#discussion_r128658587
- https://github.com/react/react/pull/7736#discussion_r79216143
