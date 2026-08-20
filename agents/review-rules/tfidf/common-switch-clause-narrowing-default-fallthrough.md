---
id: common-switch-clause-narrowing-default-fallthrough
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 裡新增或修改的函式，簽章帶有一組成對的 switch 分支範圍參數（如 `clauseStart`/`clauseEnd`，或等價的 index pair），並另外算出 `defaultIndex`（default clause 在 switch 裡的位置），再用類似 `defaultIndex >= clauseStart && defaultIndex < clauseEnd` 的判斷式得出 `hasDefaultClause`，接著依此分岔出兩套不同的型別/狀態窄化（narrowing）邏輯——一套處理落在該範圍內的具名分支、另一套處理 default 分支。也包含這類函式因為要單獨處理「default 分支 + fallthrough」而新增的分支判斷或特殊 case。

## 判準
switch 的 clause 之間可以 fallthrough，代表某段分支範圍內「哪些 case 為真」不是互斥的獨立事實，不能單純假設「非本分支即為假」。當程式碼把 default 分支的窄化邏輯建立在「其他分支都不成立」的假設上，卻沒有同時處理該範圍內其他 case 可能因為沒有 `break` 而共享同一段程式碼、因此其實無法排除為真的情況，窄化出來的型別會比實際寬鬆或錯誤地收窄，而這是型別系統的健全性（soundness）問題——編譯器可能因此漏抓真正的型別錯誤，或誤報原本合法的程式碼有錯。這類 bug 只在特定的 default+fallthrough 組合下才會現形，一般測試很難覆蓋到，且審查者往往要重新推導一次語意才能確認邏輯對不對（如本 cluster 裡多則留言都是 reviewer 重新演算後才發現需要澄清或修正）。此外，range 邊界的算式本身（`>=` / `<` 的方向、`clauseStart === clauseEnd` 這類邊界情況）也容易寫錯而讓 default 判斷落在錯誤的位置。

## 嚴重度
CRITICAL：default clause 與 fallthrough 的交互作用沒有被正確處理，導致窄化結果不健全（unsound）——編譯器/分析器對某些合法程式碼誤報錯誤，或對本該被抓到的錯誤沒有反應，且沒有對應的迴歸測試涵蓋該 fallthrough 組合。
HIGH：`clauseStart`/`clauseEnd`/`defaultIndex` 的範圍判斷式寫錯（例如邊界方向、`clauseStart === clauseEnd` 特例遺漏），導致實際被視為「in range」的 clause 集合與預期不符，但影響範圍尚未確認是否造成可觀察的健全性問題。
MEDIUM：新窄化函式與既有同類函式（例如既有的 `typeof` 窄化）在用詞、變數命名或結構上不一致，增加後續維護者理解成本，但邏輯本身正確。

## 反例（不該報）
純粹搬移既有 switch-range 邏輯位置、不改變其行為的重構（例如「code was already there, it just moved a bit」這類情況）；只是加上 TODO 註解或留言、未觸及計算邏輯的變更；已經過 reviewer 重新演算並確認「這裡其實用不到」而移除的死路徑（即該行為本來就不會被觸發，移除是安全的）；純粹的變數/型別宣告方式調整（例如把物件字面量改成建構函式）而未牽動 clause range 或 default 判斷的計算邏輯。

## 出處
- https://github.com/microsoft/TypeScript/pull/55991#discussion_r1349235843
- https://github.com/microsoft/TypeScript/pull/55991#discussion_r1349143142
- https://github.com/microsoft/TypeScript/pull/55991#discussion_r1347784281
- https://github.com/microsoft/TypeScript/pull/53681#discussion_r1321506006
- https://github.com/microsoft/TypeScript/pull/47282#discussion_r779031191
- https://github.com/microsoft/TypeScript/pull/38839#discussion_r581286231
- https://github.com/microsoft/TypeScript/pull/33510#discussion_r326310893
- https://github.com/microsoft/TypeScript/pull/17278#discussion_r131989315
- https://github.com/microsoft/TypeScript/pull/17278#discussion_r128118397
