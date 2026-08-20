---
id: common-ruby-protected-vs-private-misuse
layer: common
frameworks: ["ruby@>=2.0"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或搬移的方法標記為 `protected`，但實作內容只在同一個 instance 內部被呼叫（沒有 `other_instance.method_name` 這種跨 instance 呼叫的模式），例如把原本 `private` 區塊底下的 helper 方法改放到 `protected` 底下，或新增的 `protected` 方法只是被同一物件內其他方法呼叫的內部邏輯（如設定檢查、狀態快取、內部工具方法）。

## 判準
Ruby 的 `protected` 語意很窄：它存在的唯一目的是讓同一個 class（或其子類別）的「另一個 instance」可以呼叫這個方法，典型場景是 `==`、`<=>`、`merge` 這類需要存取另一個物件內部狀態的比較/合併邏輯。如果方法實際上只被自己（`self`）呼叫，用 `protected` 沒有任何實質效果，只會讓讀者誤以為存在跨 instance 呼叫的設計意圖，也可能誤導子類別作者去呼叫其他 instance 的該方法而踩到未預期的耦合。resident reviewer 對這種寫法的直覺反應通常是「這個方法打算被誰呼叫？」——回答不出來就代表應該用 `private`。

## 嚴重度
CRITICAL：`protected` 方法涉及連線、憑證、交易等狀態變更操作，且因誤用可讓子類別意外呼叫其他 instance 的該方法，造成資料一致性或安全風險。
HIGH：方法屬於框架/函式庫的半公開介面，其他開發者可能依賴「可跨 instance 呼叫」這個（其實不存在的）語意來擴充子類別，未來要收斂成 `private` 會是破壞相容性的變更。
MEDIUM：純粹是語意不精確——方法目前只被自己呼叫、沒有外部依賴風險，但會造成程式碼意圖不清楚，應改為 `private`。

## 反例（不該報）
方法確實會被同一 class 的另一個 instance 呼叫，例如比較兩個物件（`<=>`、`==`）、合併兩個物件的內部欄位、或子類別需要存取父類別另一個 instance 的內部狀態時，使用 `protected` 是正確且必要的設計，不該報。

## 出處
- https://github.com/rails/rails/pull/54699#discussion_r1982843845
- https://github.com/rails/rails/pull/34227#discussion_r225746797
- https://github.com/rails/rails/pull/31422#discussion_r162202336
- https://github.com/rails/rails/pull/31422#discussion_r156547497
