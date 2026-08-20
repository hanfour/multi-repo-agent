---
id: vue-suspense-pending-state-race
layer: vue
frameworks: ["vue@^3.0.0"]
severity_default: HIGH

---
## 觸發訊號
diff 動到 Suspense / KeepAlive 的 pending 狀態欄位或其衍生邏輯，具體如：
- `suspense.pendingId` / `suspense.pendingBranch` 的遞增、遞減或重置
- `pendingCacheKey` 被拿來做 `cache.set(...)`（尤其搭配 `queuePostRenderEffect` 延後執行）
- 比對 `instance.suspenseId === parentSuspense.pendingId` 之後做 dep 計數增減或 unmount 判斷
- KeepAlive 的 `deferredRenderEffects` / `deferredKeepAliveUpdates` 的建立、清空或重用（含 HMR reuse 路徑）
- 在 async setup 解析/拒絕、component unmount、或 KeepAlive 切換 target 的路徑上，新增或刪除對上述欄位的讀寫

## 判準
這類程式碼的正確性完全取決於 async 解析、unmount、HMR 重用、effect 排程之間的精確時序，肉眼看 diff 無法驗證。這個 repo 已經多次因此出包：unmount 邏輯因為 `pendingId` 早就被改掉而變成永遠不會執行的死碼、`suspenseId` 沒有隨 `pendingId` 同步更新導致 KeepAlive 快取分支狀態跟丟、`pendingCacheKey` 在 Suspense resolve 前就被快取導致快取到尚未 mount 的 vnode、HMR 重用 KeepAlive instance 時舊的 `deferredRenderEffects` 陣列殘留没清。Reviewer 要求的不是「邏輯看起來合理」，而是要作者明確指出對應的時序保證（引用實際會先執行的那行程式碼），或者提供涵蓋「resolve 後才快取／unmount 早於 resolve／KeepAlive+HMR 重用」這幾種交錯情境的回歸測試。

## 嚴重度
CRITICAL：直接修改 `pendingId` / `suspenseId` 的遞增遞減或重置邏輯，或移除既有的 async dep 清理／guard，卻沒有證明舊路徑真的是死碼。
HIGH：新增依賴 pending 狀態的快取或 effect 延後邏輯（如 `cacheSubtree` 依 `pendingCacheKey`、新的 `deferredRenderEffects` 機制），但沒有回歸測試涵蓋 resolve-after-cache、unmount-before-resolve、HMR 重用等交錯情境。
MEDIUM：新增的 pending 狀態檢查是唯讀的，且建立在既有已驗證過的不變量之上（例如把已測試過的 `pendingId` 比對邏輯搬到新的呼叫點）。

## 反例（不該報）
- 名稱含 "pending" 但與 Suspense/KeepAlive 無關的一般 async 狀態，例如 `nextTick` 內部 callback queue 的 `pending` flag，或單純的 loading state。
- 純粹的型別標註調整（如 `target: Component` 改成 `target: any`）或無行為變化的 rename。
- 只是簡化/新增測試案例本身、沒有改動 production 端 pending 狀態邏輯的 diff。
- 這次 cluster 中與 Suspense/KeepAlive 無關的討論（如 `new Function()` eval 風險、`update:` event 正則、`window.Promise` 特徵偵測、`resolveAsyncComponent` 回傳值語意、`compatConfig` 型別轉換）——這些是其他規則該處理的問題，不屬於本規則範圍。

## 出處
- https://github.com/vuejs/vue/pull/6932#discussion_r147302059
- https://github.com/vuejs/vue/pull/6244#discussion_r132457282
- https://github.com/vuejs/vue/pull/6244#discussion_r130288217
- https://github.com/vuejs/vue/pull/4506#discussion_r92942074
- https://github.com/vuejs/vue/pull/4506#discussion_r92926540
- https://github.com/vuejs/vue/pull/4506#discussion_r92920638
- https://github.com/vuejs/vue/pull/4084#discussion_r86074095
- https://github.com/vuejs/vue/pull/4084#discussion_r86061091
- https://github.com/vuejs/vue/pull/3967#discussion_r83781127
- https://github.com/vuejs/vue/pull/3967#discussion_r83774424
- https://github.com/vuejs/core/pull/15172#discussion_r3687308900
- https://github.com/vuejs/core/pull/15172#discussion_r3672284169
- https://github.com/vuejs/core/pull/14182#discussion_r2605454092
- https://github.com/vuejs/core/pull/13478#discussion_r2148972809
- https://github.com/vuejs/core/pull/13478#discussion_r2148897679
- https://github.com/vuejs/core/pull/13355#discussion_r2095166389
- https://github.com/vuejs/core/pull/10912#discussion_r1612554027
- https://github.com/vuejs/core/pull/10912#discussion_r1612054938
- https://github.com/vuejs/core/pull/6467#discussion_r949927515
- https://github.com/vuejs/core/pull/6215#discussion_r912339759
