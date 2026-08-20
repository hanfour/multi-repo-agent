---
id: react-duplicate-state-mirroring
layer: react
frameworks: ["react@>=16.8"]
severity_default: MEDIUM
---
## 觸發訊號
diff 裡新增（或既有程式碼被擴充）一個 local `useState`/component state / cache，其初始值直接取自另一個已存在的 source of truth（`Context` 提供的值、上游 cache、props 傳入的物件），並且緊接著用 `useEffect` 或在寫入路徑上手動呼叫兩次 setter（例如同時 `resource.write(...)` 又 `cache.set(...)`，或 `useEffect(() => setLocal(contextValue), [contextValue])`）把兩者「同步」在一起。也包含更廣義的情況：同一份邏輯狀態被拆成兩個以上獨立資料結構（例如 native 內部狀態 + debug/inspector 專用結構 + 要跨 bridge 序列化的第三份結構），且合入的 PR/comment 承認這些結構需要「協調」（coordinate）才能保持一致。

## 判準
一旦 local state 是從別的 source of truth 複製出來的，就多了一個「什麼時候複製、複製後何時失效」的隱性契約——render 期間可能讀到還沒被 effect 同步過的舊值，多一次 render cycle，且往後任何人改了上游來源都可能忘記同步這份影子副本，造成兩邊悄悄 diverge。resident reviewer 通常會直接問「為什麼不直接用來源的值/為什麼這樣還不夠」，因為這代表作者自己也不確定為什麼需要這份複製，而不是有明確理由（例如要讓 local state 可獨立編輯）。當結構被拆成三份以上（native / debug / serialized）時，協調成本會隨結構數量非線性增加，是後續 bug 與難以維護的重要來源。

## 嚴重度
CRITICAL：mirrored state 與同步邏輯之間形成循環更新（effect 觸發 setState → 又觸發 effect），或 diverge 後被下游當作唯一依據做出破壞性操作（例如覆寫使用者資料、觸發不可逆動作）。
HIGH：diverge 會讓使用者看到與實際來源不一致、且該資料屬於使用者依賴做判斷/編輯的內容（例如 inspector 顯示的即時狀態、可編輯欄位的顯示值）。
MEDIUM：只是多一次不必要的 render 或增加維護心智負擔，尚無已知會被讀到不一致值的路徑，但沒有註解說明為何不能直接用來源值。

## 反例（不該報）
- local state 的初始值取自 prop/context，但語意上就是「取一次初始值之後允許使用者本地編輯、之後刻意與來源脫鉤」（controlled-to-uncontrolled 模式），這是刻意設計的分岔，不是意外複製。
- hook 演算法內部本來就需要保存的前次快照（例如 `updateSyncExternalStore` 裡的 `prevSnapshot = hook.memoizedState`），這是演算法必要的 bookkeeping，不是把某個「已存在的另一份 source of truth」複製出來同步。
- 純粹的 selector/derived value 用 `useMemo` 從單一來源即時算出、沒有另外開一份 state 儲存，這正是應該鼓勵的替代寫法，不算違規。

## 出處
- https://github.com/react/react/pull/31398#discussion_r1869504738
- https://github.com/react/react/pull/20548#discussion_r552228675
- https://github.com/react/react/pull/14906#discussion_r260851563
