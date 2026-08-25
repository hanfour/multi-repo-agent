---
id: rails-cache-invalidation
layer: rails
frameworks: ["rails@>=6.0"]
severity_default: CRITICAL
---
## 觸發訊號
- diff 新增或修改一個繞過 ActiveRecord callback 的寫入路徑（`update_column`/`update_columns`、`update_all`、`upsert`/`upsert_all`、`insert_all`、`delete`/`delete_all`、原生 SQL UPDATE/DELETE），而目標 model 具備 `cache_key_with_version`、`touch: true`、`counter_cache`，或其資料會被 `Rails.cache.fetch`／view fragment cache／`fresh_when`/`stale?` 使用。
- diff 變更了 model 之間的關聯、外鍵或擁有關係（例如改動父模型主鍵、切換 `belongs_to` 目標、更換 `counter_cache` 的擁有者），但沒有同步呼叫 `reset_counters`、`touch`，或清掉舊 key 對應的快取項目。
- diff 為 `has_one`/`has_many` 關聯新增或修改交易生命週期內的 callback（如 `after_create_commit`、`around_save`），卻沒有處理「已載入的 association target 在 transaction commit 後可能與資料庫不同步（stale target）」這個情境。
- diff 修改了組成 cache key 或 digest 的輸入維度（例如 format、locale、MIME type、序列化欄位、被快取物件的欄位），但沒有把新增/變動的維度一併納入 key 或 digest 的計算。
- diff 新增或修改一個會改變被快取值的操作（如 counter 的 increment/decrement、寫入帶 `expires_in` 的快取項目），卻沒有同時處理過期時間重算或版本更新。

## 判準
Rails 的 fragment cache／low-level cache／counter cache 全部依賴一個隱性契約：底層資料一變，對應的 cache key 或 cache version 就要跟著變，否則使用者拿到的就是過期資料。這類問題不會在單元測試裡直接爆炸——繞過 callback 的寫入路徑（`update_column` 等）本身完全合法且常見於效能優化，但如果被繞過的正是快取失效機制所依賴的那個 callback，缺陷只會在特定操作序列（例如透過批次更新繞過 touch）之後才顯現為「畫面沒更新」或「計數對不上」，而且往往要等使用者回報才會被發現。reviewer 之所以要在 diff 裡追這條線索，是因為看完整個資料流才能判斷某個寫入路徑是否切斷了快取失效的因果鏈，而不是單看某一行程式碼對不對。

## 嚴重度
CRITICAL：生產環境會持續提供過期或錯誤資料，且沒有自動修復路徑（例如寫入路徑永久繞過 touch 導致 fragment cache 失真直到內容真的改變；或外鍵變更後 counter_cache 永久算錯且沒有任何 `reset_counters` 呼叫點）。
HIGH：只在特定 race 或 transaction 邊界下才會讀到 stale 值（例如 has_one association target 在 commit 後未 reset，只在同一 request 生命週期內可見）。
MEDIUM：快取失真影響範圍小，或有 TTL/過期機制兜底（例如快取設有 `expires_in`，只是沒有主動失效，最差情況是等到自然過期）。

## 反例（不該報）
- 寫入路徑本來就會觸發完整 model callback（用 `save`/`update`/`destroy` 而非 `update_column` 等），Rails 的 `touch: true` 或 `cache_key_with_version` 機制會自動處理失效。
- 新增/變動的欄位根本沒有被任何 cache key、digest 或 `Rails.cache` 呼叫用到。
- 快取本身明確宣告只為效能優化、可接受短暫不一致（例如文件寫明採用 `stale-while-revalidate` 或 eventually-consistent 策略，且該行為是設計選擇而非疏漏）。
- PR 只是重新排版、搬移或重新命名既有的快取程式碼，沒有改變任何寫入路徑、關聯結構或 key 組成邏輯。

## 出處
- https://github.com/rails/rails/pull/58168#discussion_r3625117272
- https://github.com/rails/rails/pull/57825#discussion_r3529180258
- https://github.com/rails/rails/pull/57825#discussion_r3529154825
- https://github.com/rails/rails/pull/57107#discussion_r3226991450
- https://github.com/rails/rails/pull/57107#discussion_r3226737601
- https://github.com/rails/rails/pull/56080#discussion_r2502869203
- https://github.com/rails/rails/pull/53068#discussion_r2462628191
- https://github.com/rails/rails/pull/53068#discussion_r2441462837
- https://github.com/rails/rails/pull/53068#discussion_r2440889888
- https://github.com/rails/rails/pull/55249#discussion_r2177223048
- https://github.com/rails/rails/pull/55033#discussion_r2086015264
- https://github.com/rails/rails/pull/54149#discussion_r1910156740
- https://github.com/rails/rails/pull/54149#discussion_r1909424411
- https://github.com/rails/rails/pull/53551#discussion_r1860720740
- https://github.com/rails/rails/pull/51654#discussion_r1627937982
- https://github.com/rails/rails/pull/51654#discussion_r1579559200
- https://github.com/rails/rails/pull/49765#discussion_r1387068344
- https://github.com/rails/rails/pull/49858#discussion_r1379026362
- https://github.com/rails/rails/pull/48743#discussion_r1272219135
- https://github.com/rails/rails/pull/47753#discussion_r1149596857
- https://github.com/rails/rails/pull/45940#discussion_r964146413
- https://github.com/rails/rails/pull/45711#discussion_r934388606
- https://github.com/rails/rails/pull/44232#discussion_r790164079
- https://github.com/rails/rails/pull/44219#discussion_r789170807
- https://github.com/rails/rails/pull/42744#discussion_r668259160
- https://github.com/rails/rails/pull/41084#discussion_r625187430
- https://github.com/rails/rails/pull/41404#discussion_r575158627
- https://github.com/rails/rails/pull/40229#discussion_r566536807
- https://github.com/rails/rails/pull/39754#discussion_r504270294
- https://github.com/rails/rails/pull/39495#discussion_r433179425
- https://github.com/rails/rails/pull/37723#discussion_r346913434
- https://github.com/rails/rails/pull/37669#discussion_r344465209
- https://github.com/rails/rails/pull/37669#discussion_r344465208
- https://github.com/rails/rails/pull/37301#discussion_r329372161
- https://github.com/rails/rails/pull/36708#discussion_r309036086
- https://github.com/rails/rails/pull/36708#discussion_r309031116
- https://github.com/rails/rails/pull/36708#discussion_r307672794
- https://github.com/rails/rails/pull/36708#discussion_r307565281
- https://github.com/rails/rails/pull/36708#discussion_r306768607
- https://github.com/rails/rails/pull/35833#discussion_r271426134
