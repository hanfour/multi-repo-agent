---
id: common-unsafe-string-coercion-for-codegen-or-messages
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
把型別不保證是純字串的值（`...args: any[]`、object/JSON 值、動態識別字、可能含引號或特殊字元的字串）拿去用 `Array.prototype.join()`、`+` 串接、或手動包引號的樣板字串（例如 `` `'${x}'` ``、`` `$setup[${x}]` ``、`` `${arr.join(', ')}` ``）組出以下兩種輸出，而不是用 `JSON.stringify()`：
1. 要餵給程式碼產生器（codegen）、之後會被當成 JS 原始碼執行/解析的字串字面值
2. 要顯示給使用者的錯誤/警告訊息（例如 `msg + args.join('')`）

## 判準
`join()`／樣板字串對值做隱式 `toString()` 轉換，遇到 `Symbol` 會直接丟 `TypeError`（未被防禦時會讓呼叫端崩潰，而不是印出預期的警告訊息），對其他邊界型別（`undefined`、有自訂 `toString` 的物件）也可能產出誤導性的輸出。手動包引號在值本身含有該引號字元或需要跳脫時，會產生語法錯誤或語意錯誤的產生碼。`JSON.stringify()` 對這兩個場景（人類可讀顯示、程式碼字面值跳脫）都能給出可預期、正確跳脫的結果，reviewer 在這幾則討論裡都是把它當成實際 bug 在談，不是風格偏好。

## 嚴重度
CRITICAL：輸入來源不可控（例如公開 API 的 `...args`），且 `join()`／樣板字串轉換會對某些合法輸入（如 `Symbol`）丟出未被捕捉的 `TypeError`，導致呼叫端整個崩潰而非正常降級成警告訊息。
HIGH：手動包引號（如 `` `'${x}'` `` 或 `` `$setup[${x}]` ``）用來產生「之後會被執行/解析」的程式碼字串，且被包的值可能含有分隔字元（引號）或其他需跳脫字元，會產出語法錯誤或行為錯誤的產生碼。
MEDIUM：目前 join()／字串串接的對象在現有呼叫路徑上都是純字串，但函式簽名（如 `...args: any[]`）或呼叫端讓未來混入非字串值變得可能，屬於潛在脆弱而非當下已觸發。

## 反例（不該報）
- 被 join／串接的陣列或值在型別上是靜態、已知只會是不含分隔字元/特殊字元的純字串（例如把一串已驗證過的合法識別字用逗號 join 成 import 陳述式），不該報。
- 純字面值/已知安全字串的串接，且結果既不是要被當程式碼執行、也不是要顯示給使用者的訊息，不該報。
- `.prettierrc`、`.oxfmtrc.jsonc`、`tsconfig*.json` 這類設定檔裡對 `semi`／`singleQuote`／`trailingComma`／`ignorePatterns` 等格式化偏好的調整，屬於風格設定變更，不屬於本規則要抓的字串安全性問題，不該報。

## 出處
- https://github.com/vuejs/vue/pull/4528#discussion_r93377555
- https://github.com/vuejs/vue/pull/4528#discussion_r93374038
- https://github.com/vuejs/core/pull/15110#discussion_r3610189658
- https://github.com/vuejs/core/pull/14238#discussion_r2644609904
- https://github.com/vuejs/core/pull/14238#discussion_r2644529524
- https://github.com/vuejs/core/pull/9249#discussion_r2191417833
- https://github.com/vuejs/core/pull/9249#discussion_r2191414361
- https://github.com/vuejs/core/pull/10457#discussion_r1512818592
- https://github.com/vuejs/core/pull/10414#discussion_r1505363551
- https://github.com/vuejs/core/pull/10414#discussion_r1505233815
- https://github.com/vuejs/core/pull/10414#discussion_r1504532557
- https://github.com/vuejs/core/pull/8785#discussion_r1367825635
- https://github.com/vuejs/core/pull/8785#discussion_r1367746994
- https://github.com/vuejs/core/pull/8978#discussion_r1320575412
- https://github.com/vuejs/core/pull/9162#discussion_r1318903246
- https://github.com/vuejs/core/pull/9162#discussion_r1318853027
- https://github.com/vuejs/core/pull/9162#discussion_r1318710388
- https://github.com/vuejs/core/pull/8681#discussion_r1293312630
- https://github.com/vuejs/core/pull/707#discussion_r376813685
