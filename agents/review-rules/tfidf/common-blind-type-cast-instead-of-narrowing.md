---
id: common-blind-type-cast-instead-of-narrowing
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM

---
## 觸發訊號
diff 中對使用者可傳入的 field/key/value 使用型別斷言（`as string`、`as any`、`as unknown as X`、專案內類似 `blindCast` 的 helper）以讓呼叫通過型別檢查；尤其常見於：某個「可用欄位」型別（如 `NumericFieldNames<...>`）是寫死的分類，而實際執行期能力其實來自另一個更權威的來源（如 schema/contract 對每個欄位宣告的 aggregate/codec 描述），兩者不一致時，合法輸入被型別系統擋下，只好在呼叫點斷言蓋過去，而不是回頭修正源頭型別。

## 判準
型別斷言等於告訴編譯器「相信我」——一旦下游實際型別不符，只有執行期才會炸掉，而且日後型別定義改了，呼叫點也不會再收到編譯錯誤提醒要跟著調整。當斷言只是為了消除「型別定義本身太窄」造成的假錯誤（例如寫死允許 numeric-only，但 contract 早就支援任何宣告過對應 aggregate 的欄位型別，包含 text/自訂 codec），正確做法是修正源頭型別定義（例如改成從 schema/contract 動態推導的 `AggregateFieldNames`），而不是在每個呼叫點各自斷言。這類斷言留下的技術債通常會在下一次重構時被忽略複製到更多地方，變成長期隱患，也讓型別系統對這條路徑失去把關能力。

## 嚴重度
CRITICAL：斷言掩蓋了會導致執行期崩潰或資料錯誤的型別不匹配，例如把未經 runtime 驗證的外部輸入直接斷言成特定 shape 後往下傳。
HIGH：斷言讓一整類原本應該被型別系統攔截的呼叫端錯誤（如傳入 contract 未宣告的欄位）在編譯期完全不再被檢查，且該呼叫點是公開 API 的一部分。
MEDIUM：斷言只是為了繞過因型別定義過窄造成的假陽性錯誤，而且已經有更精確、可從既有資料來源（schema/contract）推導出來的型別可以直接替換掉斷言。

## 反例（不該報）
- 斷言目標型別在同一個檔案的前一行已透過型別守衛（`typeof`、`in`、自訂 type predicate）驗證過，斷言只是把守衛收窄後的結果標注出來，並非繞過檢查。
- 使用專案提供的、語意明確的安全窄化 helper（例如題目情境中提到的 `castAs`）而非任意 `as`，且該 helper 本身有做對應的執行期檢查或有清楚的單向可擴型契約。
- 第三方函式庫的型別定義本身缺失或錯誤，已用 `// @ts-expect-error` 加上說明或型別聲明檔（`.d.ts`）修正計畫，斷言只是暫時性且有對應 issue 追蹤。

## 出處
- https://github.com/prisma/prisma/pull/29867#discussion_r3713418447
- https://github.com/prisma/prisma/pull/29867#discussion_r3713217194
- https://github.com/prisma/prisma/pull/29867#discussion_r3713216283
- https://github.com/prisma/prisma/pull/29867#discussion_r3711846519
