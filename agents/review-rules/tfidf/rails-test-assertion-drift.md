---
id: rails-test-assertion-drift
layer: rails
frameworks: ["rails@*", "minitest@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 修改了既有測試的 setup、斷言內容，或 `current_adapter?(...)` / `unless current_adapter?(...)` 之類的 adapter/config 條件式，但測試方法名稱或上方註解仍描述原本的情境（例如方法名叫 `test_condition_utc_time_interpolation_with_default_timezone_local`，但斷言已經不再涉及 UTC 轉換）；或新增的測試與緊鄰的另一個測試斷言形狀幾乎相同、只是換了關聯型別或欄位名稱，卻沒有驗證任何新行為；或 `current_adapter?` 條件式列出的 adapter 集合與該行為實際支援/需要驗證的 adapter 集合對不上（例如新增了某個 adapter 卻沒有更新既有的 guard，或 guard 排除了本該涵蓋的 adapter）；或斷言的目標是語言/框架本身保證的行為（如 `Array#first`、`Array#last` 的回傳型別）而非被測程式碼本身的行為。

## 判準
這類測試會製造假的安全感：它們照樣是綠燈，但已經不再驗證當初撰寫時要防的那個回歸，之後有人重構時可以在完全沒有紅燈警示的情況下悄悄破壞原本的行為（例如 timezone 轉換自某個 commit 起就沒被真正測到）。重複斷言則是拉長測試套件執行時間、增加維護成本卻沒有新增覆蓋率。Adapter 條件式寫錯（列漏或列多）意味著 CI 在某些 adapter 上綠燈，並不代表共用邏輯真的被驗證過——尤其是像 Trilogy 這種尚未支援 prepared statements 的 adapter，被錯誤地併入只給支援 prepared statements 的 adapter 用的判斷式時，測試可能從未在該 adapter 上真正執行過。

## 嚴重度
CRITICAL：guard 條件寫反或範圍被縮到空集合，導致該行為在任何 adapter/config 組合下都完全零覆蓋。
HIGH：測試自某個已知 commit 起就沒有真的驗證它宣稱的行為（方法名/註解與斷言內容不符），且該行為屬於使用者可觀察的正確性議題（如 timezone、prepared statements、資料完整性）。
MEDIUM：測試與相鄰測試重複覆蓋、斷言的是語言/框架本身保證的行為而非受測程式碼、或 adapter 條件式範圍過寬/過窄但不影響目前主要行為的正確性驗證。

## 反例（不該報）
- `current_adapter?` guard 正確反映了「該行為在不同 adapter 上本來就有差異」的事實，條件式與支援矩陣相符。
- 兩個測試共用 setup，但驗證的是真正不同的後置條件（不只是外觀相似）。
- 新測試刻意與既有測試重疊，是因為 reviewer 明確要求要有更貼近真實情境的範例（如把 id 換成 name 讓案例更寫實），而非意外重複。
- 斷言 `#first`/`#last` 等方法，但驗證的是 ActiveRecord 覆寫過的版本（而非 Ruby core 的版本）——這正是被測程式碼本身。

## 出處
- https://github.com/rails/rails/pull/53745#discussion_r1858192249
- https://github.com/rails/rails/pull/53702#discussion_r1857970337
- https://github.com/rails/rails/pull/53600#discussion_r1839317053
- https://github.com/rails/rails/pull/53139#discussion_r1831493110
- https://github.com/rails/rails/pull/51474#discussion_r1549609663
- https://github.com/rails/rails/pull/49345#discussion_r1333172648
- https://github.com/rails/rails/pull/49096#discussion_r1316296519
- https://github.com/rails/rails/pull/45501#discussion_r912231703
- https://github.com/rails/rails/pull/45218#discussion_r885674807
- https://github.com/rails/rails/pull/45192#discussion_r884161519
- https://github.com/rails/rails/pull/45020#discussion_r873090135
- https://github.com/rails/rails/pull/43517#discussion_r735785181
- https://github.com/rails/rails/pull/42572#discussion_r658201725
- https://github.com/rails/rails/pull/42173#discussion_r628717807
- https://github.com/rails/rails/pull/40645#discussion_r527108102
- https://github.com/rails/rails/pull/40383#discussion_r512585610
- https://github.com/rails/rails/pull/36481#discussion_r450085424
- https://github.com/rails/rails/pull/37986#discussion_r358273502
- https://github.com/rails/rails/pull/35320#discussion_r264024975
- https://github.com/rails/rails/pull/34607#discussion_r238524635
- https://github.com/rails/rails/pull/32865#discussion_r189588429
- https://github.com/rails/rails/pull/27597#discussion_r160407007
- https://github.com/rails/rails/pull/31091#discussion_r149834357
- https://github.com/rails/rails/pull/30980#discussion_r147048596
- https://github.com/rails/rails/pull/29092#discussion_r117074205
- https://github.com/rails/rails/pull/27118#discussion_r88795279
- https://github.com/rails/rails/pull/19155#discussion_r25622556
- https://github.com/rails/rails/pull/17858#discussion_r22460074
- https://github.com/rails/rails/pull/17217#discussion_r18648313
- https://github.com/rails/rails/pull/14052#discussion_r9853695
- https://github.com/rails/rails/pull/7839#discussion_r1949864
