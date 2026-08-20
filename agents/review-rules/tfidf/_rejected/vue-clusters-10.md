---
id: common-focused-test-left-in-diff
layer: common
frameworks: ["jasmine@*", "jest@*", "mocha@*", "vitest@*"]
severity_default: CRITICAL
---
## 觸發訊號
diff 新增或修改的測試檔案中出現 focused/exclusive 測試 API：`fit(`、`fdescribe(`、`it.only(`、`test.only(`、`describe.only(`、`context.only(` 等，特別是把既有的 `it(`/`describe(` 改成上述形式，或在新增的測試區塊中直接使用它們。

## 判準
focused test 會讓測試 runner 只執行被標記的案例，同檔案甚至同一 suite 內其餘案例會被靜默跳過（不會顯示為 fail 或明確警告）。這種寫法通常是開發者本地除錯時暫時加上、忘了改回來的殘留，一旦被合併，CI 依然綠燈，但實際上大量既有測試沒有真的被跑到，任何後續回歸都不會被抓到，直到有人偶然發現才補救——risk 是隱性且會累積的。

## 嚴重度
CRITICAL：出現在會被 CI 實際執行的測試檔（非明確標記為草稿/實驗性質），diff 本身新增或改出 fit/fdescribe/.only，會導致同檔或同 suite 其他既有案例被靜默停用。
HIGH：focused test 出現在大型或跨功能共用的 spec 檔案中，被靜默跳過的案例數量多、涉及範圍廣，回歸偵測缺口大。
MEDIUM：出現在案例數很少的小型 spec 檔案，或有明確跡象顯示屬於暫時性、不會進主分支的草稿測試檔。

## 反例（不該報）
- `.only(`/`fit(` 只是出現在字串常量、註解、或文件/教學範例中，並非實際的測試框架呼叫。
- PR 目的就是撰寫測試框架相關的工具、linter 規則或說明文件，其中刻意展示 `fit`/`.only` 的用法作為範例本身。
- diff 是把既有的 `fit`/`.only` 改回正常的 `it`/`describe`，這是在修正而不是引入問題。

## 出處
- https://github.com/vuejs/vue/pull/3826#discussion_r81695449
- https://github.com/vuejs/vue/pull/3097#discussion_r67564035
