---
id: vue-event-handler-key-casing-mismatch
layer: vue
frameworks: ["vue@2.x", "vue@3.x", "@vue/runtime-core@*"]
severity_default: HIGH

---
## 觸發訊號
diff 在 `componentEmits.ts`（`emit()`／`isModelListener`／`propsOptions` 存在性檢查）、v-on 編譯輸出、或 `v-model` 參數/修飾符解析等處，新增或修改「事件名 → handler key / prop 是否已宣告 / modifiers 查找」的比對邏輯，且只用單一大小寫形式做比對——例如只 `event.startsWith('update:')` 取 kebab 原始字串、只 `camelize(event)`、或只 `toHandlerKey(event)` 而未同時涵蓋 `hyphenate`／精確符合（exact match）三種形式中的其他形式，或是新比對邏輯與程式碼裡既有的其他比對點（如 dev 警告訊息 vs 實際查找邏輯 vs `useModel`）用了不同的轉換方式。

## 判準
Vue 允許使用者以 kebab-case 或 camelCase 宣告 `props`／`emits`／`v-model` 參數與修飾符，模板編譯器、`emit()` 執行期查找、dev 模式「事件未宣告」警告、`v-model` modifiers 解析，這些是各自獨立的程式碼路徑，很容易只在其中一處統一轉換而漏掉別處。一旦有一處遺漏或不一致，就會出現兩種很難靠單元測試發現的問題：(1) 明明宣告了 prop/emit 卻在 runtime 查無 handler，事件靜默不觸發；(2) dev 模式對已正確宣告的事件誤報「未宣告」警告，並且警告文字建議的名稱寫法本身可能是錯的。因為大多數測試只固定用一種大小寫風格撰寫，這類 bug 很容易漏測。

## 嚴重度
CRITICAL：造成 runtime handler 完全沒被呼叫（例如 `modelArg`／`handlerName` 解析用錯 case 導致 `v-model` 或 `emit` 靜默失效），使用者互動無反應且無任何錯誤或警告可供排查。
HIGH：僅影響 dev 模式警告邏輯本身（誤判已宣告事件為「未宣告」，或漏判真正未宣告的事件），不影響 runtime 行為，但會誤導開發者做不必要或錯誤的修改。
MEDIUM：警告訊息文字建議了不正確或不一致的 prop/emit 命名寫法（例如提示未 camelize 過的名稱），使用者依提示修改後問題仍未解決。

## 反例（不該報）
- 新增/修改的呼叫點本身就是透過既有的共用工具函式（例如全專案統一經過 `toHandlerKey`／`camelize`／`hyphenate` 的單一入口）取值，沒有引入新的裸字串比較。
- 純框架內部保留事件名（不開放使用者自訂大小寫寫法）的比對邏輯調整。
- 只在 `*.spec.ts` 測試檔新增涵蓋不同大小寫情境的測試案例本身，而非產品程式碼的比對邏輯。
- 與大小寫轉換無關的效能或風格調整（例如把 `for` 迴圈改寫成 `forEach`、變數重新命名）。

## 出處
- https://github.com/vuejs/core/pull/8268#discussion_r1571767683
- https://github.com/vuejs/core/pull/4804#discussion_r1026231929
- https://github.com/vuejs/core/pull/4804#discussion_r736462241
- https://github.com/vuejs/core/pull/4804#discussion_r736461364
- https://github.com/vuejs/core/pull/9813#discussion_r1431201411
- https://github.com/vuejs/core/pull/9813#discussion_r1423304390
- https://github.com/vuejs/core/pull/9813#discussion_r1423304302
- https://github.com/vuejs/core/pull/4850#discussion_r1394422555
- https://github.com/vuejs/core/pull/4850#discussion_r1337608585
- https://github.com/vuejs/core/pull/12654#discussion_r2132060397
- https://github.com/vuejs/core/pull/12654#discussion_r1904863805
