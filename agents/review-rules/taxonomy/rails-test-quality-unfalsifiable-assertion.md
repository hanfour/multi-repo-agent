---
id: rails-test-quality-unfalsifiable-assertion
layer: rails
frameworks: ["rails@*", "minitest@*"]
severity_default: HIGH
---
## 觸發訊號

diff 裡新增或修改了一個測試方法，且該測試方法的用途（方法名、緊鄰的 commit/PR 描述、或緊接在一段 production code 改動之後新增）宣稱是在驗證某個新行為、bug fix、或邊界情況。此時要去確認一件 diff 本身看不出來的事：**把這次 diff 中的 production code 改動還原成修改前的樣子，這個測試斷言是否依然會通過。**

具體要去核對的訊號包括：
- 測試方法只斷言「沒有拋錯」「回傳非 nil」「型別正確」等寬鬆條件，而不是斷言修改後才會出現的具體值/行為差異
- 測試的前置條件（如某個 gem 是否存在、某個 config 是否啟用、某個 helper 是否被呼叫）已經因為其他變動而失效，導致目標程式路徑根本沒被走到
- 測試方法完全沒有任何 assert 呼叫（純執行、不驗證結果）
- 新增的測試斷言其實只是複述另一個既有測試已經涵蓋的行為，沒有真正對到本次改動要保護的那條路徑

## 判準

Rails 核心維護者反覆抓到的模式是：作者以為「有測試」等於「有回歸保護」，但沒有真的檢查過那個測試在還原修改後是否會變紅。一個不會因為 bug 復發而失敗的測試，比沒有測試更危險——它會讓後續開發者誤以為這條路徑受保護，而放心地做進一步重構，最終讓同一個 bug 悄悄重新引入卻沒有任何測試示警。這類問題沒有語法上的錯誤可指，純粹要靠「反事實推理」（如果改動不在了會怎樣）才能抓到，因此是 reviewer 最容易漏掉的一類。

## 嚴重度

CRITICAL：這個測試是本次 PR 用來證明 bug 已修復或新行為已正確實作的**唯一或主要**證據，但還原 production code 改動後測試依然會通過——代表這次修的問題完全沒有回歸保護，且 reviewer/後續開發者會誤以為已涵蓋。
HIGH：測試確實會因為改動被還原而失敗，但斷言範疇明顯窄於方法名/情境所宣稱的行為（例如只斷言「沒有拋錯」而非斷言正確的回傳值），導致同一個 bug 的其他變形（例如錯誤的值、錯誤的邊界）仍然漏測。
MEDIUM：測試涵蓋了目標行為，但同時對與本次改動無關的內部實作細節／私有方法做了斷言，使測試變得脆弱，未來重構會觸發不相關的測試失敗。

## 反例（不該報）

- 單純的命名、格式、文件（guide/CHANGELOG）調整，未改變任何斷言的驗證範疇
- 把既有的寫法改成等價的慣用寫法（例如用 `assert_raises(..., match: ...)` 取代 `begin/rescue` 手動比對訊息），斷言涵蓋範圍不變
- 補上原本缺漏的 assert 呼叫，且新斷言確實會因為還原本次改動而失敗（這是在修正這類問題，不是引入）
- 測試新增了針對內部實作的斷言，但作者/reviewer 已在討論中明確認定這正是本次要鎖住的行為（例如驗證某個物件是否被延遲建立），而非附帶的無關細節

## 出處
- https://github.com/rails/rails/pull/55960#discussion_r2449529876
- https://github.com/rails/rails/pull/54679#discussion_r1982861424
- https://github.com/rails/rails/pull/50781#discussion_r1456132804
- https://github.com/rails/rails/pull/50276#discussion_r1420857200
- https://github.com/rails/rails/pull/50023#discussion_r1390447823
- https://github.com/rails/rails/pull/50023#discussion_r1390672509
- https://github.com/rails/rails/pull/50544#discussion_r1439928976
