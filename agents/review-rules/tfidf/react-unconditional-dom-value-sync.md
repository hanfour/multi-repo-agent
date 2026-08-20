---
id: react-unconditional-dom-value-sync
layer: react
frameworks: ["react-dom@^15.0.0 - ^19.0.0"]
severity_default: HIGH
---
## 觸發訊號
diff 中對表單相關 DOM 節點做寫入時，沒有先比較目前值就直接賦值或呼叫 mutation：
- `node.value = value` / `node.value = '' + value`
- `node.checked = ...`、`node.defaultChecked = ...`、`node.defaultValue = ...`
- 透過 `setAttribute('value', ...)` / `removeAttribute('value')` 同步 controlled input
- 在 `componentDidUpdate` / commit 階段、或每次 render 後的 wrapper 函式（如 `updateWrapper`、`postMountWrapper`、`synchronizeDefaultValue` 這類角色）裡，對 `<input>`/`<textarea>`/`<select>` 的 DOM 屬性做賦值，且賦值前沒有 `if (node.value !== newValue)` 或等價的比較守衛
- 特別是 `type="number"`、`type="date"`、`type="email"` 等瀏覽器會做原生驗證/正規化的 input 類型

## 判準
即使新值與目前值完全相同，直接寫入 DOM 屬性仍會被瀏覽器當成一次「新的輸入」處理，副作用包括：
- 使用者正在輸入中的游標位置、文字選取範圍、IME 組字狀態被重置（最常見的使用者可感知 bug）
- Chrome 對 `type="number"` 在賦值 `value`/`defaultValue` 時觸發原生驗證，導致小數點被截斷、trailing zero 消失
- Safari 對 `type="email"` 賦值時可能丟出 `"The specified value <x> is not a valid email address"` 之類的原生錯誤
- 對 `radio`/`checkbox` 的 `multiple` select，未加保護的批次寫入可能連帶清掉其他選項的選取狀態（因為 `option.selected` 不會在用 `removeAttribute` 時被更新一致）
- 每次 re-render 都做不必要的 DOM 寫入，即使值沒變，也會造成多餘的 reflow 與（在受控輸入的場景）觸發不必要的 native `input`/`change` 事件迴圈

資深 reviewer 在乎的不是「這樣寫會不會 crash」，而是「這樣寫在使用者仍在輸入的當下會不會打斷體驗」——這類 bug 通常在 code review 階段用眼睛看不出來，要等到手動在瀏覽器裡輸入文字時才會發現游標跳掉。

## 嚴重度
CRITICAL：影響所有瀏覽器的所有基本文字輸入（如純文字 `<input>`），造成使用者打字時游標持續跳到欄位開頭/結尾，屬於大範圍、高頻互動路徑的資料輸入體驗性 bug。
HIGH：影響特定但常用的 input 類型（`number`、`date`、`checkbox`/`radio` 群組、`select multiple`）或特定主流瀏覽器（Chrome/Safari），造成游標跳動、原生驗證誤觸發，或連動清除其他選項的選取狀態。
MEDIUM：只在極端或少見情境下觸發（例如非受控元件初次掛載後被誤觸發一次、或影響範圍侷限在效能而非可見行為，僅造成多餘 reflow）。

## 反例（不該報）
- 在元件**初次掛載**（mount）時第一次設定 DOM 屬性——此時節點是新建的，沒有既有輸入狀態可破壞，不需要比較守衛。
- 明確設計為每次都要強制同步 DOM 以覆蓋外部（非 React）修改的程式碼，且該行為有清楚註解/測試說明這是刻意的（例如 devtools 或測試輔助工具需要精確重放 DOM 狀態）。
- 純粹操作 `className`、`style`、非表單類型元素（如 `<div>`、`<span>`）的屬性——這類屬性沒有「使用者輸入中」的狀態需要保護。
- 已經包含等價比較守衛（`if (node.value !== value)`、`shouldIgnoreValue` 之類的守衛函式）的程式碼，即使寫法上看起來像是「直接賦值」。
- 測試檔案中為了斷言／模擬瀏覽器行為而刻意重複賦值的程式碼。

## 出處
- https://github.com/react/react/pull/9584#discussion_r118924774
- https://github.com/react/react/pull/9584#discussion_r116636209
- https://github.com/react/react/pull/6406#discussion_r63074763
- https://github.com/react/react/pull/6406#discussion_r62601543
- https://github.com/react/react/pull/12780#discussion_r207953757
- https://github.com/react/react/pull/11733#discussion_r154477605
- https://github.com/react/react/pull/7397#discussion_r73263613
- https://github.com/react/react/pull/13526#discussion_r217133096
- https://github.com/react/react/pull/13114#discussion_r198950707
- https://github.com/react/react/pull/11751#discussion_r154642255
