---
id: common-redundant-type-guaranteed-code
layer: common
frameworks: ["typescript@*"]
severity_default: LOW

---
## 觸發訊號
- 新增一個「正規化 / 驗證」函式，其參數型別已經是窮舉聯合型別（如 `x: 'a' | 'b'`），函式內部卻用 if/switch 把每個值映射回自己，例如：`function normalizeX(x: 'a' | 'b'): 'a' | 'b' { if (x === 'a') return 'a'; return 'b' }` —— 呼叫端傳入的值本來就只能是這兩者之一，TypeScript 已在編譯期擋掉其他情況。
- 在多個測試檔案裡逐一加上同樣一句說明（例如「這個測試驗證 X 行為」），但這句話對整個測試套件的每個檔案都成立，不是這個檔案特有的資訊。
- 在某個測試 setup 裡加上一段設定，只是為了覆蓋一個已經被另一條獨立測試（例如 E2E）完整覆蓋掉的情境，導致同一個不變量在兩處被重複斷言。

## 判準
這類程式碼、文件或測試不會多抓到任何 bug：型別系統或既有的另一個測試套件已經把這個不變量鎖住了，新增的東西只是把「型別/測試已經保證的事」用執行期程式碼或文字再講一次。留著它的成本不是它本身會出錯，而是之後維護的人要花時間確認「這個函式/這段設定到底有沒有實際作用」，而且一旦來源型別或上游測試改了，這裡的複製品很容易忘記同步更新，變成一個過時但看起來仍然合法的殘留物。resource reviewer 通常會直接建議刪掉，把邏輯留給型別系統或既有測試單一負責。

## 嚴重度
CRITICAL：（此類問題本質上是冗餘而非錯誤，通常不會到 CRITICAL）
HIGH：那段「重複保證」程式碼其實掩蓋了型別系統與執行期行為不一致的風險（例如上游型別是用 `as` 斷言硬轉、並不可信），若之後被誤當作純冗餘刪掉，會讓真正需要的邊界檢查消失
MEDIUM：重複的正規化/驗證邏輯或測試設定散落在多個檔案，型別或上游測試改動時容易漏改，造成不一致
LOW：單純多餘、不影響正確性的恆等函式，或多個測試檔案裡重複但無害的說明文字/設定

## 反例（不該報）
- 輸入型別來自 `string`、外部 API 回應、使用者輸入、或反序列化後的 JSON 等 TypeScript 無法在編譯期保證其值域的來源——此時 runtime 正規化/驗證是必要的邊界檢查，不算重複。
- 該函式雖然目前呼叫端型別是窮舉聯合型別，但函式本身是對外公開的 API（可能被非 TypeScript 呼叫端或未做型別檢查的程式碼呼叫），保留 runtime 正規化是合理的防禦性設計。
- 多個測試檔案看起來有相似的設定或說明，但實際驗證的情境並不相同（不是逐字複製貼上同一句話），此時不算冗餘。

## 出處
- https://github.com/prisma/prisma/pull/29459#discussion_r3072461191
- https://github.com/prisma/prisma/pull/28976#discussion_r2653170138
- https://github.com/prisma/prisma/pull/28976#discussion_r2653099062
- https://github.com/prisma/prisma/pull/20594#discussion_r1295218408
- https://github.com/prisma/prisma/pull/18571#discussion_r1153364592
- https://github.com/prisma/prisma/pull/16721#discussion_r1047498409
