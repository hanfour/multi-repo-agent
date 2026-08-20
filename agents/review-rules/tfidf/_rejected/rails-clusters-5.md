---
id: rails-mutable-constant-direct-write
layer: rails
frameworks: ["rails@>=6.0"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改的程式碼，對一個模組/類別層級的全大寫共享常數（例如 `NATIVE_DATABASE_TYPES`、`DEFAULT_OPTIONS` 這類設定表/型別對照表）做 in-place 修改：`SOME_CONST[key] = value`、`SOME_CONST << x`、`SOME_CONST.merge!(...)`、`SOME_CONST.delete(...)` 等，且呼叫端不是常數的定義模組本身；或是常數被直接以 `attr_accessor`/`attr_writer` 整包暴露成可寫，讓外部程式碼能任意覆蓋。

## 判準
Ruby 的全大寫常數預設不是 frozen，一旦允許外部程式碼直接用 `[]=`/`<<`/`merge!` 改它，就等於把模組內部狀態變成任何呼叫端都能竄改的全域可變狀態：沒有邊界、沒有驗證、無法追蹤是誰改的，在多執行緒或跨 request 共用下會互相污染；測試之間也會因為前一個測試改了常數而互相影響，造成順序耦合的偶發性失敗。正確做法是由定義該常數的模組提供一個公開的註冊/擴充方法（例如 `register_type(name, definition)`），內部用 `dup`/`merge` 產生新的雜湊再賦值給自己的 instance variable，把常數的所有權留在定義它的地方。

## 嚴重度
CRITICAL：被改動的常數在 production 的 request 處理路徑上被共用（如連線介面卡的型別對照表、預設連線選項），外部直接寫入會造成跨 request/跨執行緒污染，且沒有任何隔離或還原機制。
HIGH：常數只在測試或初始化程式碼中被直接改動，但缺少對應的 teardown/還原邏輯，會造成測試順序耦合、CI 偶發性失敗，或被其他開發者複製這個壞範例。
MEDIUM：常數被直接改動，但影響範圍侷限在單一、非共用的物件實例，或緊接著就有明確、可靠的還原機制。

## 反例（不該報）
- 對常數呼叫 `.dup`/`.merge` 產生的是「區域變數」再回傳，原常數本身沒有被動到（例如 `types = NATIVE_DATABASE_TYPES.dup; types[:datetime] = ...; types`）——這正是建議的正確寫法，不該報。
- 程式碼本身就是該常數「第一次賦值/初始化」的定義處，而不是之後外部的修改。
- 透過模組自己提供的公開註冊方法（內部才做 `dup`/`merge` 再賦值給自己的 instance variable）去擴充常數內容，這是被建議採用的介面，不該報。

## 出處
- https://github.com/rails/rails/pull/57341#discussion_r3219396920
- https://github.com/rails/rails/pull/41084#discussion_r625187430
