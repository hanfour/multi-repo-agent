---
id: common-incomplete-or-unbounded-cache-key
layer: common
frameworks: ["*"]
severity_default: MEDIUM

---
## 觸發訊號
diff 新增或修改一個手寫的 memoization/cache 機制(用 `Object.create(null)`、`Map`、或自訂 `Cache`/`LRU` class 包住一個計算結果),且符合下列任一情況:
- cache key 只取了函式參數的一部分(例如只用 `str`/`key` 當 key,但結果其實還受同時傳入的 `options`/`context`/`compilerOptions` 影響,那些參數沒有被序列化進 key);
- 這個 cache 是一個模組層級或長生命週期的 `Map`/`Object`,沒有任何大小上限、TTL 或淘汰機制,單純隨著呼叫次數持續塞入新 key(尤其是 key 來自外部輸入,如使用者提供的 template 字串)。

## 判準
快取的核心契約是「相同輸入 ⇒ 可以安全復用同一個輸出」。一旦 key 沒有完整涵蓋所有會影響結果的輸入,就會出現「key 相同、真實輸入不同」卻共用同一份快取結果的情況——這種 bug 通常只在特定參數組合下才會出現,單元測試很難覆蓋,線上才會被發現。另一方面,沒有上限的快取在長生命週期行程(server、SSR runtime、build watch)裡會隨呼叫次數無限成長,變成事實上的記憶體洩漏,而且不會有任何錯誤訊息提示,只會慢慢把行程吃到 OOM;如果 key 又來自外部可控輸入,等於是把記憶體耗盡的攻擊面直接暴露出去。

## 嚴重度
CRITICAL:快取跑在長駐行程(server、daemon、SSR runtime)、沒有任何上限,且 key 直接或間接來自使用者/外部可控輸入(可被用來做記憶體耗盡型 DoS)。
HIGH:cache key 遺漏的參數會實際造成錯誤輸出被復用(例如同一個 template 字串在不同 `compilerOptions` 下應該產生不同編譯結果,卻因為 key 沒有涵蓋 options 而共用了同一份快取)。
MEDIUM:快取無上限成長,但目前只存在於短生命週期的呼叫(CLI 單次執行、build script 一次性任務),或 key 遺漏的參數目前所有呼叫點都是常數、尚未真的造成錯誤輸出,但屬於容易被未來呼叫方誤用的脆弱設計。

## 反例(不該報)
- key 已經涵蓋所有會影響輸出的輸入(例如把 `options` 序列化後一併納入 key,或呼叫端有型別/註解保證該參數在整個 process 生命週期內恆定不變)。
- cache 本身雖然是無上限 `Map`/物件,但生命週期等同單次函式呼叫或單一 request(函式內部區域變數,呼叫結束即被 GC),不會跨請求持續累積。
- 純粹調整 eviction 檢查的時機(例如把「是否超過 limit」的判斷從新增前搬到新增/更新後),只是等價重構,沒有引入 key 覆蓋不全或無上限成長的新問題。
- bind/閉包等與快取無關的效能優化重構,即使外觀上也在動 `cache`/`str` 相關程式碼,但沒有動到 cache key 的完整性或大小上限,不屬於本規則要抓的問題。

## 出處
- https://github.com/vuejs/vue/pull/7445#discussion_r161387879
- https://github.com/vuejs/vue/pull/6494#discussion_r136788332
- https://github.com/vuejs/vue/pull/4930#discussion_r119790977
- https://github.com/vuejs/vue/pull/2971#discussion_r65569006
- https://github.com/vuejs/vue/pull/2885#discussion_r63451632
- https://github.com/vuejs/vue/pull/2885#discussion_r63451414
- https://github.com/vuejs/vue/pull/2885#discussion_r63448925
- https://github.com/vuejs/core/pull/7557#discussion_r1366637804
- https://github.com/vuejs/core/pull/4804#discussion_r732610718
- https://github.com/vuejs/core/pull/4631#discussion_r715961687
- https://github.com/vuejs/core/pull/4631#discussion_r713266689
- https://github.com/vuejs/core/pull/453#discussion_r346418511
