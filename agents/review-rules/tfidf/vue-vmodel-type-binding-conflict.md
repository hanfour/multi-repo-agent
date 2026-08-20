---
id: vue-vmodel-type-binding-conflict
layer: vue
frameworks: ["vue@2.x", "vue@3.x"]
severity_default: HIGH
---
## 觸發訊號
diff 改到 v-model 對 `<input>`（或其他有 `type` 語意的原生元素）的編譯/轉換邏輯，且改動只依賴單一管道去讀取 `type`：
- 只讀靜態 `type` attr（`map.type` / `el.attrsMap.type`），沒處理 `:type`／`v-bind:type`
- 只讀 `:type` binding，沒處理 `v-bind="{ type: ... }"` object spread 帶進來的 type
- 用正則/白名單去偵測三元運算式或動態值裡的 input type 字面量（如 `ternaryTextInputRE`、text-input type 清單），但清單只涵蓋部分 type
- 改變 `map['v-bind']` 與 `typeBinding`/`map.type` 的判斷順序或優先權（例如 `!typeBinding && map['v-bind']` → `!map.type && !typeBinding && map['v-bind']`）
- 檔案位置是通用的 `compiler/parser/index.js`（而非 v-model 專屬的 `directives/model.js`），卻在做只跟 v-model 有關的 type 檢查/警告

## 判準
v-model 對同一元素會依 `type`（checkbox/radio/text-like）產生完全不同的 codegen（用 `checked` 還是 `value`、綁哪個 event、要不要做 value coercion）。而 `type` 在模板裡可以透過至少四種語法路徑抵達同一個元素：靜態 attr、`:type` shorthand、`v-bind="{...}"` object spread、動態三元運算式。歷史上這條規則反覆被 reviewer 抓到的問題都是「只處理了其中一條路徑，另一條被悄悄破壞或漏判」——例如修好 `:type` 覆寫靜態 `type` 的 bug，卻讓 `v-bind="{type: x}"` 這種寫法失去 type binding；或是新增一份 text-input type 清單卻跟舊清單不同步。這類 bug 的修正 diff通常很小（一個 if 條件、一個正則），但正確性空間是組合爆炸的（語法路徑 × input type × 屬性順序），單靠 review 讀 diff 很難目測涵蓋，必須靠對應測試才能證明沒有回歸。

## 嚴重度
CRITICAL：change 讓既有已支援的語法路徑（尤其是 `v-bind="{type: ...}"` object spread）在沒有任何新測試涵蓋的情況下悄悄失去 type binding 或整個被 checkbox/radio 分支排除，會直接讓現有使用者模板在 production 跑出錯的 DOM 行為。
HIGH：新增一條 type 偵測路徑（三元式偵測、`:type` shorthand）但沒有同時涵蓋 checkbox/radio 與 text-like 兩個分支，或沒有補一個「沒有這個修正就會 fail」的 regression test。
MEDIUM：清單/正則有覆蓋但不完整（例如漏掉某個 text-like type），或邏輯放錯檔案（放在通用 parser 而非 v-model 專屬 directive 檔）導致警告的作用範圍比預期更廣或更窄。

## 反例（不該報）
- 純粹搬移既有 type 偵測 helper 到別的檔案/模組（例如把 `isTextInputType`/`ternaryTextInputRE` 移到 `shared` 或 `util/element.js`）且行為完全不變，沒有新增或刪減任何判斷路徑。
- PR 明確聲明只支援某一種語法（例如只支援靜態 `type`），測試與 reviewer 都已確認這是刻意縮小的 v1 範圍，且後續 follow-up 已在 review 中被提出並排入計畫。
- 改動的是 component 自訂 `model.prop`/`model.event` 的 fallback（props vs attrs），跟原生 input 的 `type` 判斷無關。

## 出處
- https://github.com/vuejs/vue/pull/7819#discussion_r174165051
- https://github.com/vuejs/vue/pull/7819#discussion_r174124851
- https://github.com/vuejs/vue/pull/7819#discussion_r174117712
- https://github.com/vuejs/vue/pull/7056#discussion_r151421794
- https://github.com/vuejs/vue/pull/7056#discussion_r150832962
- https://github.com/vuejs/vue/pull/6344#discussion_r132869082
- https://github.com/vuejs/vue/pull/6227#discussion_r132802215
- https://github.com/vuejs/vue/pull/6227#discussion_r132802012
- https://github.com/vuejs/vue/pull/6227#discussion_r132801798
- https://github.com/vuejs/vue/pull/6227#discussion_r132791104
- https://github.com/vuejs/vue/pull/6227#discussion_r132790831
- https://github.com/vuejs/vue/pull/6344#discussion_r132621658
- https://github.com/vuejs/core/pull/13170#discussion_r2106372101
- https://github.com/vuejs/core/pull/13170#discussion_r2101095811
