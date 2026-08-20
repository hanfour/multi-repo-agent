---
id: vue-vmodel-modifier-independence
layer: vue
frameworks: ["vue@2.x", "vue@3.x"]
severity_default: HIGH

---
## 觸發訊號
diff 修改 v-model 相關 runtime directive（`vModelText`/`vModelSelect`/`vModelCheckbox`/`vModelRadio`/`vModelDetails` 等 in `packages/runtime-dom/src/directives/vModel.ts`）、compiler codegen（`genSelect` 等 in `compiler/directives/model.js`）、或 `componentEmits.ts` 的 modifier 處理邏輯時，出現：
- 多個原本獨立的 modifier（例如 `trim`、`number`/`castToNumber`、`castToTimeStamp`）被合併進同一個 `if (a && b)` 條件才觸發某一轉換（例如 `if (trim && castToNumber) { domValue = domValue.trim() }`），而不是各自獨立的 `if` 區塊；
- 對 `domValue` 直接呼叫型別特定方法（`.trim()`、`new Date(str)`）而未先確認來源保證是該型別／格式（例如值可能來自 `$emit` 的任意 raw arg，或跨平台（iOS Safari）對含 `-` 的日期字串解析行為不一致）。

## 判準
`trim` 與 `number`（或 `castToTimeStamp`）是使用者可獨立套用的 modifier（`v-model.trim`、`v-model.number` 可以只用其中一個）。把兩者用 `&&` 綁在同一個判斷式裡，會讓「只用 trim、不用 number」這種最常見的組合被靜默跳過 —— 兩個 modifier 分別測試都會通過，只有交叉組合測試才會抓到，review 時很容易漏看。同理，對非保證為 string／特定日期格式的值直接呼叫 `.trim()` 或 `new Date(...)`，在真實輸入下會丟例外或在特定平台（如 iOS）解析出錯誤結果，而不是編譯期就能發現的型別錯誤。

## 嚴重度
CRITICAL：該路徑是框架核心 v-model 綁定邏輯，會影響大量下游使用者且已發版（例如已合併到 release branch 才發現迴歸）
HIGH：modifier 轉換邏輯用共用/相依的條件式（如 `if (trim && castToNumber)`）取代原本獨立的判斷，導致某個 modifier 在常見組合下被靜默失效
MEDIUM：對使用者可控值（如 `$emit` 的 raw arg、跨平台日期字串）直接呼叫型別特定方法而未檢查型別/格式，在非典型輸入下會丟例外或解析錯誤

## 反例（不該報）
- 值的來源已由型別系統或上游語意保證安全（例如 DOM input 的 `el.value` 保證是 string，對它呼叫 `.trim()` 沒有風險）；
- 兩個條件本來就被設計成必須同時成立才有意義，且此為文件明訂、有測試覆蓋的行為，並非疊加式的獨立 modifier；
- PR 作者已明確說明範圍是刻意限縮（例如只修 `<input type="text">`，`<textarea>` 有不同語意需另開 PR 處理），這是刻意的 scope 決策而非遺漏。

## 出處
- https://github.com/vuejs/vue/pull/4756#discussion_r96873909
- https://github.com/vuejs/vue/pull/2797#discussion_r62114863
- https://github.com/vuejs/core/pull/14411#discussion_r3711186228
- https://github.com/vuejs/core/pull/12396#discussion_r1843068610
- https://github.com/vuejs/core/pull/8048#discussion_r1161578169
- https://github.com/vuejs/core/pull/8048#discussion_r1161462561
- https://github.com/vuejs/core/pull/8048#discussion_r1161462285
- https://github.com/vuejs/core/pull/5842#discussion_r862592171
- https://github.com/vuejs/core/pull/5842#discussion_r862584990
- https://github.com/vuejs/core/pull/5770#discussion_r854924465
- https://github.com/vuejs/core/pull/4852#discussion_r735535304
- https://github.com/vuejs/core/pull/2696#discussion_r533575325
- https://github.com/vuejs/core/pull/2696#discussion_r533185605
- https://github.com/vuejs/core/pull/2649#discussion_r527581913
- https://github.com/vuejs/core/pull/2254#discussion_r500082918
