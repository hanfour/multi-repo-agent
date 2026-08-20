---
id: rails-adhoc-uri-hash-parsing-without-validation
layer: rails
frameworks: ["rails@>=5"]
severity_default: MEDIUM

---
## 觸發訊號
diff 中新增或修改了下列任一種寫法：
- 把 `URI.parse`／query string 解析結果直接 `merge`／攤平進另一個共用 hash（如 `query_hash.merge(host:, port:, database: ...)`），且沒有對合併進來的 key 做白名單過濾。
- 新增 `options_from_uri`、`url_options`、`options_from_url` 這類「把 URI 轉成一包 hash」的方法，但呼叫端只靠隱含慣例知道 hash 裡有哪些 key，沒有型別、沒有文件說明允許哪些欄位。
- 在 `registry.register_type` / MessagePack factory 之類的地方，一次只改了 `packer:` 或 `unpacker:` 其中一邊（新增 `write_x`/`read_x` 方法但另一邊仍是舊的 `:to_s`/`:new`），沒有同步驗證另一邊仍相容。
- 設定值可能是 `Proc`/callable（例如 `report_uri(uri)` 允許傳入 lambda），程式碼用 `if uri` 判斷「是否有設定」而不是判斷 `Proc` **呼叫後的回傳值**。

## 判準
URI/query string 是外部或半外部輸入（來自資料庫設定檔、環境變數、甚至 URL），一旦被攤平進通用 hash 又不設 key 白名單，日後任何人往這個 hash 加欄位、或攻擊者能控制 query string 的一部分，都可能覆蓋掉本該由程式碼保留的欄位（如 `adapter`、`database`）而不會有任何錯誤浮現——這類 bug 通常要等到生產環境才會被發現。同理，`packer`/`unpacker` 是一組必須對稱的編解碼契約，只改一邊很容易在 review 時被忽略（reviewer 在這批意見裡就明確表示「幸好 unpack 沒變，所以還好」，代表這是需要主動確認、而非顯而易見的事）。而 `if proc_value` 這種寫法對「值是 Proc」永遠為真，等於讓「有沒有設定」的判斷失效，這正是 CSP `report_uri` 那條意見指出的真實 bug。

## 嚴重度
CRITICAL：packer/unpacker（或任何序列化/反序列化的一對方法）只改了一邊，且該資料會跨版本持久化或快取（例如 MessagePack 序列化後存進 DB/cache），會造成舊資料無法反序列化或資料靜默損毀。
HIGH：URI/query string 解析出的 hash 未經白名單直接 merge 進連線設定、金鑰、路徑等敏感或結構性欄位（如 DB 連線參數），可能被外部輸入覆蓋而無任何驗證或錯誤提示。
MEDIUM：可能為 Proc/callable 的設定值只用 `if value` 判斷是否啟用，未對呼叫後的回傳值做 nil 檢查，導致該功能分支恆真或恆假；或是新增了一個把 URI 轉成 hash 的方法但沒有文件/型別說明允許的 key，造成維護者要靠讀原始碼才能知道合約。

## 反例（不該報）
- 只是把既有、行為不變的 URI parse 邏輯搬進獨立方法或物件，沒有新增未驗證的 key 合併。
- packer/unpacker（或任何編解碼對）兩邊在同一個 diff 中一起修改，且有測試涵蓋往返（round-trip）驗證。
- 攤平進 hash 的來源本身就是可信、由程式碼固定產生的常數集合（非外部輸入），且下游有明確的 keys 白名單或 schema 檢查。
- Proc 型設定值在賦值當下就已經被呼叫並確認非 nil，或該值本來就不可能是 falsy（例如永遠回傳字串）。

## 出處
- https://github.com/rails/rails/pull/55447#discussion_r2268502722
- https://github.com/rails/rails/pull/55447#discussion_r2265200370
- https://github.com/rails/rails/pull/50477#discussion_r1769680058
- https://github.com/rails/rails/pull/50742#discussion_r1451798913
- https://github.com/rails/rails/pull/47770#discussion_r1149771843
- https://github.com/rails/rails/pull/47770#discussion_r1148649931
- https://github.com/rails/rails/pull/42840#discussion_r682067744
- https://github.com/rails/rails/pull/42365#discussion_r678701152
- https://github.com/rails/rails/pull/41391#discussion_r583920107
- https://github.com/rails/rails/pull/41293#discussion_r568571890
- https://github.com/rails/rails/pull/34959#discussion_r248733685
- https://github.com/rails/rails/pull/34704#discussion_r242772479
- https://github.com/rails/rails/pull/25520#discussion_r70840593
- https://github.com/rails/rails/pull/12769#discussion_r7709308
