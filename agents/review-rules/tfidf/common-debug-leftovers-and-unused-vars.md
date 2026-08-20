---
id: common-debug-leftovers-and-unused-vars
layer: common
frameworks: ["*"]
severity_default: MEDIUM

---
## 觸發訊號
- diff 新增或保留 `console.log` / `print` / `debugger` 等除錯輸出陳述式,尤其訊息內容明顯是開發過程留下的(如帶有非英文除錯字串、變數傾印),而非有意的日誌記錄
- diff 中函式參數或區域變數宣告後完全沒被使用(例如測試回呼的 `vue`、`param1`),既沒有底線前綴慣例也沒有 `eslint-disable` 或等效抑制,且沒有對應說明
- diff 修改 lint 設定(如移除或調整 `no-unused-vars` 規則、`args` 選項)卻未在 commit/PR 說明中解釋為何不再需要該檢查,或該調整會讓大量既有未使用參數失去把關
- diff 為了效能只在某個分支/呼叫點加上防呆檢查(如把 `hasTransitionClass` 檢查塞進單一呼叫處),導致同一函式的其他呼叫路徑遺漏相同檢查
- diff 新增彼此邏輯耦合的常數或規則(例如互為對應的兩條 regex/設定),卻分散在不同位置定義,未放在一起維護

## 判準
除錯輸出殘留是最容易被忽略卻最容易造成生產環境雜訊或資訊外洩的問題,尤其一旦合併就很難靠 code review 之外的機制抓到。未使用的變數/參數看似無害,但通常是重構未清乾淨、或呼叫方式改變後遺留的訊號,放著不管會讓 lint 規則的把關失效,也讓後續讀者誤以為該參數仍被使用。調整 lint 規則本身影響全專案的品質門檻,若沒有明確理由就放寬,等於默許未來所有類似問題都不會再被攔截。把檢查邏輯塞進單一呼叫點而非共用函式內部,是一種隱性耦合——所有呼叫路徑都應該享有相同保護,而不是靠呼叫者自己記得。

## 嚴重度
CRITICAL：除錯輸出可能外洩敏感資料(使用者資料、token、內部路徑)且進入正式發布分支
HIGH：明顯的開發期除錯陳述式(如帶有測試性質文字的 `console.log`)未被移除即提交,或 lint 規則調整會讓整個專案大範圍失去未使用參數的檢查且無說明
MEDIUM：單純未使用的區域變數/參數未清理但不影響行為、或防呆檢查只放在單一呼叫點而遺漏其他路徑、或耦合的常數/規則未放在一起定義

## 反例（不該報）
- 刻意保留的結構化日誌記錄(如使用 logger 而非裸 `console.log`,且用於正式的可觀測性用途)
- 未使用的函式參數是介面/型別簽章要求必須存在(如 interface 實作、event handler 固定簽章),且專案 lint 設定本身就選擇不檢查參數(如 TypeScript 本身不檢查未使用參數、`args: 'none'` 是有意的專案慣例)
- 為了效能刻意只在最常見的呼叫路徑加檢查,且已在 PR 討論或註解中說明其他路徑本來就不需要該檢查
- 調整 lint 規則同時附上清楚理由(例如證明該規則與 TypeScript 內建檢查重複),不是沒有說明的裸調整

## 出處
- https://github.com/vuejs/vue/pull/5912#discussion_r124972010
- https://github.com/vuejs/vue/pull/4051#discussion_r85483356
- https://github.com/vuejs/vue/pull/118#discussion_r9913550
- https://github.com/vuejs/core/pull/9028#discussion_r1313667323
- https://github.com/vuejs/core/pull/8681#discussion_r1292909211
- https://github.com/vuejs/core/pull/8654#discussion_r1292898658
