---
id: vue-custom-element-async-def-race
layer: vue
frameworks: ["vue@^3.0.0"]
severity_default: HIGH

---
## 觸發訊號
diff 修改 `packages/runtime-dom/src/apiCustomElement.ts`（`VueElement` 類別）中以下任一段落：
- `asyncDef().then(def => ...)` / `_pendingResolve` callback 裡對 `this._def`、`configureApp`、props 做賦值或合併
- `_resolveProps` 呼叫時機的調整（是否在 sync 分支立即解析、或延後到 `connectedCallback`）
- `_styleChildren` / `owner` 相關的 shadow DOM style 節點插入邏輯（`prepend`、`insertBefore`、依 owner 搬移 style）
- 用 `new Date().getTime()` 或類似非嚴格遞增值產生 style/元件識別 id
- `parentNode` 向上尋找 parent custom element（`parentCE`）的遞迴邏輯

## 判準
`VueElement` 的 async 元件解析（`__asyncLoader`）與同步流程之間存在競態：await 之後直接覆寫 `this._def`、props 或 `configureApp`，很容易蓋掉這段等待期間已經由其他路徑（同步屬性設定、巢狀 resolve、parent 的 configureApp）寫入的狀態，而且這類 bug 只有在巢狀 / 非同步元件組合下才會重現，一般單元測試很難覆蓋。同理，shadow DOM 內的 style 節點插入順序會直接影響 CSS cascade，「插到最前面」或「插到最後面」這種簡化實作在單層元件下正確，但巢狀元件（parent/child 都有各自 style）就會把樣式優先權插錯位置，必須錨定在特定的 owner/anchor 節點旁而非絕對頭尾。用時間戳記當唯一 id 在極短時間內會撞號，導致後續依 id 做的清理/移除邏輯失效。

## 嚴重度
CRITICAL：async resolve 後的賦值靜默覆蓋掉已經生效的狀態（例如覆蓋掉已設定的 `configureApp`、已解析完成的 props），造成所有使用 async custom element 的使用者出現功能性回歸。
HIGH：shadow DOM style 插入順序寫錯，導致巢狀 custom element 的 CSS cascade 優先權錯誤（視覺 bug，且只在巢狀情境重現）；或 `parentNode` 向上尋找 parent custom element 的邏輯對非 CE 中介節點（如 `<div>`、`<slot>`）處理錯誤。
MEDIUM：用 `Date.now()` 類的非嚴格遞增值當 id 造成潛在（低機率）碰撞；或存在多餘/重複的 DOM 操作（例如手動 remove 後又呼叫已經會自動搬移節點的 `prepend`）。

## 反例（不該報）
- `_def` 或 props 的賦值發生在完全同步的程式路徑（沒有 `await`/`.then()`），不存在競態，不用套這條規則。
- style 節點插入只有單層（沒有 `owner`/`_styleChildren` 之類的多層巢狀 map），插入頭尾都不影響 cascade 正確性時不算問題。
- 為效能改動迴圈/查找方式（例如把 for-loop 改成 map+sort）但邏輯結果不變、且不涉及 async 狀態覆寫或 style 插入順序，屬於另一類效能考量，不套用本規則。

## 出處
- https://github.com/vuejs/core/pull/13030#discussion_r2104132046
- https://github.com/vuejs/core/pull/13030#discussion_r2103701764
- https://github.com/vuejs/core/pull/13030#discussion_r1994546814
- https://github.com/vuejs/core/pull/12965#discussion_r1974526576
- https://github.com/vuejs/core/pull/12855#discussion_r1950866896
- https://github.com/vuejs/core/pull/12607#discussion_r1899749735
- https://github.com/vuejs/core/pull/9351#discussion_r1349519107
- https://github.com/vuejs/core/pull/9351#discussion_r1349497976
- https://github.com/vuejs/core/pull/7942#discussion_r1190593946
- https://github.com/vuejs/core/pull/7942#discussion_r1188340156
- https://github.com/vuejs/core/pull/4792#discussion_r728417404
