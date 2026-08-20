---
id: vue-normalize-absent-vs-falsy-conflation
layer: vue
frameworks: ["vue@*", "@vue/runtime-core@*", "@vue/compiler-sfc@*"]
severity_default: HIGH

---
## 觸發訊號
- 新增或修改的 `normalize*()` / `resolve*()` 函式（如 `normalizePropsOptions`、`normalizeEmitsOptions`、`resolvePropValue`、`toRuntimeTypeString`）用同一段邏輯處理「使用者沒傳這個值」跟「使用者傳了但值是 falsy/空字串/空物件」兩種情況。
- normalize 步驟被放在「判斷值是否存在」之前執行，導致沒傳的預設值也被 normalize，或是先做型別轉換（如 boolean prop 轉 `true`）再 normalize 回字串。
- 函式回傳值用 `null` 代表「未設定」，但產生 `null` 的條件式沒有同時檢查「原始輸入是否存在」與「normalize 後結果是否為空」，例如 `!Object.keys(normalized).length` 沒有搭配 `&& !raw`。
- mixin/extends 合併多個來源時，對「空物件 `{}`」跟「完全沒有這個 option」一視同仁地觸發合併邏輯（如 `appContext.mixins.forEach(extendEmits)` 對每個 mixin 都執行，不管該 mixin 是否真的宣告了對應 option）。
- 對「理論上不該是 null/undefined，但實際偵測到是」的變數，直接加 `&&` 短路或 optional chaining 讓程式碼「能跑」，而不是往上追為什麼它會是 null。

## 判準
Normalize 函式是 props/emits 解析、SFC 型別推斷等多處共用的基礎設施，一旦「未提供」跟「提供了空值」被合併處理，錯誤會在使用者側以「明明沒傳這個 prop 卻噴 invalid-prop 警告」或「明明宣告了 emits 卻沒被辨識」這種難以對應回原因的方式出現，而且因為是 runtime-core 的核心路徑，影響面是所有下游元件。順序錯誤（先轉型再 normalize，或先 normalize 再判斷是否存在）尤其危險，因為兩個獨立轉換疊加後的結果經常不等於預期的單一轉換結果，測試很容易只覆蓋到「有正常傳值」的路徑而漏掉「沒傳」或「傳空值」的邊界。另外，看到不該為 null 的變數卻是 null 時直接用防禦性判斷繞過，雖然眼前不會炸，但等於把根因藏起來，之後同一個 bug 會用別的變形再冒出來，且更難追。

## 嚴重度
CRITICAL：normalize 順序錯誤或 absent/falsy 混淆會讓 public API（props/emits 解析、SFC 編譯期型別推斷）在正常使用情境下產生錯誤的 runtime 行為或誤報警告，且不易被現有測試矩陣覆蓋到。
HIGH：normalize 邏輯本身正確，但用 `&&`/optional chaining 繞過一個「理論上不該是 null」的值，掩蓋了潛在的初始化順序或狀態管理 bug。
MEDIUM：normalize 函式的回傳值語意（`null` vs `{}` vs 原值）不一致，但目前呼叫端剛好都能容錯，尚未觀察到實際錯誤行為。

## 反例（不該報）
- normalize 函式只有單一輸入來源、沒有 optional/未提供的情境（例如參數本身是必填且已在型別層保證非 null），不需要區分 absent 與 falsy。
- 用 `??`/`ifPresent` 明確區分「未提供用預設值」與「提供了 falsy 值就用該值」，且有對應測試覆蓋兩種邊界。
- 防禦性檢查是在系統邊界（使用者輸入、外部 API 回應）做的驗證，而不是對內部理論上已保證非 null 的狀態做「靜默繞過」；邊界驗證失敗時有明確報錯或警告，不是靜默 fallback。
- 對已知會是 `null`/`undefined` 的可選欄位做型別層級的 `| null` 標註與對應處理，並非在意外情況下才出現的 null。

## 出處
- https://github.com/vuejs/core/pull/15230#discussion_r3739764370
- https://github.com/vuejs/core/pull/6266#discussion_r942454943
- https://github.com/vuejs/core/pull/5998#discussion_r919711939
- https://github.com/vuejs/core/pull/4353#discussion_r689834566
- https://github.com/vuejs/core/pull/2654#discussion_r529366718
- https://github.com/vuejs/core/pull/2654#discussion_r529286072
- https://github.com/vuejs/core/pull/2654#discussion_r528210385
- https://github.com/vuejs/core/pull/2654#discussion_r528199230
- https://github.com/vuejs/core/pull/2654#discussion_r528196566
