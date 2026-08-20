---
id: vue-getter-invocation-semantics-drift
layer: vue
frameworks: ["vue@^2.0.0 || ^3.0.0"]
severity_default: HIGH
---
## 觸發訊號
diff 修改了「衍生值」的取值路徑，具體包含以下任一種改動：
- computed 的 `userDef` / `userDef.get`、`Watcher.prototype.getter`、`defineReactive` 裡的 `getter`/`setter`，或任何來自 `Object.getOwnPropertyDescriptor(obj, key).get` 的存取器。
- getter 的呼叫次數改變：原本只呼叫一次並快取結果（`const value = getter()`），改成在同一段邏輯裡呼叫兩次以上（如 array 分支再呼叫一次），或反過來把「每次都要讀最新值」的路徑改成快取。
- getter 呼叫時是否用 `.call(obj)` / `.call(vm)` 綁定 `this`，被加上或拿掉。
- 用來替代「空 getter」的 fallback 函式被換成專案裡另一個同名但語意不同的工具函式（例如 `function () {}`（回傳 `undefined`）換成 `noop`，而該 `noop` 其實是 identity function，回傳第一個參數）。
- 數值 / 時長正規化邏輯（`toNumber`、`parseFloat`、`Number(val)`、`normalizeDuration` 之類）的 NaN／`0`／空字串邊界判斷被改寫。

## 判準
這些都是 reactivity 系統的核心讀值路徑，getter 常帶有副作用（觸發依賴收集、遞迴 `traverse` 巢狀物件、讀 DOM）而不是單純的純函式：
- 重複呼叫 getter 不只是效能浪費，可能造成依賴收集被觸發兩次、或兩次呼叫之間值已經改變導致不一致。
- 遺失 `this` context 會讓 getter 內部讀 `this.xxx` 時直接壞掉或讀到 `undefined`，而且往往只在特定 `computed`/`inject` 寫法下才會炸，本地測試不容易覆蓋到。
- 把 fallback 函式换成語意不同的同名工具（`noop` 誤用為 identity）是最隱蔽的一種：呼叫端寫 `value = this.getter.call(vm, vm)`，如果 `getter` 其實是「回傳第一參數」的 identity function，`value` 會變成 `vm` 本身而不是預期的 `undefined`，且完全不會拋錯，只會在下游用到這個值時才出現詭異行為。
- `parseFloat`/`Number` 對非數字字串回傳 `NaN`，對合法的 `'0'` 回傳 `0`（falsy），如果判斷式寫成 `n || n === 0` 或漏了 `isNaN` 檢查，會把合法的 0 值誤判為轉換失敗，或把轉換失敗的 `NaN` 誤判為成功（例如 `duration` 解析出 `NaN` 卻沒有觸發預期的「不是合法數字」警告）。

## 嚴重度
CRITICAL：fallback 函式被換成語意不同的同名工具（如 identity 誤用為 noop），導致下游把非預期值（如 `vm` 本身）當成合法回傳值使用；或 getter 呼叫遺失 `.call(obj)` context 造成執行期例外或元件初始化失敗。
HIGH：getter 從「呼叫一次並快取」被改成「呼叫多次」（或反之），且該 getter 有副作用（依賴收集、遞迴 traverse、讀 DOM）；或數值／時長解析的 NaN／`0` 邊界判斷被改錯，導致合法值被拒絕、或非法值被靜默接受而不觸發應有的 dev warning。
MEDIUM：呼叫次數變動但 getter 為已知純函式、無副作用，純屬效能疑慮；或 dev-only warning 的判斷式寫法調整（如把回傳值判斷改成內聯正則/條件），但觸發時機本身未變。

## 反例（不該報）
- 單純把 `let val; if ((val = expr) != null)` 改寫成 `const val = expr; if (val != null)`：呼叫次數、context、回傳語意完全相同，只是風格重構，不該報。
- 把 dev-only 的 warning 判斷用 `if (process.env.NODE_ENV !== 'production') { ... }` 整段包起來，取代原本「函式回傳值當旗標」的寫法，但警告實際觸發的條件沒有改變，只是把邏輯挪到呼叫端讓 dead code elimination 生效，這是合理的效能/可讀性改善，不該報 CRITICAL/HIGH。
- 新增一個尚未接進任何既有呼叫路徑的小型輔助函式（如純粹的型別守衛 `isXxx`、`isUndefined`），且沒有改動任何既有 getter 的呼叫次數或語意，不該報。
- 把已知等價的兩種寫法互換（例如 `Object.assign(fn.bind(x), fn)` 換成專案自己的 `extend` alias，純粹是為了縮小 bundle size），行為完全一致，不該報。

## 出處
- https://github.com/vuejs/vue/pull/12071#discussion_r630773970
- https://github.com/vuejs/vue/pull/10627#discussion_r340405503
- https://github.com/vuejs/vue/pull/10627#discussion_r339387819
- https://github.com/vuejs/vue/pull/10491#discussion_r324467076
- https://github.com/vuejs/vue/pull/10491#discussion_r324465995
- https://github.com/vuejs/vue/pull/9386#discussion_r252018437
- https://github.com/vuejs/vue/pull/9386#discussion_r251912305
- https://github.com/vuejs/vue/pull/8925#discussion_r227106727
- https://github.com/vuejs/vue/pull/8791#discussion_r217675435
- https://github.com/vuejs/vue/pull/8791#discussion_r217667449
- https://github.com/vuejs/vue/pull/8791#discussion_r217660239
- https://github.com/vuejs/vue/pull/8613#discussion_r208298839
- https://github.com/vuejs/vue/pull/7981#discussion_r196752042
- https://github.com/vuejs/vue/pull/7981#discussion_r194326279
- https://github.com/vuejs/vue/pull/7981#discussion_r179986801
- https://github.com/vuejs/vue/pull/7171#discussion_r154520706
- https://github.com/vuejs/vue/pull/5627#discussion_r115495444
- https://github.com/vuejs/vue/pull/5267#discussion_r107867075
- https://github.com/vuejs/vue/pull/5267#discussion_r107843068
- https://github.com/vuejs/vue/pull/5267#discussion_r107819669
- https://github.com/vuejs/vue/pull/5267#discussion_r107797094
- https://github.com/vuejs/vue/pull/4684#discussion_r95337650
- https://github.com/vuejs/vue/pull/4069#discussion_r85694992
- https://github.com/vuejs/vue/pull/4069#discussion_r85691312
- https://github.com/vuejs/vue/pull/1762#discussion_r44369167
- https://github.com/vuejs/vue/pull/1762#discussion_r44290559
- https://github.com/vuejs/vue/pull/1762#discussion_r44290371
- https://github.com/vuejs/vue/pull/1762#discussion_r44232620
- https://github.com/vuejs/vue/pull/1129#discussion_r36594831
- https://github.com/vuejs/core/pull/14892#discussion_r3339451030
- https://github.com/vuejs/core/pull/12293#discussion_r1821748771
- https://github.com/vuejs/core/pull/11561#discussion_r1710586748
- https://github.com/vuejs/core/pull/11561#discussion_r1710565393
- https://github.com/vuejs/core/pull/10844#discussion_r1591297608
- https://github.com/vuejs/core/pull/10397#discussion_r1501769221
- https://github.com/vuejs/core/pull/10250#discussion_r1473683570
- https://github.com/vuejs/core/pull/8988#discussion_r1411476650
- https://github.com/vuejs/core/pull/8988#discussion_r1411132332
- https://github.com/vuejs/core/pull/9368#discussion_r1352175511
- https://github.com/vuejs/core/pull/9141#discussion_r1317838000
- https://github.com/vuejs/core/pull/8523#discussion_r1222945654
- https://github.com/vuejs/core/pull/7344#discussion_r1049665592
- https://github.com/vuejs/core/pull/6952#discussion_r1006328809
- https://github.com/vuejs/core/pull/5069#discussion_r763852921
- https://github.com/vuejs/core/pull/4335#discussion_r689074627
- https://github.com/vuejs/core/pull/1188#discussion_r425545224
