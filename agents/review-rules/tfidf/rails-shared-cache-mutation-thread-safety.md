---
id: rails-shared-cache-mutation-thread-safety
layer: rails
frameworks: ["rails@>=5.0", "concurrent-ruby@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現以下任一模式：
- 把 class-level／模組層級、會被多個 request 或多個 thread 共用的快取（例如 `@trackers`、`@cache_keys`、`quoted_column_names`、`DetailsKey.@store`、`view_paths` 這類 memoized 集合）從 `Concurrent::Map`/`Concurrent::Hash`/`Concurrent::Array` 換成一般 `Hash`/`Array`/`ThreadSafe::Cache` 之外的型別，且 PR 描述或 commit message 沒有解釋為何不再需要同步保護
- 在呼叫某方法前，先對一個「被快取、被傳入、或可能被其他呼叫者保留參照」的物件呼叫 setter 改變其狀態（例如 `finder.formats = [...]; finder.variants = [...]; finder.find(...)`），而不是把值當作參數傳入
- 在 `compute_if_absent`／`synchronize`／持有鎖的區塊內，包進了可能耗時、或可能重入呼叫同一把鎖的程式碼

## 判準
這類改動表面上只是「換個資料結構」或「先設定屬性再呼叫」的小重構，看起來無害、也常常沒有對應測試會失敗。但這些物件一旦在 Puma/Sidekiq 等多執行緒環境下被多個 request 同時讀寫，plain Hash 不像 `Concurrent::Map` 有線程安全保證，會產生 race condition；而對共享/快取物件先呼叫 setter 再呼叫方法，一旦該物件被其他地方保留了參照（例如 memoized instance、跨 request 快取的 finder），這次呼叫的 setter 會覆蓋掉其他呼叫者原本設定的狀態，造成難以重現的資料錯亂或 flaky test。資深 reviewer 在這類 PR 上通常會直接問：「這個物件真的是這次呼叫獨享的嗎？」「拿掉同步保護後在非 MRI runtime 或高並發下還安全嗎？」「要不要 dup 一份再改，而不是直接改共享物件？」

## 嚴重度
CRITICAL：移除/替換的是 framework 核心、跨 request 共用的快取（如 dependency tracker 的 `@trackers`、middleware 的 rescue_responses 表、encryption/attribute listener 清單）的同步保護，且該程式碼路徑在正常執行期間必然被多執行緒同時觸發
HIGH：對一個可能被快取或重複使用的物件（如 `finder`、`lookup_context`）呼叫 setter 改變其狀態後才呼叫查詢方法，而未 dup/複製，且沒有其他證據證明該物件在此呼叫中是獨享的
MEDIUM：在鎖或 `compute_if_absent` 區塊內包住了可能觸發同一把鎖重入、或明顯耗時的呼叫，會造成鎖爭用或效能下降，但不至於資料損毀

## 反例（不該報）
- 對方法內部建立、從未逸出當前呼叫堆疊、也不會被其他 thread 或 caller 持有參照的物件做 setter＋呼叫，是安全的區域性操作，不算違規
- 把一個確定只在單一 request、單一 thread 生命週期內使用、且每次都新建的暫存物件從 `Concurrent::Map` 換成 `Hash`，是合理簡化，不是弱化線程安全
- 對 immutable frozen 常數（例如 `INITIAL_STATE = [0].freeze`）新增 `.freeze`，是強化不可變性，不屬於本規則要抓的「弱化同步保護」問題

## 出處
- https://github.com/rails/rails/pull/57948#discussion_r3570876834
- https://github.com/rails/rails/pull/57508#discussion_r3330866565
- https://github.com/rails/rails/pull/48773#discussion_r1271401980
- https://github.com/rails/rails/pull/43218#discussion_r709316514
- https://github.com/rails/rails/pull/27296#discussion_r91314725
- https://github.com/rails/rails/pull/20904#discussion_r35444819
- https://github.com/rails/rails/pull/14329#discussion_r10574872
