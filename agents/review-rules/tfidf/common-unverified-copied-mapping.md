---
id: common-unverified-copied-mapping
layer: common
frameworks: ["*"]
severity_default: MEDIUM
---

## 觸發訊號
diff 新增或修改一份「對照表／清單／旗標」型的邏輯，且符合下列任一情況：
- PR 描述或 review 對話中出現「copied this list from」「mirrors <外部連結>」「not actually tested for any types except X」之類的字眼，代表清單是整段搬運自另一個專案／函式庫，而非依目前情境重新推導；
- 清單中只有極少數項目（如本例的 `citext`）有對應測試，其餘項目（`ltree`、`lquery`、`ltxtquery` 等）純粹是「看起來合理」但從沒跑過；
- 新增了會改變行為的旗標或自訂設定屬性（如 `rawOutputPackets?: boolean`），命名本身不足以說明用途，程式碼裡也沒有任何註解交代這是給什麼情境用的；
- switch/case 型別轉換函式（如 `fieldToColumnType`）新增或調整分支，但只在少數分支上留下來源／驗證狀態的說明。

## 判準
把別人的對照表整段複製過來，審查者無法判斷：
1. 這些項目是否真的適用於目前的資料來源／執行環境（來源專案的假設可能跟現在的情境不同）；
2. 除了明確驗證過的項目外，其餘項目只是「抄過來看起來合理」，型別轉換這類函式一旦在未測試的邊界分支上線，容易變成靜默資料錯誤或未被捕捉的例外；
3. 之後有人要維護這份清單時，分不清哪些項目「有依據」、哪些是「盲目複製」，維護成本被轉嫁給下一個接手的人。
同理，新增一個影響行為的旗標卻不寫用途，審查者無法判斷這是暫時除錯開關、效能選項還是協定相容性需求，之後也難以判斷何時能安全移除或修改。

## 嚴重度
CRITICAL：複製的對照表用於使用者資料轉換（如資料庫型別、金額、日期），未測試項目一旦命中會導致靜默資料錯誤，或在生產環境拋出未被捕捉的例外（如 `Unsupported column type` 中斷主流程）。
HIGH：對照表／清單直接影響外部協定相容性或安全判斷（如白名單、權限對照），但多數分支缺乏測試覆蓋，且完全沒有標注來源或驗證狀態。
MEDIUM：新增旗標或次要分支缺少用途說明註解，或複製清單風險較低（僅內部／開發用途），但仍缺乏來源標註與驗證狀態說明，增加後續維護成本。

## 反例（不該報）
- 純粹重構既有邏輯的格式或包裝（例如 `10000` 改成 `10_000`、把回傳值包成 `Result`/`ok()`），語意與涵蓋範圍完全沒變，既有測試覆蓋照舊，不是新增未驗證內容。
- PR 中已明確標注「這是暫緩改動，將在下一個 PR 一併重構／補測試」且維護者已知情並同意先合併（例如建議統一回傳 `Result` 型別但決定延後處理，不影響本次正確性）。
- 程式碼或 PR 描述已完整交代來源、目前驗證狀態與後續待辦（如「複製自 X，目前只驗證過 citext，其餘之後補測試並個別加測試」），此時 reviewer 若只是對註解擺放的位置（放在 if 前或 if 後）提出風格意見，屬於純風格討論，不屬於本規則要抓的「缺乏說明」問題。
- 與資料轉換／協定相容性無關的專案設定調整（如 commitlint 規則因個人風格偏好而修改），沒有正確性或資料完整性風險。

## 出處
- https://github.com/nestjs/nest/pull/8972#discussion_r788583814
- https://github.com/nestjs/nest/pull/3154#discussion_r333672051
- https://github.com/prisma/prisma/pull/22239#discussion_r1419232040
- https://github.com/prisma/prisma/pull/21918#discussion_r1395999200
- https://github.com/prisma/prisma/pull/21918#discussion_r1395672590
- https://github.com/prisma/prisma/pull/21889#discussion_r1391369933
