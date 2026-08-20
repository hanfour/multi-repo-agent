---
id: common-inconsistent-naming-or-duplicate-helper
layer: common
frameworks: []
severity_default: MEDIUM
---
## 觸發訊號
diff 新增一個 internal/exported 的函式、enum 成員或型別，且符合下列任一情況：
1. 命名不符合同檔案或同模組內既有的命名慣例（例如同模組其他函式都以 `...Worker` 結尾，新函式卻叫 `...Impl`；或新 enum 成員的命名風格跟既有成員不一致，如 `Compound` 旁邊冒出語意不明的 `CompoundLike`）。
2. 新函式的邏輯跟程式庫裡已存在、只是名字不同的另一個函式重疊（例如新寫一個 `generateIndentString`，但別處已有功能相同的 `getIndentationString`；或新增 `isDynamicImport`，但別處已有語意相同的 `isImportCall`）。
3. 命名選字帶有不必要的文化/語言隱喻或含糊詞（例如用 "left-handed/right-handed" 描述方向性 API，或用不具語意的縮寫）。

## 判準
命名不一致會讓未來的人用 grep/搜尋找不到相關程式碼，也會讓同一份邏輯散落多處、各自維護：改 bug 時只改到其中一份，另一份沒人記得要一起改，久了行為就會分歧。這在大型、長期維護的程式庫裡特別致命，因為原作者往往已經離開專案，只有 code review 當下這個時間點能攔住重複實作。命名選字帶隱喻/含糊詞則會增加非母語或新進成員的理解成本，屬於低成本就能避免的可讀性債。

## 嚴重度
CRITICAL：重複邏輯出現在安全性、權限判斷或計費等關鍵路徑上，未來只修其中一份會造成行為不一致且難以察覺。
HIGH：新函式的邏輯明確與既有函式重複（非表面相似而是真的做同一件事），且該邏輯未來很可能需要修正/擴充，分裂維護風險高。
MEDIUM：純粹命名風格不一致（不影響行為），但降低可搜尋性與程式碼一致性，例如函式後綴不符慣例、enum 成員命名邏輯跳脫既有模式。

## 反例（不該報）
- 新函式雖然名稱看起來相似，但語意/用途本質不同（不是同一件事的兩種寫法），不算重複實作。
- 作者在同一個 PR 討論串裡已經承認命名待調整、且會在合併前修正（例如 "sorry for naming, will rename to X" 這種正在收斂中的暫定命名），不需要重複提報。
- 檔案/模組本身既有命名慣例就不一致（新增前就已經是各種風格混雜），新程式碼只是延續既有主流風格之一，不算引入新的不一致。
- 兩個函式名稱不同但刻意保留（例如新函式是舊函式的公開別名並加了 `@deprecated`，用於漸進式遷移），這是刻意的相容性設計而非重複實作疏忽。

## 出處
- https://github.com/microsoft/TypeScript/pull/52016#discussion_r1096177608
- https://github.com/microsoft/TypeScript/pull/52493#discussion_r1090333979
- https://github.com/microsoft/TypeScript/pull/41294#discussion_r561455802
- https://github.com/microsoft/TypeScript/pull/39656#discussion_r533820095
- https://github.com/microsoft/TypeScript/pull/37376#discussion_r398971151
- https://github.com/microsoft/TypeScript/pull/37376#discussion_r398810935
- https://github.com/microsoft/TypeScript/pull/33402#discussion_r324933380
- https://github.com/microsoft/TypeScript/pull/8444#discussion_r61957864
- https://github.com/microsoft/TypeScript/pull/3084#discussion_r29978903
