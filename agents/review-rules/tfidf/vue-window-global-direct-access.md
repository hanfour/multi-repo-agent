---
id: vue-window-global-direct-access
layer: vue
frameworks: ["vue@2.x", "vue@3.x", "@vue/repl", "@vue/sfc-playground"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中在 runtime-core / shared 等平台無關套件內新增或修改直接讀取 `window`、`typeof window !== 'undefined' && window.xxx`、`window.customElements`、`window.indexedDB`、`window.setTimeout` 等瀏覽器全域 API 的程式碼；或新增針對特定瀏覽器版本（UA、CSS 單位如 `svh`、`100vh`）的相容性 workaround，且沒有：(a) 快取檢查結果、(b) 用既有的 `inBrowser`/`getGlobalThis()` 抽象、(c) 考慮該 workaround 在未來版本或不同執行環境（Node/SSR）下是否仍然正確。

## 判準
1. `window` 存取若寫在 `runtime-core` 這類宣稱平台無關（可跑在 Node/SSR）的模組裡，會讓套件在 SSR 環境直接爆炸——這是正確性問題，不只是風格問題，應該一律走 `getGlobalThis()` 或既有的 `inBrowser` 判斷式集中處理。
2. `typeof window !== 'undefined' && window.xxx` 這種檢查如果在熱路徑（例如 `toString`、`isUnknownElement` 這類每次 patch/render 都會呼叫的函式）裡重複執行，沒有快取結果，是可避免的效能浪費。
3. 針對特定瀏覽器版本或特定 CSS 特性（iOS 9.3、`svh` 單位）寫死的相容性判斷，若沒有考慮到「未來版本行為不變」或「舊瀏覽器不支援」的邊界，會隨時間邊際失效或造成新相容性斷層，是脆弱、不易維護的寫法。

## 嚴重度
CRITICAL：平台無關套件（如 `runtime-core`、`shared`）中直接使用 `window`/`document` 等瀏覽器全域物件，會導致 SSR/Node 環境執行時直接拋錯（fatal to SSR）。
HIGH：（此類問題較少落在 HIGH；若快取缺失導致明顯效能回歸或相容性判斷錯誤造成功能在目標瀏覽器上直接失效，可視情況上調。）
MEDIUM：在熱路徑中重複進行未快取的 `window` 全域檢查（效能浪費）；或新增只針對單一瀏覽器版本/最新 CSS 特性的相容性判斷，未考慮向前相容或缺少 fallback（如 `svh` 在舊 iOS 不支援、UA 版本判斷未涵蓋後續版本）。

## 反例（不該報）
- 在明確標示為瀏覽器專屬的套件（如 `sfc-playground`、`repl` 等應用層 UI 程式碼）中直接使用 `window`——這些套件本來就只跑在瀏覽器，不需要 SSR 相容。
- 已經透過 `inBrowser` 或 `getGlobalThis()` 等既有抽象包裝過的 `window` 存取。
- 使用 `window.setTimeout` 等 API 只是為了在型別或語意上明確表示「這是瀏覽器的計時器」而非 Node 的計時器，且該檔案本身就是瀏覽器專屬程式碼。
- 針對某瀏覽器特性刻意選用舊API（如用 `window.innerHeight` 而非 `100vh`）而非新CSS單位，是經過權衡後的正確選擇（例如行動裝置上 `100vh` 會包含瀏覽器 UI 高度，`innerHeight` 才是使用者實際可見區域）——不要誤報為「應該改用更新的 CSS 特性」。

## 出處
- https://github.com/vuejs/vue/pull/10491#discussion_r324466433
- https://github.com/vuejs/vue/pull/9919#discussion_r278379245
- https://github.com/vuejs/vue/pull/3027#discussion_r65751010
- https://github.com/vuejs/vue/pull/3027#discussion_r65746855
- https://github.com/vuejs/core/pull/8051#discussion_r1165111197
- https://github.com/vuejs/core/pull/3217#discussion_r573683920
- https://github.com/vuejs/core/pull/3034#discussion_r559177067
