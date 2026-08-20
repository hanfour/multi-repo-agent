---
id: rails-brittle-crypto-rescue
layer: rails
frameworks: ["openssl@*", "activesupport@*", "activerecord@*"]
severity_default: HIGH
---
## 觸發訊號
diff 在加解密 / 雜湊 / 金鑰處理路徑（OpenSSL、Digest、ActiveSupport::MessageEncryptor/Verifier、ActiveRecord::Encryption 相關程式碼）新增或修改了：
- 沒有指定例外類別的 bare `rescue`（例如 `rescue # OpenSSL may have MD5 disabled` 這種只靠註解說明、實際上會接住所有 `StandardError` 子類別的寫法），用來偵測環境能力（如某演算法是否被停用）。
- `rescue SomeError => e` 之後用 `e.message.match?(/.../)` 去比對第三方 gem（如 `openssl`）拋出例外的訊息文字，藉此決定分支行為（例如判斷是不是「金鑰長度錯誤」）。

## 判準
bare rescue 會連帶吞掉跟預期情境無關的例外（打錯方法名的 `NoMethodError`、環境沒裝某個 library 的 `LoadError` 等），讓「這行為是我預期的 fallback」變成一個沒有邊界的假設，除錯時完全看不出真正錯在哪。用例外訊息字串去分支則是把控制流程綁死在第三方 library 的內部實作文字（例如 `openssl` gem 在 `ossl_cipher.c` 裡丟出的訊息格式）——那不是任何公開 API 契約保證的東西，gem 升級改個措辭，分支邏輯就悄悄失效，而且不會有任何測試失敗來提醒你。資深 reviewer 的立場是：能夠提前驗證的條件（例如金鑰長度）就該主動驗證並在觸發點就報錯，而不是等函式庫丟例外後再回頭「猜」是不是那個原因。

## 嚴重度
CRITICAL：吞掉的例外或誤判的分支發生在金鑰驗證、簽章驗證、加解密是否成功的判斷路徑上，可能讓錯誤或不合規格的金鑰/演算法被靜默接受，造成安全繞過。
HIGH：用 `e.message.match?(...)` 依賴特定第三方 gem 的例外訊息文字做為控制流程分支，且沒有對應測試鎖定該訊息格式，gem 版本升級可能無聲改變行為。
MEDIUM：bare rescue 用於偵測環境能力（如「這台機器的 OpenSSL 有沒有停用 MD5」）等非安全判斷、僅影響 fallback 實作選擇的情境，但仍缺乏明確例外類別，除錯困難。

## 反例（不該報）
- `rescue` 有指定明確、狹窄的例外類別，且該類別是該函式庫公開文件承諾會拋出的（例如 `rescue OpenSSL::Digest::DigestError`）。
- 例外訊息比對只用於寫 log / 警告訊息，不影響任何安全性判斷或程式的控制流程走向。
- 程式碼位於測試輔助工具、除錯腳本或非正式執行路徑中，不是實際的加解密/驗證邏輯。
- rescue 範圍雖廣，但緊接著會 re-raise（`raise`）而非吞掉例外，只是用來附加上下文再往外拋。

## 出處
- https://github.com/rails/rails/pull/54040#discussion_r1905181663
- https://github.com/rails/rails/pull/54040#discussion_r1903095428
- https://github.com/rails/rails/pull/39554#discussion_r479697391
