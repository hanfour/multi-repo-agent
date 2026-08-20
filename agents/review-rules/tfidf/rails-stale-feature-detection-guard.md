---
id: rails-stale-feature-detection-guard
layer: rails
frameworks: ["ruby>=2.7"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中出現 `defined?(SomeStdlibOrCoreModule)`、`SomeModule.respond_to?(:method)`、`exception.respond_to?(:method)` 這類 feature-detection 守門判斷，且被守護的功能其實在專案宣告的最低 Ruby/gem 版本下已經保證存在（例如 `defined?(DidYouMean) && DidYouMean.respond_to?(:correct_error)`、`exception.respond_to?(:annotated_source_code)`），或是守護的原因是「某個方法以前可能回傳 nil」而該前提已被更早的 commit 移除。特別留意：新增程式碼自行重新實作/繼承一個內部相容層（如 `ActiveSupport::CorrectableError`），而不是直接 `include` 標準函式庫已提供的模組（如 `DidYouMean::Correctable`）。

## 判準
這類守門式判斷是舊版本相容遺留物：一旦專案的最低相依版本已經保證該功能存在，判斷式就是恆真或恆假的死分支，只會增加閱讀與維護成本，且可能掩蓋真正的問題——例如把本該一定執行的測試包在條件式裡，讓它在支援的版本上被靜默跳過而失去回歸保護；或是明明可以直接依賴標準介面卻自建一份內部重複實作，形成不必要的耦合與日後升級時的分歧點。resident reviewer 的常見反應是「這個版本已經不用檢查了」「這應該可以直接刪掉測試/判斷式」。

## 嚴重度
CRITICAL：守門判斷讓正式功能路徑（例如例外回報、安全性檢查）在支援版本下被靜默跳過，導致該路徑實際上從未被執行卻無任何錯誤提示。
HIGH：守門判斷包住的是測試本身（`if defined?(...) ... def test_xxx`），造成該測試在所有實際受支援版本上都被跳過，喪失回歸保護。
MEDIUM：屬於死分支/多餘防呆，沒有功能性風險，但增加不必要複雜度，或應直接使用標準介面（如 `include DidYouMean::Correctable`）卻自建內部相容層。

## 反例（不該報）
- `respond_to?`/`defined?` 用於檢查真正可選的第三方 gem，或專案仍需支援的多個 Ruby 版本間確實不保證存在的功能。
- 用於 duck-typing 檢查使用者傳入的任意物件（而非標準函式庫/框架內部類別）是否實作某介面，這是合理且必要的多型判斷，不是版本相容遺留物。
- 判斷式守護的是外部輸入或執行期才能決定的狀態（而非編譯期/版本已知的保證），例如檢查某個 middleware 是否被載入。

## 出處
- https://github.com/rails/rails/pull/42333#discussion_r645191850
- https://github.com/rails/rails/pull/42333#discussion_r642983151
- https://github.com/rails/rails/pull/42142#discussion_r626725038
- https://github.com/rails/rails/pull/39363#discussion_r428196248
