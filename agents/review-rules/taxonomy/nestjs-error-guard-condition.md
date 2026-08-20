---
id: nestjs-error-guard-condition
layer: nestjs
frameworks: ["typescript@*"]
severity_default: CRITICAL

---
## 觸發訊號

當 diff 中出現以下任一種變更時，要跳出這個 diff 本身，去追查「呼叫端實際可能傳入的所有案例」是否都被目前的條件式涵蓋：

1. **新增或修改一個「邊界轉換函式」**（把外部/序列化資料轉成內部型別，例如 `xxxFromSerialized`、`parseXxx`、`loadXxx`）：去找同一份資料在別處（建構子、class invariant）是否已經有更嚴格的合法性檢查（例如兩個選填欄位互斥、XOR 關係）——如果轉換函式沒有重放同一條件，畸形輸入會直接繞過原本的守衛，進到下游。
2. **新增或修改一個用來比對檔名/路徑/設定來源的正規表示式或字串比對**：去列出這個系統實際支援的所有合法變體（例如同一設定可能有多種檔名慣例、多個載入目錄），確認 regex 是否只覆蓋了「預設路徑」而漏掉其他合法路徑。
3. **新增或修改依賴「到達順序」做正確性假設的邏輯**（例如批次處理、佇列合併多來源請求後直接依插入順序送出）：去確認當中介層/擴充功能/多個非同步來源插入額外項目時，原本「先進先出即代表正確順序」的假設是否還成立。

## 判準

這類問題的共同點是：程式碼裡「有」判斷式或驗證邏輯，讓人一眼覺得「已經處理過了」，但條件涵蓋的案例集合和實際輸入集合不一致，差距通常藏在別處（另一個檔案的建構子、另一種合法設定慣例、非同步時序），單看變更那幾行看不出破綻，必須主動去核對「這個條件本來應該擋住/涵蓋什麼」。這正是為什麼它是目前最大的盲區——reviewer 只讀 diff 內的邏輯是否自洽，不會主動去比對「呼叫端全集」與「條件涵蓋集」是否相等。

## 嚴重度

CRITICAL：守衛被繞過後，畸形資料會進入持久化層、契約（contract）建構或編譯結果，導致執行期才炸開，或產生錯誤但看起來合法的輸出（例如索引 `columns`/`expression` 同時存在或同時缺席卻仍被接受，繼續往下產生錯誤的 SQL）。
HIGH：條件遺漏了一種合法但較少見的輸入形態，使用者會撞到誤導性錯誤訊息或功能悄悄不生效，需要額外除錯才能定位（例如設定檔用替代路徑載入時，錯誤訊息解析邏輯抓不到檔名）。
MEDIUM：只有在特定組合下才會觸發的順序/時序假設失效，影響範圍有限但會造成資料被送錯順序、需人工排查才會發現（例如中介層插入額外請求打亂了批次送出順序）。

## 反例（不該報）

- 轉換/賦值處只是把已通過完整驗證管線（例如反序列化 + schema 驗證）的資料做型別窄化的 `as Contract` 之類的 cast，且驗證邏輯已經在更早的呼叫鏈中執行過一次——不是繞過守衛，只是型別標記，不該重複要求再驗證一次。
- 條件式涵蓋的案例確實與呼叫端一致，只是分類結果（如「精確匹配」vs「受管理」）在下游其他地方（例如另一側已驗證過的比較邏輯）本來就不消費這個分類，所以分類寬鬆不影響正確性——不是條件錯，是條件的用途被誤解。
- 移除的是一段呼叫路徑已經確定不會再進入的死碼（例如某個分支被上游邏輯完全繞過），純粹是清理，不是「條件該涵蓋卻沒涵蓋」。

## 出處

- https://github.com/prisma/prisma/pull/30008#discussion_r3776726471
- https://github.com/prisma/prisma/pull/29972#discussion_r3765074874
- https://github.com/prisma/prisma/pull/29930#discussion_r3740019772
- https://github.com/prisma/prisma/pull/29889#discussion_r3714436319
- https://github.com/prisma/prisma/pull/29808#discussion_r3683519838
- https://github.com/prisma/prisma/pull/29808#discussion_r3683519194
- https://github.com/prisma/prisma/pull/27672#discussion_r2213572430
- https://github.com/prisma/prisma/pull/26678#discussion_r2007929288
- https://github.com/prisma/prisma/pull/19538#discussion_r1212894413
- https://github.com/prisma/prisma/pull/19057#discussion_r1183850888
