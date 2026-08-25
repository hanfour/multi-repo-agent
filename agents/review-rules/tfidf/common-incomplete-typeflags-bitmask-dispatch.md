---
id: common-incomplete-typeflags-bitmask-dispatch
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改了以 `type.flags & TypeFlags.X`（或其他 bitmask/enum flag）來判斷型別種類、再據以走不同分支的邏輯——例如判斷是否為 literal type、union/intersection 成員、discriminant property、index key type、apparent property 來源等。特別是條件式只檢查了幾個具體 flag（如 `StringLiteral | NumberLiteral`），卻沒有同時涵蓋語意相近的其他 kind（`BigIntLiteral`、`Enum`/`EnumLiteral`、`UniqueESSymbol`、pattern literal type），或是沒有先對來源型別做 unwrap/正規化（如 `unwrapNoInferType`、`getBaseConstraintOfType`、剝除 `Substitution`/`IndexedAccess` 包裝）就直接檢查 flags。

## 判準
以 bitmask 判斷型別種類的程式碼很容易「漏掉一個 case」而不會在編譯期或大多數測試中曝光，因為漏掉的分支通常只有在特定、罕見的型別組合下才會被觸發，例如 BigInt literal 當索引、enum member 當 discriminant、或型別被 `NoInfer`/`Substitution` 包裝過。這類問題不會拋錯，而是靜默地落入錯誤的 fallback 分支（通常是最寬鬆、最保守，或乾脆回傳 `any`/`unknown` 的那一支），使型別檢查結果錯誤卻很難察覺，往往要等使用者回報一個很刁鑽的型別組合才會浮現。資深 reviewer 看到新增的 flag 判斷式時，會先問「這個 mask 是否窮舉了所有應該匹配的 kind？」以及「這個型別在檢查 flags 前是否需要先正規化/unwrap？」

## 嚴重度
CRITICAL：漏掉的 case 會讓型別檢查器對常見型別（如字串/數字 literal、union 展開、assignability 判斷）產生錯誤的推導結果，或錯誤地放行本該報錯的程式碼（false negative）。
HIGH：漏掉的 case 只影響邊緣型別（BigInt literal、const enum member、模板字面量萬用字元、包裝型別如 NoInfer/Substitution）但仍會造成型別結果不一致，或需要額外呼叫端手動 unwrap 才能得到正確行為。
MEDIUM：漏掉的 case 只影響診斷訊息的準確度（例如 index type 錯誤訊息顯示了未正規化前的型別字串），不影響型別檢查本身的正確性。

## 反例（不該報）
- 明確排除某個 kind 是刻意設計，且旁邊有註解或型別系統本身保證呼叫端已先過濾掉該 kind（例如已在更上層做過窄化）。
- 新增的 flag 判斷只是把既有邏輯抽成獨立函式、行為完全不變的純重構，涵蓋的 case 集合前後一致。
- 為效能加入的「快速路徑」（fast path）判斷，其後仍會 fallback 到涵蓋所有 case 的完整邏輯處理其餘型別，並非漏判。

## 出處
- https://github.com/microsoft/TypeScript/pull/60271#discussion_r2587025690
- https://github.com/microsoft/TypeScript/pull/61350#discussion_r1980347752
- https://github.com/microsoft/TypeScript/pull/58608#discussion_r1680008756
- https://github.com/microsoft/TypeScript/pull/58608#discussion_r1676476875
- https://github.com/microsoft/TypeScript/pull/59834#discussion_r1741537639
- https://github.com/microsoft/TypeScript/pull/56932#discussion_r1459619119
- https://github.com/microsoft/TypeScript/pull/52542#discussion_r1104834508
- https://github.com/microsoft/TypeScript/pull/37481#discussion_r396690986
- https://github.com/microsoft/TypeScript/pull/25886#discussion_r230511345
- https://github.com/microsoft/TypeScript/pull/32116#discussion_r315377381
