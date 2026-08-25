---
id: common-framework-semantics-missing-mode-interaction
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 新增或修改一段以「模式/環境旗標」為條件的分支邏輯——例如依 strict mode 與否、檔案是 `.ts` 還是 `.js`、ESM 還是 CommonJS、是否啟用某個 compiler/runtime option（如 `noCheck`、`verbatimModuleSyntax`）來決定行為——且該判斷式看起來只針對驅動這次改動的那一個情境（issue/repro/測試案例）調整過。看到這種變更時，要去確認：這個判斷式所耦合的旗標維度上，其餘的取值（另一種模式、另一種檔案類型、選項的其他組合、另一個既有旗標）是否也被同步考慮，還是這段邏輯只是針對眼前案例量身打造，其他組合仍照舊（或被新條件意外收窄/放寬）。

## 判準
資深 reviewer 的經驗是，這類條件式最容易「fit 到眼前的 test case 就收工」——因為驅動改動的通常只有一個 issue 或一份 repro，作者驗證到那個案例過了就停手。但底層的旗標維度（strict/非 strict、TS/JS、ESM/CJS、有無某個 option）彼此組合出的路徑遠多於那一個案例，漏掉的組合往往要等下一個使用者在不同設定下踩到才會被發現，而且因為問題是「行為沒有涵蓋到」而非「寫錯一行」，既有測試通常也抓不到。另一個常見變體是：兩個原本各自獨立判斷的旗標被合併或互相取代成一個條件，但合併後條件的語意其實跟原本兩者之一不對稱，造成規則在某個組合下被意外收窄或放寬。

## 嚴重度
CRITICAL：該分支邏輯直接影響型別檢查正確性或程式碼產出正確性（例如 emit、型別窄化、assignability 判斷），且遺漏的組合會讓使用者在常見設定下得到錯誤但不會被警告的結果（silently wrong）。
HIGH：遺漏的組合會導致明顯錯誤（誤報/漏報診斷、執行期崩潰、輸出不可用），但只在較少見或需要特定選項組合才會觸發。
MEDIUM：遺漏的組合只影響邊緣情境的體驗品質（例如某個 refactor/quick-fix 在特定檔案類型或選項下退化成次佳但仍屬正確的結果）。

## 反例（不該報）
- 條件式雖然只處理單一模式，但函式簽名、呼叫端型別或前置的 early return 已經保證另一個模式永遠不會走到這個分支——這種情況要往上追呼叫鏈確認，不能只看這個函式內部就判定「沒考慮到」。
- 該旗標維度的其他取值已有明確的既有測試涵蓋、或 PR 描述/commit message 已明說「這個模式刻意留給後續 PR」，屬於已知且已溝通的範圍縮減，不是漏做。
- 純粹的重構（搬動程式碼位置、改名、抽函式）沒有新增或改變任何條件式語意時，不適用此規則。

## 出處
- https://github.com/microsoft/TypeScript/pull/61261#discussion_r1967856575
- https://github.com/microsoft/TypeScript/pull/57934#discussion_r1561759782
- https://github.com/microsoft/TypeScript/pull/57029#discussion_r1454003393
- https://github.com/microsoft/TypeScript/pull/56713#discussion_r1420434963
- https://github.com/microsoft/TypeScript/pull/54728#discussion_r1237696385
- https://github.com/microsoft/TypeScript/pull/54726#discussion_r1237323651
- https://github.com/microsoft/TypeScript/pull/53542#discussion_r1162053002
- https://github.com/microsoft/TypeScript/pull/55503#discussion_r1305266209
- https://github.com/microsoft/TypeScript/pull/48861#discussion_r860186160
- https://github.com/microsoft/TypeScript/pull/49644#discussion_r908419633
