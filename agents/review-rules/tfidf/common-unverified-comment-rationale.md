---
id: common-unverified-comment-rationale
layer: common
frameworks: ["ruby@*"]
severity_default: MEDIUM
---
## 觸發訊號
新增或修改的程式碼旁邊有一段解釋「為什麼這樣做/為什麼這樣安全/為什麼這樣比較快」的註解或函式命名，但：
- 註解宣稱的效能結論（例如「這個寫法比較快」「已改成最快版本」）沒有對照目前實際輸入分布重新驗證過，或作者自己都承認結果不確定（如 benchmark 顯示「same-ish」卻仍寫死結論）；
- 函式名稱/註解暗示完整處理某個問題（例如 `quote(str)` 暗示產出可安全使用的字串），但實作只覆蓋最簡單情況，沒處理邊界輸入（如字串裡本身含引號/跳脫字元）；
- 錯誤訊息只描述「發生了什麼類別的錯誤」（如 `raise "Missing Parameter"`），沒有帶出讓呼叫者能定位問題的具體資訊（哪個 key、哪個 position）；
- 新增一個功能相近的私有方法（如 `klass_suppress_errors`／類似 inverse-lookup 的 candidate 查找),但看不出是否與既有邏輯重複，PR 描述或註解也沒解釋為何不能複用既有機制。

## 判準
這類問題的共通點是「文字承諾的保證」與「程式碼實際提供的保證」之間有落差。Reviewer 讀到註解或函式名稱時會先信任它，之後如果拿掉註解、只看程式碼本身，行為的正確性反而站不住腳——這種落差在程式碼被複製貼上、或後人只讀函式簽名決定要不要用時特別危險，因為誤導性註解比沒有註解更糟：沒註解時後人會自己去查，有誤導性註解時後人會誤信。同理，只處理部分輸入空間卻用看似通用的函式名稱，日後很容易被別的呼叫點誤用到沒被覆蓋的情況。錯誤訊息缺乏具體資訊則是维護成本問題：出錯時除了看 stack trace 別無他法定位。

## 嚴重度
CRITICAL：（此類問題本身少見到 CRITICAL 等級；若邊界情況未處理導致的是安全問題，例如字串未跳脫被用於拼接 shell 指令/SQL/HTML，則升級為 CRITICAL）
HIGH：函式命名或註解暗示「已完整處理」但實際上遺漏的邊界情況會在正常使用路徑（非人為構造）就觸發，或錯誤訊息缺失資訊會直接拖慢 production 除錯（例如批次處理多筆資料時無法知道是哪一筆失敗）
MEDIUM：效能相關註解的結論未經目前程式碼路徑驗證、或新增方法與既有邏輯疑似重複但未說明原因，這類情況會誤導後續維護者但不會立即造成錯誤行為

## 反例（不該報）
- 註解清楚標註「TODO」「暫不處理 X 情況」等，明確承認邊界未覆蓋，而非宣稱已完整處理；
- 效能相關註解有附上可重現的 benchmark 數字、且該數字仍然反映目前程式碼路徑（沒有因後續改動而失真）；
- 錯誤訊息雖簡短，但呼叫端本來就只會在單一已知情境下呼叫該函式，訊息缺乏細節不影響定位（例如函式只有一個呼叫點且立刻在外層被 rescue 並附上 context）；
- 新增的私有方法雖然名稱聽起來與既有邏輯相近，但 PR 描述或程式碼本身已清楚說明兩者處理的情境完全不同（例如一個是查 has_one，一個是查 has_many），不存在可複用性。

## 出處
- https://github.com/rails/rails/pull/41321#discussion_r800282527
- https://github.com/rails/rails/pull/36180#discussion_r307991163
- https://github.com/rails/rails/pull/26535#discussion_r79299035
- https://github.com/rails/rails/pull/24658#discussion_r60494889
- https://github.com/rails/rails/pull/15327#discussion_r13051397
- https://github.com/rails/rails/pull/6873#discussion_r1059804
