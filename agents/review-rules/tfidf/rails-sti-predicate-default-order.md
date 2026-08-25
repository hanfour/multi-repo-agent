---
id: rails-sti-predicate-default-order
layer: rails
frameworks: ["rails@>=4.0"]
severity_default: HIGH
---
## 觸發訊號
diff 修改了一個以 `?` 結尾的判斷式方法（例如 `subclass_from_attributes?`），使其回傳值從單純布林改成「布林 || 某個 default/fallback 值」（如 `attribute_names.include?(inheritance_column) && (...) || columns_hash[inheritance_column].default`）；或者在呼叫端加入 `attrs[col] ||= default` 之類的預設值賦值，但這行賦值出現在「依賴同一個 attrs/欄位」的判斷式（`if subclass_from_attributes?(attrs)`）之後，而不是之前。

## 判準
STI（單表繼承）子類解析、或任何依 attrs/hash 內容決定分支走向的邏輯，一旦判斷式的執行時機早於預設值套用的時機，判斷式看到的永遠是「套用預設值之前」的狀態，導致本該生效的 default 型別完全不會被用到——這種 bug 不會拋例外、不會讓測試明顯失敗，只會讓應用程式在特定情境（例如 attrs 沒帶 `type` 欄位、依賴 column default）下悄悄實例化錯誤的子類，非常難在 code review 用肉眼抓到，必須追蹤呼叫順序才看得出來。另外，`foo?` 命名的方法承諾回傳布林，一旦摻入「順便回傳 default 值」的邏輯，呼叫端很容易誤把回傳值當成有意義的資料而非純粹的 true/false，破壞方法名稱與行為的一致性，也讓之後想抽出/重用這段邏輯的人更容易複製這個順序錯誤。

## 嚴重度
CRITICAL：順序錯誤會導致正式環境對外部輸入（如使用者送來的 params/attrs）解析出錯誤的 STI 子類型，且無測試覆蓋此路徑。
HIGH：順序錯誤已被邏輯本身覆蓋到（如本 cluster 中的案例），但當下測試套件未涵蓋「default 生效時的分支判斷」這條路徑，只是尚未造成外部可見的資料錯誤。
MEDIUM：`?` 結尾方法回傳非布林值但目前所有呼叫端都只用在 `if`/`&&` 布林語境中，尚未實際造成分支誤判，純粹是可讀性/未來誤用風險。

## 反例（不該報）
- 判斷式與預設值賦值操作的不是同一個 key/欄位，彼此沒有資料依賴，順序不影響結果。
- `?` 方法回傳值雖非嚴格布林，但呼叫端一律用 `!!` 或僅在 `if`/`unless` 中使用且從不把回傳值當資料存取（純粹依賴 truthy/falsy）。
- 預設值賦值本來就刻意放在判斷式之後，且判斷式的目的正是「檢查使用者是否明確提供了值（不含 default）」，此時後置賦值是設計意圖而非 bug。

## 出處
- https://github.com/rails/rails/pull/17169#discussion_r2296785907 (誤置，見下方正確清單)
- https://github.com/rails/rails/pull/17169#discussion_r46190053
- https://github.com/rails/rails/pull/17169#discussion_r39246600
- https://github.com/rails/rails/pull/9497#discussion_r3217972
- https://github.com/rails/rails/pull/24812#discussion_r61808198
- https://github.com/rails/rails/pull/11019#discussion_r4884387
