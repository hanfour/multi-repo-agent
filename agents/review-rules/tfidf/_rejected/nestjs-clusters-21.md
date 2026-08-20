---
id: common-array-includes-breaks-discriminant-narrowing
layer: common
frameworks: ["typescript@>=4.0"]
severity_default: MEDIUM
---
## 觸發訊號
把原本用來窄化 discriminated union 的 `x === A || x === B || x === C` 或多個 `else if (x === A)` 分支，改寫成 `[A, B, C].includes(x)`（或 `Set.has(x)`）放進同一個 `if`/`else if` 條件；且該分支內接著存取只有窄化後才會出現的屬性（例如 `warning.affected.map(it => it.model)` 這種依賴 union 特定成員型別的欄位）。常見於把一長串 `===` 判斷「重構得更短」的 PR。

## 判準
TypeScript 的 control flow narrowing 認得 `===`／`||` 字面值比較鏈，因為它們是 literal type guard；但 `Array.prototype.includes()` 回傳的是泛用 `boolean`，不帶字面型別資訊，不會被編譯器當成 type guard。結果是條件式雖然邏輯等價、程式碼變短也更好讀，但分支內原本被窄化成特定 union member 的屬性（如 `warning.affected`）會整個退化成 `any` 或全部 union 分支的聯集型別 —— 編譯器從此對這段程式碼的欄位存取失去保護，之後有人加新的 union member 或打錯欄位名，TS 不會再報錯，是靜默的型別安全退化，不是功能性 bug，但會在往後的維護中被複用成理所當然的模式。

## 嚴重度
CRITICAL：分支內已經存在因窄化消失而本該被 TS 抓出、但現在抓不到的錯誤欄位存取（例如存取的欄位其實只屬於 union 的另一個 member），也就是型別安全網消失後正好蓋住了一個真實的 latent bug。
HIGH：該 discriminated union 之後還會持續擴充 member（如錯誤碼、事件型別逐版新增），且此處的窄化正是後續分支正確存取欄位的唯一防線；一旦用 `.includes()` 取代，新增 member 時最容易漏改而不自知。
MEDIUM：純粹是把既有 `===` 鏈改寫得更短，目前分支內沒有實際型別錯誤，但確實讓該區塊的欄位存取型別退化為 `any`／過寬聯集，是預防性問題而非立即性問題。

## 反例（不該報）
`.includes()` / `Set.has()` 只用來做單純的 membership 檢查、後面沒有依賴窄化後的欄位型別（例如只是拿來決定要不要 early return，或结果只用在字串插值而非物件屬性存取）；或者該屬性在窄化前後本來就是 `any`／`unknown`，沒有型別資訊可窄化；或者這段本來就沒有 discriminated union（各分支的物件形狀完全相同），只是單純的錯誤碼白名單判斷。

## 出處
- https://github.com/prisma/prisma/pull/18701#discussion_r1166581696
- https://github.com/prisma/prisma/pull/11872#discussion_r809172031
