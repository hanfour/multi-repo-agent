---
id: react-reducer-derived-state-staleness
layer: react
frameworks: ["react@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 裡出現以下任一模式：
- `useReducer` 的 reducer 內，從外部可變來源（如 devtools 的 `store`、`Map`/`Set`、快取物件）重新計算索引/排序/查找結果（例如 `store.getIndexOfElementID(...)`、`Array.from(store.xxx.keys()).map(...)`），且這個計算結果只在 dispatch 當下算一次，之後不會隨來源變化重新驗證。
- reducer 的 initial state 裡混入了依賴外部可變物件的衍生欄位（如 `defaultXxxIndex != null ? defaultXxxIndex : store.getIndexOfElementID(...)`），但後續程式碼路徑已不再讀取這個值，只是為了「保留舊行為」而留著計算。
- 針對「集合異動後快取的索引/子集失效」情境，只在某個特定 action type 判斷 `haveXxxChanged` 之類旗標決定是否重算，但漏掉了其他會讓集合變化的路徑（如 add/remove 用不同 action 進來）。
- effect 裡先用某個較新/較同步的 dispatch（如從 `transitionDispatch` 換成 `dispatch`），卻沒有同時處理「訂閱建立前，來源已經先變動過」這段初始 diff 被吃掉的情形。

## 判準
這類 bug 的共同根源是：把「衍生值」當成「一次性計算後存起來的值」，但衍生值的來源（store、Map、DOM 集合）是外部可變的，reducer/effect 只在某個時間點採樣它。時間點一過，採樣結果就可能跟真實來源不同步——常見表現是索引指向錯誤元素、選取狀態指向已刪除節點、或警告被誤觸發（值明明沒被用到但檢查邏輯還在跑舊分支）。資深 reviewer 對這類程式碼的預設懷疑是：「這個值是重新算出來的，還是編譯時就寫死、以後永遠不會再對齊？」如果重算路徑沒有覆蓋所有會讓來源失效的 action/事件，就是一個会在特定操作序列後才顯現的正確性 bug，且通常很難用單元測試覆蓋到（需要構造「先做 A 操作、再做 B 操作」的序列）。

## 嚴重度
CRITICAL：衍生索引/狀態失準會導致操作到錯誤實體（例如刪除、高亮、跳轉到錯的 tree node/DOM 元素），且無法從 UI 上立即察覺不一致。
HIGH：索引/快取失效會讓功能整段失效或丟出可見錯誤（如 index out of range、`getIndexOfElementID` 回傳 null 未處理），但範圍侷限在單一互動流程內。
MEDIUM：衍生值計算路徑遺漏部分觸發來源，導致某些操作序列下顯示過期資料（如警告/搜尋結果沒有即時刷新），但不會造成崩潰或誤操作到其他實體。

## 反例（不該報）
- reducer 每次 dispatch 時都完整重新計算衍生值（不是只在 initial state 或某個分支算一次），而且所有會讓來源集合變化的 action 都會觸發這次重算。
- 衍生值來源本身是 immutable/每次都是新物件（例如 `useMemo` 已正確列出所有 deps），不存在「來源變了但快取沒變」的視窗。
- 過期值只會造成非使用者可感知的內部欄位不一致（例如僅供 Flow/TS 型別滿足，執行期從未讀取，且已確認未來也不會被讀取）。
- 明確標記為 `// TODO` 且該落後行為在同一 PR 討論中已被作者/review 承認為已知限制、非本次改動範圍。

## 出處
- https://github.com/react/react/pull/34620#discussion_r2384436601
- https://github.com/react/react/pull/34119#discussion_r2260056095
- https://github.com/react/react/pull/34078#discussion_r2247613099
- https://github.com/react/react/pull/22144#discussion_r693002697
- https://github.com/react/react/pull/20463#discussion_r546108040
- https://github.com/react/react/pull/20463#discussion_r546054273
- https://github.com/react/react/pull/20463#discussion_r545992602
- https://github.com/react/react/pull/20463#discussion_r543372938
