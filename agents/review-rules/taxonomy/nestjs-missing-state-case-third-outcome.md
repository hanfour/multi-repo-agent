---
id: nestjs-missing-state-case-third-outcome
layer: nestjs
frameworks: ["typescript@*", "node@*"]
severity_default: HIGH
---
## 觸發訊號

diff 出現以下任一種變更時，要去確認實際可能的狀態數，而不是只看程式碼寫的兩態：

- 新增或修改一個 boolean flag、二值 if/else（沒有 else-if、沒有 default分支）來處理「CLI 參數／設定值／環境變數是否存在」，且該值除了「不存在」「存在且合法」外，還可能出現「存在但是空字串／格式不完整」（例如 `--config=` 這種有 flag 卻沒值的寫法）——要去確認這第三種輸入是否被獨立處理，還是被靜靜併進其中一個既有分支。
- 新增或修改一段等待外部 Promise／driver 呼叫的邏輯，且原本的逾時或取消機制只綁在「發起呼叫」那一步（如 `maxWait`／`AbortController` 包住 `startTransaction()` 本身），但清理／回滾路徑又另外 `await` 同一個底層 Promise——要去確認「該 Promise 永遠不會 settle（driver 卡死）」這個第三態有沒有自己的界限，而不是假設它終究會成功或快速失敗。
- 新增或修改一個依賴單一 boolean（如 `isJson`）分岔輸出格式的函式，其中 try/catch 或 if/else 把「呼叫成功」「HTTP 回應非 2xx」「網路完全打不通（fetch 丟例外）」這三種結果，用同一組錯誤處理邏輯或字串组裝表達——要去確認這三態是否各自有清楚可辨識的資料形狀，而不是共用同一段程式碼硬湊。
- 新增或修改字串解析／型別轉換的驗證式，只用寬鬆轉型（如 `Number(value)`、對缺少時區的字串直接 append 固定尾綴後餵給 `new Date()`）來判斷「合法／不合法」，而輸入實際上還有第三種語意（例如「格式合法但帶著這段程式碼無法正確還原的時區 offset」）——要去確認那個中間態是被明確拒絕，還是被靜靜吃進兩態判斷裡產生錯誤結果或誤導性錯誤訊息。

## 判準

這類問題不是某一行寫錯，而是作者在設計判斷式時，心裡的模型只有「on/off」「成功/失敗」兩種可能，但實際輸入或執行環境有第三種邊界狀態。危險之處在於，這第三態通常不會讓程式當場炸掉——它會被吸收進兩態判斷裡的某一支，於是行為看起來「正常」，卻悄悄做錯事：空字串被當成合法路徑吃掉、卡死的 Promise 讓 shutdown 永遠掛著、網路錯誤和 HTTP 4xx/5xx 共用同一段訊息讓使用者分不清是哪一種、帶時區的時間字串被硬套無時區的解析邏輯得到一個看似合法但語意錯誤的 Date。資深 reviewer 抓的不是語法而是「這裡的狀態空間比程式碼認為的更大」，而且往往是那個沒被寫出來的分支最先被使用者在正式環境撞到。

## 嚴重度

CRITICAL：遺漏的第三態會造成資料被誤判為合法而寫入/使用（如時區 offset 被吃進無時區欄位）、或讓不會 settle 的操作使關機/交易清理流程無界期掛住（hang），影響服務可用性或資料正確性。

HIGH：遺漏的第三態會產生誤導性的錯誤訊息或錯誤分類，讓除錯者或呼叫端誤判失敗原因（如把 HTTP 錯誤和網路錯誤混在一起、把「格式不合法」誤報成「數值不合法」），但不會直接造成資料損毀或掛住。

MEDIUM：遺漏的第三態只影響邊界輸入（極少觸發、或有其他機制間接兜底），修正後主要是讓程式碼意圖更清楚、減少未來擴充時再次踩坑的風險。

## 反例（不該報）

- 該值本質上確實只有兩種狀態（例如某個 feature flag 只設計成 on/off，且已有文件或型別系統保證不會有第三種輸入），不要因為「理論上可以有更多值」就無中生有地要求第三分支。
- 已經用 discriminated union／exhaustive switch（TypeScript 编译器能在漏 case 時報錯）窮盡列出所有狀態，即使目前只有兩個 case，也不算遺漏——型別系統已經是防線。
- 第三態雖然存在，但團隊已有明確共識或文件說明它應該和既有某一態同義處理（例如「空字串等同未提供，此為刻意設計」且有測試佐證），此時不該報，除非該共識本身就是這次 diff 想推翻的對象。

## 出處
- https://github.com/nestjs/nest/pull/7516#discussion_r816766309
- https://github.com/nestjs/nest/pull/4479#discussion_r402095011
- https://github.com/nestjs/nest/pull/1216#discussion_r230554701
- https://github.com/nestjs/nest/pull/644#discussion_r196143640
- https://github.com/prisma/prisma/pull/29984#discussion_r3765922569
- https://github.com/prisma/prisma/pull/29970#discussion_r3762139976
- https://github.com/prisma/prisma/pull/29970#discussion_r3762139731
- https://github.com/prisma/prisma/pull/29902#discussion_r3735951277
- https://github.com/prisma/prisma/pull/29830#discussion_r3675204853
- https://github.com/prisma/prisma/pull/29830#discussion_r3675202066
- https://github.com/prisma/prisma/pull/29830#discussion_r3674775667
- https://github.com/prisma/prisma/pull/28768#discussion_r3624106252
- https://github.com/prisma/prisma/pull/29026#discussion_r3623080775
- https://github.com/prisma/prisma/pull/29688#discussion_r3529554714
- https://github.com/prisma/prisma/pull/29207#discussion_r2829141845
- https://github.com/prisma/prisma/pull/28710#discussion_r2564785184
- https://github.com/prisma/prisma/pull/28266#discussion_r2427108353
- https://github.com/prisma/prisma/pull/26678#discussion_r2007929288
- https://github.com/prisma/prisma/pull/26333#discussion_r1956081869
- https://github.com/prisma/prisma/pull/26271#discussion_r1946720598
- https://github.com/prisma/prisma/pull/26271#discussion_r1946705219
- https://github.com/prisma/prisma/pull/26271#discussion_r1946698774
- https://github.com/prisma/prisma/pull/26137#discussion_r1925209169
- https://github.com/prisma/prisma/pull/25828#discussion_r1886746572
- https://github.com/prisma/prisma/pull/24878#discussion_r1745331571
- https://github.com/prisma/prisma/pull/23637#discussion_r1543077728
- https://github.com/prisma/prisma/pull/23637#discussion_r1543072622
- https://github.com/prisma/prisma/pull/22958#discussion_r1508425157
- https://github.com/prisma/prisma/pull/22800#discussion_r1466216594
- https://github.com/prisma/prisma/pull/22665#discussion_r1453281687
- https://github.com/prisma/prisma/pull/22637#discussion_r1452535002
- https://github.com/prisma/prisma/pull/21891#discussion_r1400956397
- https://github.com/prisma/prisma/pull/21977#discussion_r1394830243
- https://github.com/prisma/prisma/pull/21333#discussion_r1345031606
- https://github.com/prisma/prisma/pull/20734#discussion_r1300116085
- https://github.com/prisma/prisma/pull/20161#discussion_r1259066194
- https://github.com/prisma/prisma/pull/19039#discussion_r1185246424
- https://github.com/prisma/prisma/pull/18900#discussion_r1176432971
- https://github.com/prisma/prisma/pull/17950#discussion_r1109885628
- https://github.com/prisma/prisma/pull/17911#discussion_r1106898682
