---
id: vue-domain-logic-lifecycle-state-flag-edge-cases
layer: vue
frameworks: ["vue@3.x"]
severity_default: HIGH

---
## 觸發訊號
diff 新增或修改了「依據某個內部旗標／索引／計數器來決定要不要走某個分支」的邏輯，而這個旗標是由生命週期回呼或非同步解析事件寫入或清空的 —— 常見形態包括：`disconnectedCallback` / `unmounted` 會把某個 instance 欄位（如 `_app`、`_ob`）設回 `null`；async 元件或 Suspense 的 `resolved`／`asyncResolved` 之類的 boolean；佇列（scheduler queue、cache）目前為空時索引/游標的初始值（如 `postFlushIndex`）；或某個 key（`pendingCacheKey`）在跨渲染週期之間被覆寫。看到這種變更時，要去確認：這個旗標在「先卸載、再重新掛載／重新插入」「非同步解析尚未完成就被移除或替換」「巢狀非同步元件或 Suspense 情境」「佇列/快取目前是空的（尚未開始 flush）」這幾種狀態下的實際取值，有沒有被明確列舉並各自給出正確分支，還是只覆蓋了作者心裡「正常流程」那一條路徑。

## 判準
這類旗標的設計初衷通常只考慮了「掛載一次、單向前進」的情境，但清除/重置這個旗標的時機（生命週期回呼、佇列跑完）跟判斷這個旗標的時機（下一次重新掛載、下一次 invalidate 呼叫）之間存在時間窗口，導致同一個變數在不同階段其實代表不同語意，而實作只處理了其中一種語意。這種缺陷不會被 golden-path 的單元測試或型別檢查抓到，因為它只在特定時序組合（先移除再重新插入、巢狀非同步元件、佇列目前恰好是空的）下才會現形；resident reviewer 是靠對元件生命週期與排程時序的知識去交叉核對每個分支覆蓋了哪些狀態，而不是單純讀懂那行程式碼寫了什麼。

## 嚴重度
CRITICAL：該旗標控制的是資料是否被正確渲染、快取或清理，漏判會造成使用者可見的錯誤畫面、記憶體洩漏或狀態污染，且使用者無法透過正常互動自行恢復（例如自訂元素重新插入後遺失 observer 導致響應式失效、KeepAlive 快取到尚未掛載完成的 vnode）。
HIGH：該旗標只在特定巢狀／非同步組合下才會走錯分支，多數一般使用情境不受影響，但一旦命中會造成明確的功能錯誤（例如 hydration 對不上真實 DOM、應該被移除的排程 job 沒被正確移除）。
MEDIUM：該旗標的邊界情況只會造成微小或難以察覺的偏差（例如一次多餘的重新渲染、極端輸入下才會撞到的快取鍵碰撞），不影響核心功能正確性。

## 反例（不該報）
旗標的設定與清除都發生在同一個同步呼叫堆疊內、沒有跨越 async 回呼或生命週期邊界的，不算——例如單純用一個區域 boolean 做 debounce 或遞迴防護，函式呼叫結束後該變數的生命週期也結束，不存在「下一次帶著舊語意被讀到」的機會。同樣地，若旗標的寫入與讀取保證都落在同一個 render pass 或同一次 flush 週期內完成（沒有機會被卸載/非同步解析打斷），也不需要枚舉生命週期狀態；純粹的規格對齊（例如字串跳脫、大小寫轉換規則）如果跟元件狀態無關，屬於另一類問題，不套用本規則。

## 出處
- https://github.com/vuejs/core/pull/15035#discussion_r3510007504
- https://github.com/vuejs/core/pull/14967#discussion_r3412487859
- https://github.com/vuejs/core/pull/13673#discussion_r2659255532
- https://github.com/vuejs/core/pull/12455#discussion_r1853248471
- https://github.com/vuejs/core/pull/12442#discussion_r1850006762
- https://github.com/vuejs/core/pull/12416#discussion_r1845829624
- https://github.com/vuejs/core/pull/10912#discussion_r1612054938
- https://github.com/vuejs/core/pull/7786#discussion_r1573016962
- https://github.com/vuejs/core/pull/9370#discussion_r1353120528
- https://github.com/vuejs/core/pull/4850#discussion_r1337608585
- https://github.com/vuejs/core/pull/4631#discussion_r715961687
- https://github.com/vuejs/core/pull/851#discussion_r394470937
