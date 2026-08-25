---
id: react-duplicated-event-type-tables
layer: react
frameworks: ["react-dom@*"]
severity_default: MEDIUM
---
## 觸發訊號
Diff 新增或修改與事件系統相關的 map/list 字面量（例如 `eventTypes`、`discreteEventPairsForSimpleEventPlugin`、`interactiveEventTypeNames`、`otherDiscreteEvents`、`phasedRegistrationNames`、`dependencies: [...]`）時，同一份事件資訊（`DOMTopLevelEventTypes` enum 值、對應的字串名稱、bubbled/captured 命名）被同時手寫在兩個以上獨立的陣列或物件字面量裡；或某處用 `keyOf({onXxx: true})` 這類間接寫法產生字串鍵，而旁邊已經有另一份明碼字串清單；或某個常數/函式旁的註解描述著舊行為（例如「不允許監聽 mouseOver」「維持 focus/blur 為 discrete event」）但周圍程式碼已被改動。

## 判準
這類手動維護的平行資料結構，每次新增、刪除或重新命名一個事件類型，都必須靠人工在所有出現的地方同步修改；一旦漏掉其中一處，不會有編譯期或型別檢查提醒，只會在執行期出現該事件遺漏 dispatch、優先權誤判等難以察覺的行為分歧。已知曾被 reviewer 抓到的具體型態包括：`dependencies` 欄位手動重複寫一次本來就能從既有變數（如 `topLevelType`）直接引用的值；已經不再需要保留原始用途（例如避免 minifier 改壞字串）的 `keyOf()` 間接層被繼續沿用增加閱讀成本。另一類是註解本身描述的行為已經被後續修改推翻，卻沒有一併更新或刪除，會誤導未來讀者對現有邏輯做出錯誤假設。

## 嚴重度
CRITICAL：事件類型資訊分散在多張表中，其中一張被新增/修改但另一張忘記同步，導致某類事件（例如新的 pointer/focus 事件）在部分表中缺席，造成執行期行為不一致（事件不會被 dispatch、優先權判斷錯誤等）。
HIGH：新增或修改的 `dependencies`／config 手動重複複製了本可直接引用既有變數的值（而非引用單一來源），日後上游改名或增刪事件時會產生分歧且沒有任何測試或型別能提前攔截。
MEDIUM：保留已無必要的間接層（如殘留的 `keyOf()`）但目前資料仍一致、尚未造成行為分歧，屬於可讀性/維護成本問題；或程式碼旁註解描述的行為已與目前實作不符（stale comment），但不影響現有執行正確性。

## 反例（不該報）
若同一份事件清單只出現一次，其他表格都是透過程式邏輯（map/reduce/import/衍生運算）從該唯一來源動態產生，並非人工另外複製一份，則不算重複維護，不該報。單純把 `keyOf({onAbort: true})` 這類包裝改成裸字串 `'onAbort'`、且周遭沒有殘留另一份需要人工同步的重複資料源時，這只是移除多餘間接層的清理動作，不會引入新的重複風險，不該報。測試檔案中兩個測試名稱相似但涵蓋不同斷言／情境時，不該視為重複測試而要求合併。

## 出處
- https://github.com/react/react/pull/19186#discussion_r450360204
- https://github.com/react/react/pull/19186#discussion_r444929811
- https://github.com/react/react/pull/12629#discussion_r184123475
- https://github.com/react/react/pull/11631#discussion_r152885050
- https://github.com/react/react/pull/10339#discussion_r130668742
- https://github.com/react/react/pull/7616#discussion_r76870143
- https://github.com/react/react/pull/7615#discussion_r76846092
- https://github.com/react/react/pull/967#discussion_r9163992
- https://github.com/react/react/pull/462#discussion_r8207875
