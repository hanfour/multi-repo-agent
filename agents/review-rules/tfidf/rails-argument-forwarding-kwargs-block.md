---
id: rails-argument-forwarding-kwargs-block
layer: rails
frameworks: ["rails@>=5.0", "ruby@>=2.7"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改的方法用 `*args`（有時搭配 `**options`、`&block`）手動把參數轉發給另一個方法、`super`，或動態產生的方法（`module_eval`/`class_eval`/`define_method`）、`method_missing`、`delegate`、mailer/job 的 enqueue 參數組裝；或看到 `options = args.first` 這類從 `*args` 裡手動拆出 hash 的寫法；或看到 `args.push(options)` 而不是直接用 `**options`；或看到依 `RUBY_VERSION` 手動切換 `"..."` 與 `"*args, &block"` 兩種轉發語法的產生器程式碼。

## 判準
Ruby 2.7 之後 keyword arguments 與最後一個 positional hash 是分開處理的，單純用 `*args` 收集參數會把呼叫端傳入的 kwargs 錯誤併入（或漏掉）最後一個 positional 引數，造成呼叫端傳關鍵字引數時行為悄悄改變，甚至丟出 `ArgumentError`。同樣地，手動用 `*args, &block` 做多層轉發（例如 `method_missing` → `delegate` → 目標方法）卻沒有用完整的 `...`（full argument forwarding）或明確拆分 `args`/`kwargs`/`block`，會在其中一層把 block 或 kwargs 弄丟，或塞進錯誤位置。這類 bug 通常要等呼叫端真的用 keyword 引數或帶 block 呼叫才會現形，一般測試容易漏掉，是 Rails 這類大量依賴動態方法產生與委派的 codebase 裡的常見雷區。

## 嚴重度
CRITICAL：轉發路徑上 kwargs 被吃掉或位置錯亂，且影響到對外公開 API（例如 ActiveRecord/ActionMailer 的公開方法），呼叫端行為在特定呼叫方式下悄悄改變且沒有任何錯誤訊息
HIGH：手動用 `*args, &block` 做多層轉發但沒有處理 kwargs 分離，或動態產生的方法沒有依 Ruby 版本一致地選對轉發語法（`...` vs `*args, &block`），或轉發過程中把 hash 的 key 型別（symbol/string）在跨層傳遞時弄錯
MEDIUM：轉發語意不精確（例如用 `args.first` 猜測 options、或用 `include?`/`respond_to?` 間接推斷是否傳了某引數）但目前呼叫端都還沒踩到，風險是未來新增呼叫方式時才會壞

## 反例（不該報）
若目標方法本身沒有 keyword arguments、也不接受 block，單純 `*args` 轉發沒有風險；或該轉發已經用 `...`、`ruby2_keywords`、或明確 `def foo(*args, **kwargs, &block)` 完整涵蓋三種型態並經測試驗證跨版本行為一致，就不該報；純粹是測試輔助方法（test helper）內部使用、且沒有對外語意保證的轉發，風險等級應相應下修，不必比照公開 API 標準。

## 出處
- https://github.com/rails/rails/pull/55659#discussion_r2342250450
- https://github.com/rails/rails/pull/52605#discussion_r1717973265
- https://github.com/rails/rails/pull/50721#discussion_r1450123168
- https://github.com/rails/rails/pull/48533#discussion_r1263286869
- https://github.com/rails/rails/pull/48338#discussion_r1212697832
- https://github.com/rails/rails/pull/46846#discussion_r1064004905
- https://github.com/rails/rails/pull/46789#discussion_r1055195448
- https://github.com/rails/rails/pull/46448#discussion_r1017156989
- https://github.com/rails/rails/pull/40848#discussion_r545327203
- https://github.com/rails/rails/pull/39280#discussion_r425044432
- https://github.com/rails/rails/pull/38105#discussion_r361727643
- https://github.com/rails/rails/pull/38038#discussion_r360014814
- https://github.com/rails/rails/pull/32136#discussion_r172060576
- https://github.com/rails/rails/pull/31179#discussion_r152933920
- https://github.com/rails/rails/pull/29757#discussion_r126761693
- https://github.com/rails/rails/pull/29619#discussion_r125158589
- https://github.com/rails/rails/pull/28640#discussion_r112345526
- https://github.com/rails/rails/pull/27392#discussion_r94916285
- https://github.com/rails/rails/pull/24890#discussion_r64127158
- https://github.com/rails/rails/pull/23703#discussion_r52964097
- https://github.com/rails/rails/pull/16485#discussion_r16325802
- https://github.com/rails/rails/pull/16485#discussion_r16197969
- https://github.com/rails/rails/pull/10550#discussion_r4172791
- https://github.com/rails/rails/pull/1955#discussion_r57544
