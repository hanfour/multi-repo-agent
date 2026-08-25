---
id: vue-async-hook-promise-chain-context-bug
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: HIGH

---
## 觸發訊號
diff 中出現以下任一種寫法：
- 把 lifecycle hook 或使用者提供的 callback 直接傳進 `.then()`、`Promise.all([...])`、或其他 promise chain（例如 `Promise.all([handler(), hook()])`、`p.then(fn)`），卻沒有 `.call(instance.proxy)` / `.bind(instance.proxy)` 綁定正確的元件實例 context。
- 在 async 分支的一開始（例如 `hasAsyncSetup || prefetches` 這類判斷式或 `Promise.resolve(res).then(...)` 的最外層）就把一個「會在 async setup/promise resolve 之後才被賦值」的實例欄位（如 `instance.sp`）讀出來存成 `const`，而不是等對應的 promise resolve 之後才讀。
- 把單次請求（尤其 SSR render）生命週期內才有效的可變狀態（如 `ssrContext`）存成 module-level 變數，供某個 `async function` 之後存取，而該 function 有可能被併發呼叫。
- 修改 `nextTick`／scheduler 相關函式對 callback 的呼叫方式（新增/移除 `.bind(...)`、改變 `p.then(fn)` 的呼叫時機）。

## 判準
這類 bug 只有在特定時序或併發情境下才會炸，單次同步呼叫的測試通常測不出來：
- context 綁定遺失會讓使用者在 hook 裡寫 `this.xxx` 時拿到 `undefined` 或錯誤的 instance，而且往往要到 production 才被回報。
- 過早讀取閉包變數會拿到 assignment 之前的舊值（通常是 `undefined`/空陣列），導致對應的 prefetch/hook 被靜默跳過（不丟錯、也不執行），非常難追。
- module-level 共享狀態在 SSR 這種天生會被併發呼叫的路徑上，會讓不同請求互相覆蓋彼此的 context，屬於典型的 race condition，本地開發環境（單一 request）幾乎不可能重現。

## 嚴重度
CRITICAL：module-level 可變狀態（如 `ssrContext`）在會被併發呼叫的 async function（尤其 SSR render 路徑）中讀寫，可能導致不同請求間資料互相覆蓋/洩漏。
HIGH：hook/callback 傳入 promise chain 時遺失 `this`/instance context 綁定；或閉包變數在其真正被賦值前就被讀出並固定下來，造成 async hook（如 `serverPrefetch`）被靜默跳過。
MEDIUM：純粹是可讀性/时序上容易誤解但目前邏輯正確（例如用 `if` 取代 `&&` 的建議），或修改只影響效能而非正確性。

## 反例（不該報）
- promise chain 裡的 callback 是不依賴 `this` 的純函式，或已經是綁定好詞法作用域的箭頭函式：缺少 `.call()`/`.bind()` 不是 bug。
- 被提前讀取的欄位是同步賦值、且在整個 promise pending 期間不會被外部改變：提前讀取沒有問題。
- module-level 變數只在單一、非併發（例如同步或有明確序列化保證）的呼叫路徑中使用：不算共享狀態 bug。
- 只是把既有邏輯搬到新的 helper／改變寫法（如 `hookInjector` 抽象化、`indexOf`→`includes`）但語意與呼叫時機完全未變：屬於重構整理，不在此規則範圍內。

## 出處
- https://github.com/vuejs/vue/pull/3967#discussion_r83987304
- https://github.com/vuejs/vue/pull/3967#discussion_r83941565
- https://github.com/vuejs/vue/pull/3967#discussion_r83938508
- https://github.com/vuejs/vue/pull/3967#discussion_r83903842
- https://github.com/vuejs/vue/pull/3967#discussion_r83898300
- https://github.com/vuejs/vue/pull/3967#discussion_r83859946
- https://github.com/vuejs/vue/pull/2796#discussion_r62117514
- https://github.com/vuejs/core/pull/10893#discussion_r1722609703
- https://github.com/vuejs/core/pull/10893#discussion_r1722561238
- https://github.com/vuejs/core/pull/10893#discussion_r1721309086
- https://github.com/vuejs/core/pull/9961#discussion_r1440214622
- https://github.com/vuejs/core/pull/8731#discussion_r1370834830
- https://github.com/vuejs/core/pull/9370#discussion_r1353120528
- https://github.com/vuejs/core/pull/8406#discussion_r1225645025
- https://github.com/vuejs/core/pull/8406#discussion_r1225401958
- https://github.com/vuejs/core/pull/8406#discussion_r1225365506
- https://github.com/vuejs/core/pull/8406#discussion_r1225234033
- https://github.com/vuejs/core/pull/6215#discussion_r912339965
- https://github.com/vuejs/core/pull/3435#discussion_r597678196
- https://github.com/vuejs/core/pull/3070#discussion_r569369269
- https://github.com/vuejs/core/pull/3070#discussion_r569288749
- https://github.com/vuejs/core/pull/2597#discussion_r534407247
- https://github.com/vuejs/core/pull/2597#discussion_r534378382
- https://github.com/vuejs/core/pull/2597#discussion_r534373801
- https://github.com/vuejs/core/pull/2287#discussion_r498616459
- https://github.com/vuejs/core/pull/714#discussion_r379841213
- https://github.com/vuejs/core/pull/246#discussion_r334257408
- https://github.com/vuejs/core/pull/240#discussion_r334257089
- https://github.com/vuejs/core/pull/240#discussion_r334242008
