---
id: rails-missing-convention-support-actions
layer: rails
frameworks: ["rails@>=7.0"]
severity_default: HIGH
---
## 觸發訊號
- diff 新增一支新的 `*_test.rb` 檔案，且第一個類別繼承自 `ActiveSupport::TestCase`（或其他框架測試基底類別）時 → 去確認檔案開頭是否有 `require_relative "abstract_unit"`（或該目錄慣用的等價 require），不要假設 test loader 會自動載入，會導致該檔案單獨執行或在特定 CI 分片下直接炸掉。
- diff 在 CLI/Rails command（如 `railties/lib/rails/commands/**`）裡新增或修改一個會失敗的分支（讀不到值、找不到 key、bundle install 失敗等）時 → 去確認失敗訊息是否寫到 stderr（而不是只用 `say` 寫到 stdout），以及是否回傳非 0 的 exit code，而不是預設把失敗吞掉讓指令看起來成功。
- diff 新增一個非 `:nodoc:` 的公開方法、常數、Struct 或例外子類別，且它帶有欄位、選項或特定用途（例如新的 `RateLimit` struct、新的 exception 子類別、新的可設定行為）時 → 去確認是否補上對應的 RDoc 註解或 guide 更新，說明用途與可用欄位/選項，而不是只讓實作說話。
- diff 把「某個步驟本來由基底方法/框架統一保證」改成「需要每個呼叫端各自記得做」（例如把預設行為從共用方法搬到呼叫端各自處理）時 → 去確認現有每一個呼叫點是否都同步更新了，還是可能有呼叫點會漏掉這個步驟而悄悄改變行為。
- diff 讓一個查找/lookup 類方法在「查無資料」時直接回傳 `nil`、卻沒有和「值本身就合法地是 nil」的情況分開處理時 → 去確認是否應該改成明確拋出「找不到」的例外，而不是讓兩種語意不同的情況被呼叫端一併當成「有值」。

## 判準
Rails 是高度慣例化的框架，reviewer 在意的往往不是這行程式碼本身寫錯了什麼，而是這次新增的東西沒有跟上既有慣例所隱含的「配套動作」：漏了 require，測試在被單獨或分片執行時就會炸；CLI 失敗卻用 stdout + exit 0，呼叫它的腳本會誤判成功、在壞資料上繼續跑下去；新增的公開介面沒有文件，下一個使用者要嘛用錯要嘛得回頭去讀原始碼；正確性保證從「框架統一處理」退化成「呼叫端自己要記得」，等於把行為的一致性寄託在人的記性上，遲早會有某個呼叫點忘記跟進。這些問題的共同點是：只盯著那一行 diff 本身完全看不出哪裡錯，必須把它放回「這個 repo 對這類新增通常還會連帶做什麼」的脈絡裡，才看得出少了什麼。

## 嚴重度
CRITICAL：失敗路徑沒有依照慣例回報失敗（CLI 指令失敗卻寫到 stdout 且 exit code 是 0、或錯誤被吞掉只留下模糊訊息），導致自動化腳本/CI 誤判成功並在壞資料或半完成狀態上繼續執行；或「查無資料」與「合法的 nil」被混為一談，讓呼叫端把找不到的情況誤判為有效值。
HIGH：某個正確性保證從「基底方法/框架統一處理」被下放成「每個呼叫端要自己記得做」，而目前的呼叫點沒有全部跟著更新，會在特定路徑悄悄漏掉、產生行為不一致。
MEDIUM：新增的公開方法、Struct、例外類別或設定選項缺少對應文件（RDoc 或 guide），或新增的測試檔缺少必要的 require，導致單獨執行會失敗但不影響完整測試套件整體結果。

## 反例（不該報）
- 討論串裡 reviewer 只是在比較兩種設計方案的取捨（例如是否要額外做一個 ractor-local 版本的 cache key generator），本身沒有指出實際少了什麼，甚至事後自己撤回意見。
- 被標記 `:nodoc:` 的私有/內部 helper 方法，本來就不預期要有公開文件。
- 只是調整既有文件段落的措辭、排版、範例順序或補一個換行，內容本身沒有遺漏任何說明。
- 呼叫端本來就被設計成可以合法地不做某個步驟（例如允許 `nil` 作為合法輸入本身，而不是「查無資料」的訊號），不要把設計上允許的可選行為當成缺漏來報。

## 出處
- https://github.com/rails/rails/pull/58049#discussion_r3540616950
- https://github.com/rails/rails/pull/57825#discussion_r3529180258
- https://github.com/rails/rails/pull/57662#discussion_r3460122776
- https://github.com/rails/rails/pull/57754#discussion_r3456211984
- https://github.com/rails/rails/pull/57742#discussion_r3421379772
- https://github.com/rails/rails/pull/57381#discussion_r3396655675
- https://github.com/rails/rails/pull/57381#discussion_r3396033377
- https://github.com/rails/rails/pull/57381#discussion_r3395973896
- https://github.com/rails/rails/pull/57381#discussion_r3395595826
- https://github.com/rails/rails/pull/57381#discussion_r3388421450
- https://github.com/rails/rails/pull/57395#discussion_r3337244204
- https://github.com/rails/rails/pull/57508#discussion_r3330866565
- https://github.com/rails/rails/pull/57467#discussion_r3314772972
- https://github.com/rails/rails/pull/57123#discussion_r3307550658
- https://github.com/rails/rails/pull/56340#discussion_r3280080906
- https://github.com/rails/rails/pull/57036#discussion_r3214286680
- https://github.com/rails/rails/pull/56341#discussion_r3051211832
- https://github.com/rails/rails/pull/56341#discussion_r3051207206
- https://github.com/rails/rails/pull/57012#discussion_r2958233847
- https://github.com/rails/rails/pull/56538#discussion_r2674388756
- https://github.com/rails/rails/pull/56496#discussion_r2669456903
- https://github.com/rails/rails/pull/56430#discussion_r2649813979
- https://github.com/rails/rails/pull/56384#discussion_r2634013310
- https://github.com/rails/rails/pull/56307#discussion_r2597793756
- https://github.com/rails/rails/pull/56202#discussion_r2550665809
- https://github.com/rails/rails/pull/56080#discussion_r2503041762
- https://github.com/rails/rails/pull/55928#discussion_r2500085289
- https://github.com/rails/rails/pull/55924#discussion_r2441567342
- https://github.com/rails/rails/pull/55900#discussion_r2437913407
- https://github.com/rails/rails/pull/54251#discussion_r2388075679
- https://github.com/rails/rails/pull/55690#discussion_r2365971571
- https://github.com/rails/rails/pull/55565#discussion_r2310407750
- https://github.com/rails/rails/pull/55565#discussion_r2310405844
- https://github.com/rails/rails/pull/55515#discussion_r2286958305
- https://github.com/rails/rails/pull/53146#discussion_r2271411547
- https://github.com/rails/rails/pull/55445#discussion_r2265208721
- https://github.com/rails/rails/pull/53119#discussion_r2250807054
- https://github.com/rails/rails/pull/53119#discussion_r2250805287
- https://github.com/rails/rails/pull/55334#discussion_r2244024021
- https://github.com/rails/rails/pull/55405#discussion_r2236463825
