---
id: common-pointfree-callback-arity-mismatch
layer: common
frameworks: ["typescript@*", "javascript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中把原本明確轉發單一參數的 lambda（如 `arr.map(x => fn(x))`、`items.forEach(item => cb(item))`）改寫成 point-free 形式直接傳函式參照（`arr.map(fn)`、`items.forEach(cb)`），或是新增程式碼一開始就用 point-free 形式把函式直接丟給 `Array.prototype.map/forEach/filter/reduce`、`Map`/自訂集合工具的 `forEach`/`map`，而目標函式（`fn`/`cb`）本身簽章中含有第二個參數（不論是否標為 optional），且該第二個參數的型別/語意與呼叫端傳入的 index、key 或 array 剛好相容或被寬鬆地接受（例如 `string | number`、`any`，或該參數型別恰好能吃下 index/key 而不報型別錯誤）。

## 判準
`map`/`forEach` 等迭代方法會固定傳入第二、第三個位置參數（index 或 key、原陣列/Map）。如果被當作 callback 直接傳入的函式剛好也接受第二個參數，這些位置參數會被靜默地餵進去，改變函式的實際行為 —— 而不是編譯或執行期噴錯。這是經典的 `["6","8","10"].map(parseInt)` 陷阱的變體：第二個參數被誤用為 radix、index 被誤用為 key 型別的一部分，或是像 review 中指出的「Map 傳給 callback 的第二參數會弄亂 `getTargetOfMappedDeclarationInfo` 的 `original` 初始值」。這類 bug 難以被發現，因為在測試常見的小資料（例如 index 0、或剛好 falsy）下行為看起來正常，只有在特定 index/key 組合下才會暴露錯誤結果，且型別系統若對第二參數用了寬鬆型別（`any`、聯合型別、optional）便不會攔下。

## 嚴重度
CRITICAL：該路徑影響編譯輸出、對外 API 回傳值或使用者可見結果，且第二參數被吃入後型別檢查仍會通過（無編譯期保護），現有測試也不會涵蓋非首位 index/key 的情境。
HIGH：型別系統允許此呼叫（無 TS 錯誤），且沒有針對多筆/非零 index 或非首個 key 的單元測試能捕捉行為差異。
MEDIUM：雖然簽章上存在風險，但呼叫範圍小、有對應測試覆蓋多筆資料，或目標函式的第二參數已明確標註且與呼叫端語意一致（風險已被驗證過但仍建議標註清楚以防未來維護者誤解）。

## 反例（不該報）
- 目標函式（`fn`/`cb`）只接受一個參數、沒有第二個參數可被吃入，point-free 化是安全的重構。
- 呼叫端明確使用箭頭函式只轉發第一個參數（如 `x => fn(x)`），即使目標函式有多個參數，也不會被自動帶入 index/key，因為呼叫時的引數已被限制。
- 目標函式的第二參數型別與迭代方法傳入的 index/key 型別完全不相容，TypeScript 編譯會直接報型別錯誤（此時屬於編譯期防線已生效，不是隱藏 bug）。
- 目標函式的第二參數有明確、與呼叫情境相符的預設值或型別窄化（例如就是設計來接收 index，而呼叫端也確實需要 index 語意一致），這是刻意設計而非誤用。

## 出處
- https://github.com/microsoft/TypeScript/pull/60646#discussion_r1875045818
- https://github.com/microsoft/TypeScript/pull/57679#discussion_r1540094336
- https://github.com/microsoft/TypeScript/pull/56902#discussion_r1468181360
- https://github.com/microsoft/TypeScript/pull/52996#discussion_r1409630068
- https://github.com/microsoft/TypeScript/pull/55484#discussion_r1303407242
- https://github.com/microsoft/TypeScript/pull/48560#discussion_r855651142
- https://github.com/microsoft/TypeScript/pull/47409#discussion_r791096399
- https://github.com/microsoft/TypeScript/pull/44006#discussion_r634832623
- https://github.com/microsoft/TypeScript/pull/40634#discussion_r508067977
- https://github.com/microsoft/TypeScript/pull/40593#discussion_r489798038
- https://github.com/microsoft/TypeScript/pull/33537#discussion_r329713800
- https://github.com/microsoft/TypeScript/pull/32372#discussion_r327780760
- https://github.com/microsoft/TypeScript/pull/30937#discussion_r275487236
- https://github.com/microsoft/TypeScript/pull/30411#discussion_r266675545
- https://github.com/microsoft/TypeScript/pull/25283#discussion_r198903797
- https://github.com/microsoft/TypeScript/pull/19175#discussion_r146413441
- https://github.com/microsoft/TypeScript/pull/12715#discussion_r93984785
- https://github.com/microsoft/TypeScript/pull/10230#discussion_r74116692
