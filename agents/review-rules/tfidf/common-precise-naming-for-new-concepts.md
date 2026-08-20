---
id: common-precise-naming-for-new-concepts
layer: common
frameworks: ["*"]
severity_default: MEDIUM
---
## 觸發訊號
- 新增的 type flag / enum member 是在現有語意上做延伸或變體（例如 `VoidLike = Void | Undefined`），但命名沒有清楚標示出它與相鄰概念的差異（`void` 是型別層級語法概念，`undefined` 是執行期值，合併成一個名稱會混淆兩者）。
- 新增一個內部計數器/統計值，實際上是既有計數器（如 `typeCount`）的子集或特化，但直接併入同一個欄位／同一個回傳值，而不是給它獨立的名稱或獨立的回傳管道。
- 新增的設定檔/資源檔放進與既有工具鏈保留字重疊、但語意不同的目錄（例如把非 workflow 用途的資源放進 `.github/workflows`，該目錄名稱會被 CI 工具特殊處理）。
- 新增的 runtime helper / 產生出的識別字命名，與其他知名函式庫（如 Babel）既有的同類 helper 名稱相近或雷同，未特別確認過是否會造成使用者混淆或衝突。

## 判準
資深 reviewer 在意的不是命名美觀，而是：一旦新概念借用了既有名稱或既有位置，未來想把兩者分開（debug、單獨診斷、單獨統計、避免工具誤判）就會變成破壞性變更；尤其像 `.github/workflows` 這種目錄名稱，工具鏈會依名稱觸發行為，命名衝突不只是可讀性問題，是功能風險。合併計數器同理：使用者現在報效能問題時，你已經失去了「這個數字裡有多少是新概念貢獻的」這個診斷能力，之後想拆分只能加新 API，等於還是要重做一次。

## 嚴重度
CRITICAL：新目錄/檔案名稱與工具鏈保留路徑（如 CI 系統掃描的資料夾）重疊，會被誤判觸發非預期行為。
HIGH：新的度量/計數被silently併入既有公開 API 的既有欄位（如 `typeCount`），日後若要拆分需要新增/變更公開介面才能還原可觀測性。
MEDIUM：新識別字命名不精確、與其實際語意不符（如把型別層級與值層級概念用同一個名稱涵蓋），或產生的 helper 名稱與其他知名工具的同類命名相近，尚未造成功能性衝突，但增加閱讀與除錯成本。

## 反例（不該報）
- 新增的值只是既有已明文設計為可擴充之 enum 的合理延伸，且與其他成員語意上完全一致、沒有分歧用途，沿用既有分類無誤。
- 現有名稱已經精確且無歧義，單純出於個人風格偏好要求改名——這是 bikeshedding，不是真的缺陷。
- 新增的計數器/欄位純粹是內部除錯用途，從不對外輸出、也沒有使用者會問到，此時不必特地拆出獨立診斷管道。

## 出處
- https://github.com/microsoft/TypeScript/pull/45431#discussion_r694281036
- https://github.com/microsoft/TypeScript/pull/42149#discussion_r553634555
- https://github.com/microsoft/TypeScript/pull/23672#discussion_r183919445
- https://github.com/microsoft/TypeScript/pull/18300#discussion_r142069800
