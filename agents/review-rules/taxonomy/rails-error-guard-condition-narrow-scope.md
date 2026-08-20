---
id: rails-error-guard-condition-narrow-scope
layer: rails
frameworks: ["rails@>=6.0"]
severity_default: HIGH
---
## 觸發訊號
當 diff 新增或修改一個用來決定「是否要短路、提早 return、套用預設值、跳過某段邏輯、或允許 bypass 某個檢查」的 guard 條件式，且該條件式的判斷依據只看「單一、當下狀態」的值時（例如：只讀取 `klass` 本身的設定而非整條繼承鏈／`ancestors`；只比對一個 attribute 名稱而未考慮它是否有 alias；把 foreign key／primary key 當成單一值比對而該欄位其實可能是複合鍵（composite key）陣列；只用 `respond_to?` 或型別判斷來決定是否要重算，而沒有再排除「值其實已經是合法/已轉換完成」的情形），要回頭去確認：這個判斷依據在子類別繼承、attribute alias、composite key、以及「值已經處理過」這幾種情境下是否仍然成立，而不是只驗證 diff 本身改動的那一行邏輯有沒有語法錯誤。

## 判準
這類 guard 在最常見的情境（base class、無 alias、單一欄位鍵、值尚未處理）下完全正確，也能通過針對該情境寫的單元測試，所以很容易被合併；但 Rails 的物件模型大量依賴繼承（AR model hierarchy）、attribute aliasing、composite primary key，guard 只看「當下這一層」會在合法但較少被測試覆蓋的情境下悄悄選錯分支——輕則多做一次不必要的運算，重則讓子類別繞過了原本該套用的安全/驗證設定，或讓更新／刪除作用在錯誤範圍的記錄上。resident reviewer 抓的不是這行程式碼寫錯了什麼，而是「這個條件式沒有窮舉它應該窮舉的情況」。

## 嚴重度
CRITICAL：漏掉的分支涉及安全機制或資料完整性——例如驗證用的 secret／verifier 判斷只看模型本身、沒看繼承鏈，導致子類別悄悄退回舊的較不安全設定；或複合鍵情境下把多欄位鍵當單一欄位比對，導致 update/delete 作用在錯誤範圍的記錄。
HIGH：漏掉的分支會讓功能在合法且常見的情境（attribute alias、composite key、被繼承的子類別）下行為不正確，例如該觸發的 callback 沒有被觸發、快取沒有正確失效，但不涉及資料損毀或安全繞過。
MEDIUM：漏掉的分支只造成多餘運算或效能損耗（guard 範圍設太寬，導致本可跳過的重運算被執行），不影響最終結果正確性。

## 反例（不該報）
- 條件式本來就只設計給單一、非繼承、非複合鍵的情境使用（例如純粹的 local variable、method 參數、request 層的一次性判斷），沒有繼承鏈、alias 或 composite key 的概念可言。
- 條件式已經呼叫了既有、已知涵蓋繼承鏈或 alias 解析的既有方法（例如透過 `attribute_aliases`、`superclass` 顯式往上查找），diff 只是換了個等價寫法，涵蓋範圍並未縮小。
- diff 只是重新命名變數、抽出私有方法或搬移程式碼位置，判斷邏輯本身（涵蓋範圍）完全沒有變動。

## 出處
- https://github.com/rails/rails/pull/54422#discussion_r2029940361
- https://github.com/rails/rails/pull/48552#discussion_r1240235921
- https://github.com/rails/rails/pull/32241#discussion_r206364464
- https://github.com/rails/rails/pull/35415#discussion_r260264602
- https://github.com/rails/rails/pull/21020#discussion_r94473746
