---
id: rails-shared-state-scope
layer: rails
frameworks: ["rails@>=7.0", "activesupport@>=7.0", "activerecord@>=7.0"]
severity_default: HIGH
---
## 觸發訊號
diff 裡新增或修改了一個「掛在類別/模組層級而非個別物件」的狀態容器時，要去確認它的共享範圍是否跟語意相符：
- 新增 `class_attribute`、`mattr_accessor`/`cattr_accessor`、`singleton_class.attr_accessor`、或類別層級 `@ivar`／`@@cvar` 來存放設定值或快取。
- 把一個選項掛到全域命名空間或基底類別上（`ActiveRecord::Base.xxx=`、`ActiveSupport.xxx=`、`Rails.application.config.xxx`、`ActiveJob::Base.xxx=`）。
- 讓某個物件的內部狀態被跨執行緒／Fiber／Ractor／worker process 共用或複製（例如把 ivar 塞進 `Ractor[]`、`Thread.current`、常駐的 `Concurrent::Map`）。
- 測試中對上述任一類別層級或全域狀態賦值（例如 `Account.some_flag = true`、`SomeClass.mattr = x`）。
- 把一個原本該依「每個資料庫 / 每個帳號 / 每個 request」而不同的旗標，實作成單一開關（例如 `seed = true if database_initialized`、一個 process 全域的 executor pool）。

## 判準
這類問題不是「這行語法錯了」，而是「這個狀態的共享粒度跟它實際被讀寫的操作粒度對不上」：
- 用 `class_attribute` 會讓每個子類別各自持有一份獨立拷貝；如果語意上這其實該是唯一一份全域值（例如 verifier、raise-on-invalid 旗標），子類別各自一份會造成設定在某個子類別生效、在另一個子類別看不到，行為讓人意外且難以除錯。
- 用 `mattr_accessor`／單例全域值時，若呼叫端其實期待可以被子類別覆寫（繼承語意），會直接破壞既有的 subclassing 行為。
- 狀態被 fork／thread／fiber／ractor 重用或共享，卻沒有規劃清除或釋放時機，會導致記憶體洩漏或跨 worker 的資料污染，而且是那種平常測試很難重現、只有在長時間跑的 process 才會爆的 bug。
- 測試裡對類別層級或全域狀態賦值卻沒有在 `teardown` 還原，會讓這個值滲漏到之後的測試，造成測試順序相依的 flaky failure，而且通常只有 CI 隨機順序執行時才會現形。
- 把本該依 per-database／per-account／per-request 而不同的旗標做成單一全域開關，等於假設「只有一份」，一旦應用程式有多個資料庫、多個帳號或多個併發 request，就會用錯的旗標值去操作不該操作的資源（甚至是正式環境資料）。

## 嚴重度
CRITICAL：錯誤共享的全域/類別層級狀態會導致跨資料庫、跨帳號或跨 request 的資料被錯誤操作，尤其是可能在正式環境清空或覆寫既有資料（例如 `db:prepare` 對已存在的資料庫誤跑 seed）。
HIGH：語意上應為單一全域值卻用 per-subclass 機制實作（或反之），造成行為在不同子類別/呼叫路徑之間不一致，且會影響到框架公開 API 的行為（例如 `signed_id_verifier`、`message_verifiers` 用 `class_attribute` 讓每個 model 各自一份）。
MEDIUM：測試中對類別層級或全域狀態賦值但未在 `teardown` 還原，當下不影響正式行為，但有讓後續測試變 flaky 的風險。

## 反例（不該報）
- 該狀態被設計成「可被子類別覆寫」正是刻意的功能（例如各 Job 子類別各自宣告自己的 `retry_on`、`queue_with_priority`），不是共享範圍錯誤。
- 狀態的生命週期已經明確限定在單一 thread/fiber 內，且透過 `IsolatedExecutionState` 這類既有機制做了隔離，不需要進一步處理。
- 測試中對全域/類別狀態的變更是透過既有的、會自動還原的 helper（如 `around` block、`stub`、`with_xxx` 包裝方法）完成，本身已保證還原，不算漏 teardown。
- 純粹是把既有的、範圍本來就正確的全域設定值重新命名或搬動位置，沒有改變它的共享語意。

## 出處
- https://github.com/rails/rails/pull/57211#discussion_r3636592345
- https://github.com/rails/rails/pull/57825#discussion_r3530975048
- https://github.com/rails/rails/pull/55786#discussion_r2383992933
- https://github.com/rails/rails/pull/55420#discussion_r2246278226
- https://github.com/rails/rails/pull/55176#discussion_r2136334180
- https://github.com/rails/rails/pull/54788#discussion_r2008166337
- https://github.com/rails/rails/pull/54422#discussion_r1976480822
- https://github.com/rails/rails/pull/54422#discussion_r1970307985
- https://github.com/rails/rails/pull/54422#discussion_r1949674938
- https://github.com/rails/rails/pull/54290#discussion_r1922005794
- https://github.com/rails/rails/pull/53640#discussion_r1842619069
- https://github.com/rails/rails/pull/53354#discussion_r1807008556
- https://github.com/rails/rails/pull/52103#discussion_r1636651252
- https://github.com/rails/rails/pull/47522#discussion_r1120192785
- https://github.com/rails/rails/pull/43899#discussion_r1444360928
- https://github.com/rails/rails/pull/43899#discussion_r1444101987
