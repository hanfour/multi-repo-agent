---
id: vue-vapor-expose-lifecycle-consistency
layer: vue
frameworks: ["vue@>=3.6.0-alpha"]
severity_default: MEDIUM

---
## 觸發訊號
Vapor runtime 元件（`setup(props, { slots, expose, ... })` 或 `decorate((props, { slots, expose }) => {...})` 形式的 functional/內建元件，例如 `KeepAlive.ts`、`Transition.ts`）新增或修改了對 `expose` 的處理，尤其是：
- 新增 `expose()` 呼叫但沒有搭配對應的 `@ts-expect-error` 或型別調整說明為何要 bypass 型別檢查
- 在 HMR rerender、keep-alive 快取重建、或元件重新掛載等生命週期分支中，沒有同步重置 `instance.exposed`（例如 `keepAliveInstance.exposed = null` 這類重置動作缺漏）
- `exposed` 物件的賦值時機跟實際 render/rerender 完成的時機對不上（在 render 完成前提早讀取，或 render 之後忘記更新）

## 判準
`expose()` 與 `instance.exposed` 是 Vapor 對齊 compiled script setup 行為的關鍵橋接點：外部透過 template ref 拿到的物件必須反映元件「當下」暴露的內容。KeepAlive/Transition 這類會重建或重新渲染子樹的內建元件，如果沒有在重建時機同步清空或重設 `exposed`，模板 ref 拿到的會是舊的、過期的 exposed 物件，造成使用者透過 ref 呼叫已經不存在或已變更的方法/屬性，而且這種 bug 只有在 HMR 或 keep-alive 快取命中路徑才會出現，一般 render 路徑測不到。

## 嚴重度
CRITICAL：`exposed` 過期會導致 template ref 呼叫到已銷毀元件實例的方法/state，造成執行期例外或操作到分離的 DOM/狀態（尤其發生在 keep-alive 快取切換場景）。
HIGH：HMR rerender 後 `exposed` 未重置，導致開發環境下模板 ref 行為與實際元件不一致，掩蓋真實的生產行為差異。
MEDIUM：`expose()` 呼叫新增但缺少對應的型別處理說明（如 `@ts-expect-error` 沒有註解原因），增加後續維護者誤刪或誤改型別繞過的風險。

## 反例（不該報）
- 一般（非 keep-alive、非 HMR）元件第一次 setup 時呼叫 `expose()` 並依賴後續的 `rerender!()`/正常 render 流程去實際賦值 `exposed`——這是正常的延遲賦值模式，不用在呼叫當下就賦值。
- 純粹新增 `expose` 到解構參數但函式本身尚未使用它（例如只是為了型別對齊 compiled script setup 的簽名），且沒有生命週期重建邏輯需要同步的場景。
- e2e-test-only 分支（如 `__BROWSER__ && __VUE_VAPOR_E2E_TEST__`）內的 exposed 賦值，這類程式碼不影響一般生產行為，不用比照正式邏輯的嚴謹度審查。

## 出處
- https://github.com/vuejs/core/pull/14448#discussion_r2850566392
- https://github.com/vuejs/core/pull/14448#discussion_r2850563568
- https://github.com/vuejs/core/pull/14448#discussion_r2797754886
