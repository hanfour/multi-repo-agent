---
id: common-date-timezone-determinism
layer: common
frameworks: []
severity_default: HIGH
---
## 觸發訊號
diff 中出現以下任一種寫法：(1) 用 `Date` 物件的「本地時間」存取方法——`getFullYear()`/`getMonth()`/`getDate()`/`getHours()` 等——去格式化日期字串或組出 `YYYY-MM-DD` 之類的值，尤其是搭配 `<input type="date">` 的 `valueAsDate`、或任何跨時區儲存/傳輸/比對日期的情境；(2) 測試程式碼（`*.spec.ts`/`*.test.ts`）裡用 `Date.now()` 或不帶參數的 `new Date()` 產生時間戳，直接拿來當斷言依據或測試資料輸入，而不是寫死一個固定值。

## 判準
`getFullYear`/`getMonth`/`getDate` 是依執行環境的本地時區計算的，但瀏覽器 `<input type="date">.valueAsDate`、後端存的日期欄位多半是 UTC 午夜。對負時區偏移地區（例如美洲）的使用者，用本地時間去讀一個 UTC 午夜的 `Date`，會整個退一天——使用者明明選了某一天，存下來/顯示出來卻變成前一天，而且這種 bug 只有在特定時區才會出現，本地測試（多半跑在 UTC 或東半球時區）很難自然發現。測試裡用 `Date.now()`/`new Date()` 而非固定時間戳，則是另一種風險：測試結果依賴「執行當下究竟是幾點」，兩次呼叫可能跨越秒/毫秒邊界造成間歇性失敗，而且讀 case 的人看不出這個測試到底在斷言哪個具體時間點，可讀性與可重現性都變差。

## 嚴重度
CRITICAL：涉及金流結算日、排程觸發時間、法規時效（合約到期日、訂單日期）等業務關鍵日期，時區誤判會造成資料錯誤且事後難以復原或稽核。
HIGH：使用者可見的日期輸入/顯示元件（日期選擇器、表單送出的日期欄位）在特定時區下選到的日期與實際儲存/顯示的日期差一天，直接是功能性 bug。
MEDIUM：純測試程式碼用 `Date.now()`/`new Date()` 產生非固定時間戳，增加 flaky 風險、降低斷言可讀性，但不影響 production 邏輯正確性。

## 反例（不該報）
明確只需要「相對時間量測」或「產生單調遞增的暫時唯一識別碼」而使用 `Date.now()`（例如效能計時、debounce/throttle 的時間差計算、生成暫存 key），此時本地/UTC 差異或值是否固定都不影響正確性，不該報。同樣，若功能本來就是刻意要呈現「使用者所在時區的本地時間」（例如顯示「你的裝置目前時間」、本地時鐘元件），用 `getFullYear`/`getMonth`/`getDate` 是正確選擇，不該報；只有在資料語意是「與時區無關的某一天」卻用本地時間方法讀寫時才成立。

## 出處
- https://github.com/vuejs/vue/pull/8113#discussion_r193672677
- https://github.com/vuejs/vue/pull/8113#discussion_r193660840
- https://github.com/vuejs/vue/pull/8113#discussion_r193659801
- https://github.com/vuejs/vue/pull/2663#discussion_r59451977
- https://github.com/vuejs/core/pull/14786#discussion_r3198778105
- https://github.com/vuejs/core/pull/14695#discussion_r3056190241
- https://github.com/vuejs/core/pull/13703#discussion_r2249431389
- https://github.com/vuejs/core/pull/9083#discussion_r1722965909
- https://github.com/vuejs/core/pull/9083#discussion_r1632195509
- https://github.com/vuejs/core/pull/7786#discussion_r1573016962
- https://github.com/vuejs/core/pull/9129#discussion_r1422262254
- https://github.com/vuejs/core/pull/9400#discussion_r1362042045
- https://github.com/vuejs/core/pull/9400#discussion_r1361872378
- https://github.com/vuejs/core/pull/9069#discussion_r1315572761
- https://github.com/vuejs/core/pull/8018#discussion_r1159573045
- https://github.com/vuejs/core/pull/3798#discussion_r695513410
