---
id: rails-generator-doc-api-breaking-change
layer: rails
frameworks: ["rails@>=4.0"]
severity_default: HIGH

---
## 觸發訊號
diff 修改了 railties generator 基底類別（如 `named_base.rb`）或 scaffold 模板中標註 `# :doc:` 的方法，或修改了 Rails core 的公開擴充方法（如 `ActiveSupport::HashWithIndifferentAccess#convert_value`），且符合下列任一情況：
- 一組互相委派的 helper 方法中，其中一個新增了參數/選項（如 `show_helper(local:, suffix:, entity:)`），但呼叫它的另一個方法（如 `edit_helper`）沒有同步轉發這些新參數。
- 既有公開方法的回傳型別被改變（例如 `namespaced_path` 從回傳 `String` 改成回傳 `Array`），且沒有任何 deprecation 路徑。
- 方法簽名的預設參數使用可變的 Hash/Array 字面值（如 `options = {}`），而非 frozen 常數或 `nil`。
- 在 scaffold controller 模板中新增了公開方法（如 `update_many`、`replace`），卻沒有清楚的命名慣例、可見性（public/private）規劃或文件/使用情境佐證。
- 模板中出現框架已隱式處理、因此多餘的程式碼（如 action 結尾明確呼叫 `head :no_content`，而 Rails 在找不到 template 時本就會隱式渲染它）。

## 判準
`# :doc:` 標註的方法與 generator 產出的模板程式碼，實質上是 Rails 應用與外掛依賴的公開 API 介面：
- 委派方法沒有同步轉發新參數，會造成呼叫端拿到不一致、殘缺的功能（`edit_helper` 用不到 `show_helper` 剛加的 `local:`/`suffix:`/`entity:`）。
- 公開方法回傳型別悄悄改變，會直接打破所有現有呼叫端對回傳值型別的假設，是典型的破壞性變更卻沒有走 deprecation 流程。
- 可變的 Hash/Array 預設參數是 Ruby 的經典陷阱，若方法內對該物件做了 mutate，會在多次呼叫間共享狀態，產生極難追的 bug。
- Generator 模板一旦合併，會被套用到每一個使用該 generator 的專案；若新增方法沒有清楚的用途、命名或文件，會讓所有下游專案背負一個沒被驗證過價值、卻難以移除的 API 表面。
- 框架已經隱式處理的行為若在模板中重複明寫，屬於誤導性的死重複程式碼，日後框架行為異動時容易產生不一致。

## 嚴重度
CRITICAL：公開 generator 方法的回傳型別改變（如 String → Array），且沒有相容處理或 deprecation，會讓現有呼叫端直接壞掉。
HIGH：一組委派/包裝方法中，只更新了被包裝的方法而沒有同步讓包裝方法轉發新參數，造成 API 表面不一致；或父類別（如 `Hash`）定義的方法被期待能在子類別 override 卻實際無效，導致設計無法達成預期行為。
MEDIUM：方法簽名使用可變 Hash/Array 作為預設參數值；scaffold 模板新增方法但命名、可見性或使用情境不清楚；模板中出現框架已隱式處理而顯得多餘的程式碼。

## 反例（不該報）
- 純粹的私有 helper 內部重構、且所有外部呼叫端行為完全不變，不算破壞性變更。
- 為既有公開方法新增可選的 keyword 參數，且所有既有呼叫端與委派方法都同步更新、行為保持相容，不該報。
- 模板新增的方法有清楚對應到標準 REST 動作、遵循既有命名慣例，且有 commit/PR 說明使用情境與可見性設計，不該報。
- 使用 `{}.freeze` 或具名 frozen 常數作為預設參數（如 `EMPTY_HASH = {}.freeze`），已經正確避免可變預設值問題，不該報。

## 出處
- https://github.com/rails/rails/pull/43611#discussion_r767178090
- https://github.com/rails/rails/pull/36758#discussion_r307300866
- https://github.com/rails/rails/pull/35249#discussion_r256614616
- https://github.com/rails/rails/pull/27550#discussion_r94523445
- https://github.com/rails/rails/pull/19832#discussion_r30533966
- https://github.com/rails/rails/pull/15719#discussion_r22818615
- https://github.com/rails/rails/pull/15719#discussion_r22775911
