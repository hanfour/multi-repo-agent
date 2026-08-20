---
id: vue-prod-mode-runtime-filter-completeness
layer: vue
frameworks: ["vue@3.x", "@vue/compiler-sfc@3.x"]
severity_default: MEDIUM
---
## 觸發訊號
diff 裡出現以 `isProd` / `isSSR` / `useDevMode` 之類的 mode flag 去過濾或改寫「會影響 runtime 行為」的資料結構，且過濾條件是用列舉的方式寫死哪些值「在 prod/SSR 才必要」（例如 `defineModel` 的 `runtimeTypes` 只保留 `Boolean` 或 `Function && options`、或依 `isSSR` 對變數名稱做逃逸/加前綴處理）。也包含把單一 `.filter()` 拆成兩段式邏輯（先過濾再整批清空/整批加前綴）的重構。

## 判準
這類 mode-gated 過濾邏輯的正確性完全依賴「列舉的條件是否真的等於 runtime 實際會讀到的組合」，而不是寫的人直覺上覺得該留什麼。常見漏洞是漏掉組合情境（例如 `Boolean` 存在時 `String` 也要保留、`Function` 是否需要有 `options`/default 才算數）或只在單一 mode（如 SSR + dev）的交叉情境才會觸發的邊界案例（例如變數名裡的反斜線只有在 SSR dev model 才需要 escape）。這種 bug 平時測試不會覆蓋到，因為它只在 prod build 或 SSR+dev 的特定交叉條件下才會炸，corner case 多且容易漏。

## 嚴重度
CRITICAL：漏掉的組合會導致 prod build 產生錯誤的 runtime 行為（例如 prop 型別檢查在 prod 被錯誤地整批清空，導致本該生效的 coercion/驗證消失）。
HIGH：邏輯改寫後測試通過但邊界組合未被單元測試覆蓋到（如 Boolean+String 並存、Function 有無 options）。
MEDIUM：只是效能/產物大小的最佳化（去掉 prod 不需要的型別）但邏輯本身正確，只是可讀性差或條件寫法容易誤導未來維護者。

## 反例（不該報）
純粹的型別標注（如 `as SFCAsyncStyleCompileOptions`）或不影響過濾邏輯本身正確性的 cast，不算此規則要抓的問題。若 mode-gated 過濾邏輯有對應的單元測試明確涵蓋所有型別組合（Boolean/Function/String 各種搭配、SSR+dev 交叉），且測試通過，則不用因為程式碼看起來複雜就報。

## 出處
- https://github.com/vuejs/core/pull/9603#discussion_r1394300167
- https://github.com/vuejs/core/pull/9603#discussion_r1394192720
- https://github.com/vuejs/core/pull/9603#discussion_r1392967677
- https://github.com/vuejs/core/pull/8051#discussion_r1161465611
- https://github.com/vuejs/core/pull/7861#discussion_r1130237422
