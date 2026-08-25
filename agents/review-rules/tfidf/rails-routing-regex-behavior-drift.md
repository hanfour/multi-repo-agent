---
id: rails-routing-regex-behavior-drift
layer: rails
frameworks: ["rails@>=6"]
severity_default: HIGH

---
## 觸發訊號
diff 改動到 Rails routing 內部機制：ActionDispatch::Journey（ast、nodes、routes.rb、GTG::Builder）、路由比對用的 regexp（mapper.rb 的 ANCHOR/OPTIONAL_FORMAT_REGEX、host_authorization.rb 的 IPV4/IPV6/PORT regex、mailbox routing 的 regex => symbol 對照）、或是路由集合上的 memoized ivar（`@partitioned_routes`、`@simulator`、`@ast`、`@route_set_class`），且該次改動同時牽動了 default 值、regexp pattern，或 cache/memoization 邏輯，卻沒有對應測試去鎖住那個邊界情境。

## 判準
routing 是每個 request 都會經過的熱路徑，這裡的行為改變通常不會編譯期報錯，也很難靠人工檢查發現——例如把 keyword default 從 `nil` 換成 `false`，看起來只是型別調整，實際上會改變 `as:` 未指定時是否產生具名路由；memoized ivar 如果被重構成每次呼叫都重新計算（例如把只在第一次呼叫時執行的邏輯搬進 method body），效能會在高流量下明顯劣化卻不會噴錯；regexp 表面上等價（例如 `/(#{match})(?![^<]*?>)/i` vs `/<[^>]*|[^<]+/`），實際在特定輸入下的回溯行為天差地遠，可能造成 catastrophic backtracking。這些問題共同點是：改動小、影響大、且沒有測試會自動抓到。

## 嚴重度
CRITICAL：regexp 改動使 catastrophic backtracking 可被 request path、mail header 等外部輸入觸發，形成 DoS 風險（例如 highlight regex 對長字串回溯爆炸的案例）。
HIGH：keyword default（如 `as: nil` → `as: false`）或其他預設值改變了既有 app 的路由命名/比對行為卻未被察覺；或 memoized 邏輯被破壞導致本該只算一次的路由計算（partition、simulator、AST 建置）變成每次呼叫都重算。
MEDIUM：regexp/AST 重構本身行為等價，但沒有新增測試明確鎖定被改動的邊界案例（例如 unicode route segment、`:port` 選填、mailbox 地址大小寫）。

## 反例（不該報）
純文件/guide 的段落重組、標題調整、措辭潤飾，沒有動到程式碼；純風格轉換且已確認行為完全等價（例如 `{ }` block 換成 `&:symbol_to_proc`）；純空白或 CHANGELOG 文字修正；把框架內部限定的開發用路由改成透過正確擴充點（如 `initializer :add_internal_routes`）注入，而不是直接寫進使用者的 `config/routes.rb` 產生樣板——這是修正本身，不是要抓的問題；regexp 或 AST 改動同時附上 benchmark 或測試證明語意等價、且無回溯劣化。

## 出處
- https://github.com/rails/rails/pull/56245#discussion_r2570828755
- https://github.com/rails/rails/pull/54916#discussion_r2043849411
- https://github.com/rails/rails/pull/52521#discussion_r1727554812
- https://github.com/rails/rails/pull/52512#discussion_r1704689707
- https://github.com/rails/rails/pull/48296#discussion_r1230671127
- https://github.com/rails/rails/pull/47186#discussion_r1105216942
- https://github.com/rails/rails/pull/47339#discussion_r1102268691
- https://github.com/rails/rails/pull/47186#discussion_r1097108330
- https://github.com/rails/rails/pull/43882#discussion_r770055710
- https://github.com/rails/rails/pull/42634#discussion_r660708118
- https://github.com/rails/rails/pull/40883#discussion_r551537971
- https://github.com/rails/rails/pull/39981#discussion_r467508337
- https://github.com/rails/rails/pull/34656#discussion_r286769923
- https://github.com/rails/rails/pull/32296#discussion_r177515080
- https://github.com/rails/rails/pull/20420#discussion_r44216583
- https://github.com/rails/rails/pull/8783#discussion_r2560723
- https://github.com/rails/rails/pull/8521#discussion_r2430267
