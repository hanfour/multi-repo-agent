---
id: rails-low-value-test-additions
layer: rails
frameworks: ["minitest@*", "rails@>=5"]
severity_default: MEDIUM
---
## 觸發訊號
diff 新增或修改 `test/**/*_test.rb`（或等價的 Minitest/ActiveSupport::TestCase 測試檔）時出現以下任一情形：
1. 針對非公開介面、不預期被外部直接呼叫的內部類別/方法撰寫測試（例如直接 `new` 一個 internal formatter/factory class 只為了測 `ArgumentError`）。
2. `assert_equal` 比對前把 `expected`/`actual` 做 `.strip`、正規表達式或其他正規化處理，或改用局部/包含式比對，取代原本可以精確比對整段字串的寫法。
3. 為了目前只有一個呼叫點的測試，新增共用 helper/setup 抽象（如額外的 `with_xxx` wrapper method）。
4. 新增測試時發現行為不如預期，用 `skip "之後修"` 附註延後處理，而不是在同一個 PR 內把實作修好。

## 判準
這些改動表面上是在補測試覆蓋率，實際上沒有提升防迴歸能力，甚至會製造假象：測到內部實作細節的測試在重構時常被迫跟著改，卻抓不到任何真實行為錯誤；用 `.strip`/局部比對弱化 `assert_equal` 等於放棄了原本要鎖定的精確輸出，之後這段輸出跑掉也不會被抓到，測試變成「看起來測到」但實際上沒有迴歸保護；沒有第二個呼叫點的 helper 抽象只是多一層要維護的間接層，之後測試被刪改時很難跟著清乾淨；`skip` 附註「之後修」在忙碌的專案裡極容易被遺忘，變成長期技術債甚至掩蓋已知 bug。Rails core reviewer 的一貫立場是：沒有真正防護力或已知有問題的測試，寧可當場砍掉／修好，也不要留著製造維護負擔。

## 嚴重度
CRITICAL：把原本用來防止安全相關輸出（SQL sanitize 結果、逸出字元、權限判斷）迴歸的精確 `assert_equal` 改成寬鬆/正規化比對，導致該行為壞掉時測試仍綠燈。
HIGH：新增測試時在同一個 PR 裡發現既有 bug 或行為不如預期，卻用 `skip` 加註記延後而非就地修掉；或把原本精確比對整段輸出的 `assert_equal` 改成 `.strip`/局部比對，使既有迴歸保護消失。
MEDIUM：針對明確不對外開放呼叫的內部類別/私有 API 撰寫的測試；或為單一呼叫點提前抽出測試 helper/共用工具方法。

## 反例（不該報）
測試目標本來就是公開或半公開的行為契約，即使實作類別命名看起來像內部命名，也不算是在測內部細節。被比較內容含有環境相依或非決定性雜訊（時間戳、隨機 ID、路徑分隔符）時使用正規化或局部比對，是合理且必要的作法，不算放寬判準。`skip` 附上明確的 tracking issue 連結、且該問題確定不在本 PR 範圍內時，是合理的延後方式，不應被要求當場修掉。helper 從一開始就明確會被多個測試檔重用（例如共用 fixture 設定）而先行抽出，不算過早抽象。

## 出處
- https://github.com/rails/rails/pull/57381#discussion_r3396355008
- https://github.com/rails/rails/pull/56909#discussion_r2925121487
- https://github.com/rails/rails/pull/49856#discussion_r1451634684
- https://github.com/rails/rails/pull/48835#discussion_r1277681284
- https://github.com/rails/rails/pull/48133#discussion_r1185494313
- https://github.com/rails/rails/pull/47376#discussion_r1104975875
- https://github.com/rails/rails/pull/46454#discussion_r1020549857
- https://github.com/rails/rails/pull/45527#discussion_r927176000
- https://github.com/rails/rails/pull/45337#discussion_r895881353
- https://github.com/rails/rails/pull/45081#discussion_r872897245
- https://github.com/rails/rails/pull/44429#discussion_r807712958
- https://github.com/rails/rails/pull/42061#discussion_r688058295
- https://github.com/rails/rails/pull/41522#discussion_r581176834
- https://github.com/rails/rails/pull/21267#discussion_r37279864
- https://github.com/rails/rails/pull/18942#discussion_r25365829
- https://github.com/rails/rails/pull/14546#discussion_r11145450
- https://github.com/rails/rails/pull/12450#discussion_r6963680
- https://github.com/rails/rails/pull/10884#discussion_r4775693
- https://github.com/rails/rails/pull/8497#discussion_r2396500
