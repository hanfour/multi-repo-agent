---
id: react-fiber-alternate-sync
layer: react
frameworks: ["react@>=16.3"]
severity_default: HIGH
---
## 觸發訊號
Diff 中對 Fiber 的可變欄位（`stateNode`、`memoizedState`、`memoizedProps`、`updateQueue`、`flags`/`effectTag`、profiler/component-name 快取欄位、或掛在模組級 Map/WeakMap 上以 fiber 為 key 的紀錄）做了寫入或清除動作，但：
- 只出現在 `if (current !== null)` / `if (fiber.alternate !== null)` 其中一支，另一支（`workInProgress`、`finishedWork`、`current.alternate`）沒有對稱地寫入或清除；
- 或是把上一輪殘留在 `workInProgress`/`current` 上的值直接沿用，卻沒有針對「這是新掛載（`current === null`）」與「這是更新」兩種情況分別重置；
- 或是在 detach/GC 清理路徑中只 null 掉 `fiber.alternate` 卻沒處理 `alternate.alternate`（即對方指回自己的反向指標）。

## 判準
Fiber reconciler 靠 `current`／`workInProgress`（互為 `alternate`）雙緩衝樹在 commit 時整棵切換。任何不是「純粹由這次 render 的 props/state 重新算出」的可變欄位，若只在其中一側寫入，就會在下列情境下露餡：(1) 一次被打斷或 bail-out 的 render 會直接復用還沒被重新 clone 的 workInProgress，殘留的舊值會被誤當成這次 render 的結果帶出去；(2) 只清理 `current` 而沒對稱清理 `alternate` 的 GC/detach 邏輯，會在下次 commit swap 後讓已刪除的節點重新被引用；(3) 分別處理 mount（`current === null`）與 update 的程式碼很容易寫成「其中一支忘了做」，導致 update-only 的狀態被誤用在 mount 上，或反之。這類 bug 在一般直線 render→commit 流程裡完全測不出來，只有在 bail-out、error retry、hidden→reappear、或兩個 update 互相打斷時才會現形，這正是這批 review 意見反覆抓到它們、而不是靠測試抓到的原因。

## 嚴重度
CRITICAL：清理/detach 邏輯只 null 掉一側的 `alternate` 指標或只從一個 Map/Set 移除紀錄，導致下次 commit swap 後仍能經由另一側抓到已刪除的 fiber（use-after-free 等級的懸空引用），或造成無限迴圈/掛起。
HIGH：欄位只在 `current !== null` 或 `current === null` 其中一支被寫入/重置，另一側殘留前一輪的舊值，導致下一次 render 讀到錯的 state（例如 component name、cache pool、effect destroy 函式、dehydrated 狀態），造成使用者可見的錯誤行為。
MEDIUM：對稱性缺失但影響範圍侷限在 DEV-only 警告、profiling 數據或內部 debug 工具，不影響生產行為。

## 反例（不該報）
- 欄位每次 render 都會被無條件整個覆寫、不依賴上一輪殘留值——例如直接由 `nextProps` 算出後整包賦值的欄位，此時 current/workInProgress 不同步沒有風險。
- 該值本來就只該活在 workInProgress 上的暫時性渲染中間結果，且這次 render 保證會完整跑完 begin→complete（不會被打斷復用），commit 後整個 workInProgress 變成新的 current，欄位自然「跟著搬過去」，不需要手動鏡像到 `current`。
- 程式明確只針對「新掛載」或「只針對更新」其中一種語意設計，且有不變量保證另一側永遠不會被讀到（例如只在錯誤路徑短暫存在、活不過這次 commit 的中間 tag/state）。

## 出處
- https://github.com/react/react/pull/34463#discussion_r2353908990
- https://github.com/react/react/pull/34196#discussion_r2274045816
- https://github.com/react/react/pull/35643#discussion_r2733222098
- https://github.com/react/react/pull/22007#discussion_r681250566
- https://github.com/react/react/pull/21583#discussion_r642610919
- https://github.com/react/react/pull/16807#discussion_r325232573
- https://github.com/react/react/pull/31930#discussion_r1901203087
- https://github.com/react/react/pull/30895#discussion_r1746458578
- https://github.com/react/react/pull/12279#discussion_r185963243
