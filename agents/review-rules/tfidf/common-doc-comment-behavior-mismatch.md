---
id: common-doc-comment-behavior-mismatch
layer: common
frameworks: []
severity_default: LOW
---
## 觸發訊號
PR 中新增或修改的函式/方法命名、型別簽名、JSDoc 或行內註解，宣稱某種行為（例如「會套用 completion」「兩型別 identical/subtype」「forEach 會走訪整個集合」），但：(a) 實際實作只做名稱字面之外的子集動作或有例外分支；(b) 已知的邊界情況（例如 callback 在迭代過程中修改被迭代的集合、導致結果不準確）沒有被註解揭露；(c) 註解寫得過長，超出目標呈現介質（editor hover/tooltip）的顯示能力而被截斷，造成讀者只看到片段資訊。

## 判準
Reviewer 在意的不是「有沒有寫註解」，而是註解/命名跟實際行為之間有沒有落差：一旦命名或文件比實作誇大或含糊，後續呼叫者會依照字面意義做出錯誤假設（以為 helper 會自動套用 completion、以為 forEach 對 mutation 安全），等到出錯才發現行為不符，除錯成本遠高於當下補一行精確說明的成本。對型別系統這類核心語意判斷函式（isIdenticalTo/isSubtypeOf 之類），呼叫端幾乎不會去讀實作，文件的精確度直接決定使用是否正確。同時也要考慮呈現介質的限制——過度冗長的 JSDoc 在某些工具（如 vscode hover）會被裁切，因此該留意精簡度與資訊優先順序。

## 嚴重度
CRITICAL：無。
HIGH：公開 API 或跨模組共用的核心工具函式（型別系統、資料結構等基礎設施），其命名/型別簽名/文件字面意義與實際實作行為不一致，呼叫端無法從介面本身推導出正確用法，容易產生誤用或錯誤結果。
MEDIUM：內部或測試用 helper 的命名/註解與行為有落差，或已知邊界情況（如迭代中 mutation 造成結果不準確）未被記錄在附近的註解中，可能誤導日後維護者；或既有测试 baseline 的重寫理由未被說明清楚（例如把等價寫法改回原始寫法卻沒解釋為何要保留舊寫法）。

## 反例（不該報）
- 函式命名/註解本身已清楚界定範疇（例如「只執行 code action、不負責套用 completion 本身」這種明確澄清），不需要在每個呼叫點重複補充。
- 若測試 baseline 的改寫只是語意等價的寫法（例如把手寫的 infer 條件式換成等價的內建 utility type），且沒有改變任何可觀察行為，不應僅因「原始寫法也可以」而要求回退或補充額外文件。
- 已知邊界情況雖然沒有寫成獨立註解，但可以直接從函式簽名/型別或同模組既有文件明確推導出來，不需要每處重複標注。

## 出處
- https://github.com/microsoft/TypeScript/pull/58873#discussion_r1643540290
- https://github.com/microsoft/TypeScript/pull/49627#discussion_r923590243
- https://github.com/microsoft/TypeScript/pull/42583#discussion_r570441553
- https://github.com/microsoft/TypeScript/pull/9943#discussion_r72181269
