---
id: rails-dirty-tracking-changed-edge-cases
layer: rails
frameworks: ["activerecord@*", "activemodel@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改了 `ActiveRecord::Type` / `ActiveModel::Type` 子類別（或其 helper module，如 `ActiveModel::Type::Helpers::Numeric`）裡的 `changed?`、`changed_in_place?` 或類似的 dirty-tracking 比較方法，內容是用 `old_value`、`new_value`、`new_value_before_type_cast` 做相等性判斷（`==`、`!=`、`.class !=`、`nan?`、字串轉數字檢查等），尤其是數字型別（Integer/Float/Decimal/Numeric）、有多種底層表示的型別（如 Cidr/Inet）。

## 判準
這類比較邏輯決定「同一欄位的新舊值是否算變更」，直接影響要不要送出 UPDATE、要不要觸發 `attribute_changed?`/callback。常見出錯點：
- `NaN != NaN` 永遠為真，若沒有特判 `equal_nan?`，會把「沒變的 NaN 欄位」誤判成 changed。
- `"Infinity"`／`Float::INFINITY` 這類特殊數值字串，容易被 `non_numeric_string?` 誤判成「不是數字」，導致沒變的值被標記為 changed；反過來，把特判寫得太窄（只處理 `Float::INFINITY` 而不是所有 `Numeric`）又會漏掉其他等價情況。
- 子類別（例如 Cidr）的 `cast_value` 可能已經做過型別正規化，父類別/mixin 再加一層 `old_value.class != new_value.class` 有可能是多餘的，也可能和子類別的正規化邏輯衝突，需要確認兩邊沒有互相踩踏。
- 條件用 `||`/`&&` 串接多個檢查時，順序影響效能：常見分支應該放前面讓它先短路，NaN 這種罕見分支應該放最後（如 `(super || number_to_non_number) && !equal_nan?` 優於把 `equal_nan?` 放最前面）。

錯誤方向是雙向的，且都不會在一般測試中明顯報錯：
- 判斷太寬鬆（該變沒偵測到）→ dirty tracking 認為沒變 → `save` 不會送出 UPDATE → 資料庫值與記憶體值不同步、資料實質遺失。
- 判斷太嚴格（沒變被判成變）→ 多餘 UPDATE、多餘 callback/validation 觸發，效能與副作用問題。

## 嚴重度
CRITICAL：漏報 changed 導致該欄位的 UPDATE 沒有送出（例如金額、狀態、主鍵關聯等欄位），造成資料庫值與程式內值悄悄不同步，且沒有任何錯誤訊息或測試會發現。
HIGH：一般數值/字串欄位的 changed? 判斷錯誤（誤報或漏報皆算），會影響 dirty tracking 正確性，但不涉及關鍵欄位或有其他保護機制（如 validation）會間接發現。
MEDIUM：只影響效能（檢查順序沒有把常見分支放前面）、或只在極端邊界值（如巢狀 NaN/Infinity 組合）才會出錯，功能上多數情況仍正確。

## 反例（不該報）
- 比較邏輯只用於展示/序列化給使用者看，不影響 `save`/dirty tracking 決策。
- 欄位型別已知不可能出現 NaN/Infinity/型別不一致（例如純 boolean、純 string 欄位）的簡單 `==`/`!=` 比較。
- 問題出在 `cast_value`/`cast` 本身把值轉錯，而不是 `changed?` 的比較邏輯——那屬於型別轉換正確性問題，不是這條規則要抓的 dirty-tracking 比較問題。

## 出處
- https://github.com/rails/rails/pull/51633#discussion_r1575499384
- https://github.com/rails/rails/pull/49904#discussion_r1382458043
- https://github.com/rails/rails/pull/42831#discussion_r674545383
