---
id: react-cache-invalidation
layer: react
frameworks: ["react@>=16.8"]
severity_default: HIGH
---
## 觸發訊號
- diff 新增或修改了記憶化/快取邏輯：`useMemo`/`useCallback` 的依賴陣列、任何「先比對舊值/查表，沒變或查得到才跳過重算」的手寫判斷式（例如 `if (cache.has(key))`、`if (prev !== next)` 型態的 bailout）、或是 Map/WeakMap/物件形式的 cache — 要去確認 cache 的 key 或依賴陣列是否涵蓋了「所有會改變輸出結果」的輸入，而不是只涵蓋作者當下想到的那幾個。
- diff 新增了 module-level（元件/函式外部）或跨 render、跨 request 存活的變數、Map、陣列作為暫存/快取 — 要去確認：元件重新掛載、多個 instance 共用同一份模組狀態、或資料來源整批替換時，這份狀態有沒有對應的清除/重置路徑。
- diff 把某個會隨操作改變的來源（清單順序、遠端/外部 schema、設定值）的衍生結果（索引、排序位置、預設值副本）存下來重複使用 — 要去確認來源用「非新增/刪除」的方式改變時（例如純粹重新排序、原地更新），這份衍生結果是否也會同步刷新，而不是只在特定操作型別（如新增、刪除）時才觸發重算。
- diff 新增了會被多處重複讀取的訂閱/監聽器狀態切換邏輯（例如 bubble/capture 兩種模式互換）— 要去確認舊的訂閱是否確實被清掉，不會有殘留的 stale 訂閱同時存在。

## 判準
這類問題的共同點是：快取或記憶化少涵蓋了一個會影響結果的輸入，導致程式在特定操作序列下（重新排序、跨 render 保留、多 instance 共用、schema 之後被改掉）回傳上一輪的舊值。這種 bug 通常不會在一般的「新增/刪除」測試路徑被踩到，只有在較不常見但真實會發生的操作組合下才會顯現，因此作者自己往往沒意識到少了一個依賴或一條清除路徑。資深 reviewer 之所以特別盯著這類地方，是因為一旦漏抓，使用者看到的是「悄悄顯示舊資料」而非明顯的崩潰或報錯，難以在事後除錯時定位成因。

## 嚴重度
CRITICAL：快取/memo 命中會讓使用者看到明顯錯誤或過期的資料，且影響核心互動路徑（渲染結果、要送出的資料、清單顯示順序），使用者無法透過重新整理頁面之外的手段自行修正，也沒有其他機制會事後糾正。
HIGH：快取失效邏輯遺漏了可預期會發生的情境（重新排序、元件重新掛載、schema/設定變更），但影響侷限在次要功能，或需要特定但不算罕見的操作序列才會觸發。
MEDIUM：快取/memo 依賴不完整，但實際影響很小（只造成不必要的重算而非錯誤結果），或已有明確 TODO/後續 PR 在追蹤這個已知落差。

## 反例（不該報）
- 一般的 `useMemo`/`useCallback`，依賴陣列已經涵蓋所有讀取到的變數，且沒有額外的自訂快取邏輯 — 這是正常用法，不該報。
- staleness 是設計上刻意允許的（例如樂觀更新、為避免 loading 閃爍而短暫顯示舊資料，且有明確的後續同步機制），屬於已知取捨而非遺漏，不該報。
- 快取/memo 拿掉後計算結果完全一致，純粹是效能優化而非正確性議題（例如兩種計算路徑保證同構）— 不屬於這一類。
- 單純的過期註解或死程式碼（comment 提到已刪除的函式或已不存在的行為），沒有實際快取/記憶化邏輯牽涉其中 — 應歸類到別的規則，不算這一類。

## 出處
- https://github.com/react/react/pull/22144#discussion_r692816119
- https://github.com/react/react/pull/34226#discussion_r2282540380
- https://github.com/react/react/pull/19634#discussion_r472373859
- https://github.com/react/react/pull/18745#discussion_r426793077
- https://github.com/react/react/pull/34371#discussion_r2323577595
- https://github.com/react/react/pull/22184#discussion_r756465502
- https://github.com/react/react/pull/20315#discussion_r534427356
- https://github.com/react/react/pull/20023#discussion_r504837615
