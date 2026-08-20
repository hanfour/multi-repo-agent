---
id: common-stale-equality-shortcut-on-mutable-collections
layer: common
frameworks: []
severity_default: MEDIUM
---
## 觸發訊號
在 watcher/updated hook 或任何「值變了才做事」的邏輯裡，新加了一段用 `===`（或 `!==`）比較 new value 與 old value（或某個快取值）來提前 return / 跳過處理的程式碼，而該值的型別是 Array、Set、Map、Object 等可變（mutable）集合型別，且值本身可能被「原地修改（mutate in place）」而非「整個替換成新的參考（replace with new reference）」。典型形態：`if (value === oldValue) { return }`、`if (!changed || toRaw(value) !== cached) { ... }`。

## 判準
`===` 對物件類型比的是參考（reference），不是內容（content）。如果呼叫端習慣對 Array/Set 等做原地變異（`arr.push(x)`、`set.add(x)`）而不是替換整個物件，這個相等性檢查會誤判「沒變」，導致本該觸發的更新邏輯被跳過。這類 bug 通常在一般測試裡看不出來，因為測試多半用「替換整個物件」的寫法，只有刻意用 mutate-in-place 的重現案例才會暴露，因此特別容易在 code review 被抓到、卻在自動化測試裡漏網。加這行 early-return 常常是為了修另一個 bug（例如避免重複觸發），但順手引入了對可變集合的回歸。

## 嚴重度
CRITICAL：此差異用在資料一致性關鍵路徑（例如金流、庫存、送單狀態）上，跳過的邏輯一旦漏執行会造成不可逆的資料 / 使用者影響。
HIGH：跳過的邏輯是 UI 更新 / 表單雙向綁定 / DOM 同步等使用者可見行為，漏執行會讓畫面呈現與底層狀態不同步，且沒有其他機制能自我修正。
MEDIUM：功能上會出現有限、可自行復原的不一致（例如下一次外部觸發的更新會覆蓋掉這次的遺漏），或影響範圍侷限在非關鍵互動流程。

## 反例（不該報）
- 比較的值型別是原始型別（string/number/boolean）或已知一定會被整個替換成新參考的物件（例如每次都是新建的 immutable 資料結構、或搭配 immutability 慣例維護的 state），此時 `===` 是正確且高效的判斷方式。
- 專案內有明確約定「所有可變集合一律用不可變模式更新（never mutate, always replace）」，且此約定有 lint 規則或型別系統強制，此時 `===` 快捷比較不會遇到本規則描述的失效場景。
- 程式碼在 early-return 之外，仍保留了其他機制（例如額外的 deep-equal 檢查、或後續必然會被另一次事件重新同步）能兜住原地變異未被偵測到的情況。

## 出處
- https://github.com/vuejs/core/pull/13637#discussion_r2207116405
- https://github.com/vuejs/core/pull/12428#discussion_r1854595994
- https://github.com/vuejs/core/pull/8639#discussion_r1649735608
