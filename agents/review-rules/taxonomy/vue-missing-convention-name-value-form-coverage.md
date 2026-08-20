---
id: vue-missing-convention-name-value-form-coverage
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: HIGH
---
## 觸發訊號
當 diff 修改了「判斷某個名稱或值屬於哪一種等價形式」的邏輯時，要去確認涵蓋範圍是否完整。具體包括：
- prop/event/model 參數名稱的 camelCase ↔ kebab-case 轉換規則（如 `camelize`/`hyphenate`、`toHandlerKey` 的比對條件）
- component/prop 名稱合法字元集的正則（如 `validateComponentName` 擴充字元集）
- attribute/prop 值的型別或真假值判斷分支（如 boolean attribute 的字串值、`trueValue`/`falseValue`、CSS var 值型別）
- 物件目標型別偵測（如 `getTargetType`/`targetTypeMap` 判斷是否為 plain object 或可觀察對象）

要去檢查：新邏輯是否仍涵蓋該名稱/值原本支援的「所有等價表示法」與邊界值（exact match、camelCase、kebab-case、空字串、`undefined`、擴充字元集、繼承/子類別覆寫內建行為等），還是只處理了作者當下想到、測試到的那一種。

## 判準
這類程式碼的呼叫端往往同時允許多種等價寫法（例如 `v-model:fooBar` 與 `v-model:foo-bar` 都合法），或呼叫端可能傳入邊界值（空字串、`undefined`、繼承 `Array` 的自訂類別）。改動判斷邏輯時，如果只驗證了作者當下測試的那條路徑，另一種等價形式或邊界值會悄悄退化成「找不到匹配」或「型別誤判」，而且因為原本能動，這種回歸不會被既有測試發現——它只會在使用者剛好用到那個特定形式時才炸開，且通常沒有清楚的錯誤訊息可以追查。

## 嚴重度
CRITICAL：漏掉的形式是被文件或既有測試明確保證支援的（例如 exact-match 事件名稱、`trueValue`/`falseValue` checkbox 語意），導致生產環境既有合法用法直接失效或產生誤導性警告。
HIGH：漏掉的是合理但邊緣的等價形式（如非拉丁字元的 component 名稱、CSS var 空字串值、boolean attribute 的字串 `'false'`），會在特定使用者場景下產生錯誤行為，但範圍較窄。
MEDIUM：漏掉的形式極罕見，或影響僅限開發模式警告訊息文字不準確，不影響實際渲染／執行結果。

## 反例（不該報）
- 判斷邏輯本來就明確只設計支援單一形式（例如新 API 文件已聲明「僅支援 camelCase」），沒有義務涵蓋其他寫法。
- diff 只是重新命名或搬移既有判斷邏輯的位置，語意與涵蓋範圍完全不變（沒有新增或刪減分支）。
- 該值本身受上游 schema／編譯器保證只會產生單一形式，使用者不可能寫出其他等價寫法，因此不存在遺漏形式的風險。

## 出處
- https://github.com/vuejs/vue/pull/8666#discussion_r240465450
- https://github.com/vuejs/core/pull/8268#discussion_r1571767683
- https://github.com/vuejs/core/pull/4850#discussion_r1337608585
- https://github.com/vuejs/core/pull/4804#discussion_r735440183
- https://github.com/vuejs/core/pull/5780#discussion_r2163482533
- https://github.com/vuejs/core/pull/9698#discussion_r1413564608
- https://github.com/vuejs/core/pull/12445#discussion_r2109983944
- https://github.com/vuejs/core/pull/12442#discussion_r1849472364
- https://github.com/vuejs/core/pull/12832#discussion_r1950325791
