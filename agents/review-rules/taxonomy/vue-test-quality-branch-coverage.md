---
id: vue-test-quality-branch-coverage
layer: vue
frameworks: ["vitest@*", "vue@*"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改了 `*.spec.ts` / `*.test-d.ts` 測試檔案，且符合下列任一情況：
- 同一個 PR 同時修改了被測程式碼中含分支的邏輯（if/else、多個 overload、boolean 參數、多個型別分支），但新增或修改的斷言只涵蓋其中一個分支/一種取值。
- 修改的是「既有測試案例」而不是新增獨立測試案例，且該修改讓原本用來區分兩個分支的差異消失（例如把只呼叫一次的物件改成呼叫兩次但結構相同）。
- 型別測試（`expectType` / `.test-d.ts`）把目前的推斷結果直接寫成期望值，而該推斷結果本身在 PR 描述或討論中被承認是不精確/過窄的（例如把 `defineModel({ default: 123 })` 推斷成字面量型別 `123` 而非 `number`）。
- 新增的斷言依賴一個特定執行環境旗標（如 `__BROWSER__`、`compatConfig`、特定 target build），但測試執行方式（node/jsdom/預設 test runner）不保證真的觸發該旗標。
- 斷言檢查的錯誤訊息/字串與 diff 中實際變更的程式碼路徑必須逐一核對觸發條件是否吻合（例如檢查是否真的是「required prop 缺失」而不是「prop 型別檢查失敗」這兩種不同訊息）。
- 新增了處理「屬性存在」情境的斷言，但沒有對應「屬性不存在」的負面情境斷言。

## 判準
資深 reviewer 在意的不是「測試綠燈」，而是「測試綠燈是否真的代表行為被驗證」。具體理由：
1. 只測 if 的一邊，把條件改成恆真/恆假測試依然會通過——測試沒有真正防住迴歸，覆蓋率數字會騙人。
2. 型別測試把「目前可能是 bug」的推斷結果寫成 `expectType` 期望值，等於把型別缺陷鎖進契約，之後沒人敢修，且未來修正型別反而會被這條測試擋下來。
3. 斷言檢查的訊息/路徑如果跟實際觸發的程式碼邏輯對不上，測試會誤導後人以為某個情境被保護了，實際上驗證的是另一條路徑。
4. 測試依賴的執行環境旗標若沒被真正觸發，等於新增了一段「看起來測了但實際沒跑到目標程式碼」的死斷言。
5. 只驗證正面情境、不驗證負面情境，代表移除該行為的迴歸不會被抓到。

## 嚴重度
CRITICAL：型別測試把已知不精確/過窄的推斷結果寫成 `expectType` 契約值；或斷言檢查的錯誤訊息/程式碼路徑與 diff 實際觸發的行為對不上（誤把 A 情境的驗證當成 B 情境）。
HIGH：修改既有測試而非新增測試，導致某個分支失去覆蓋（該分支被改壞也不會被抓到）；或斷言依賴的執行環境旗標實際未被觸發，等於沒有測到目標程式碼。
MEDIUM：新增邏輯有多個可能取值（如 boolean true/false、多個 overload）但測試只涵蓋其中一部分；或只驗證正面情境、缺少對應的負面情境斷言。

## 反例（不該報）
- PR 只是重構已被涵蓋分支的既有實作，沒有引入新分支或新取值，不需要額外測試。
- 缺的分支/情境已經在同一 PR 的其他測試案例、或同檔案其他斷言中被涵蓋（例如某個 attribute 的行為已由另一組斷言驗證過）。
- 新增的分支是型別系統本身保證不會發生的防禦性程式碼，沒有實際可觸發路徑，加測試無意義。
- 測試只是把既有斷言重新排版/搬移位置，邏輯覆蓋範圍完全沒變。

## 出處
- https://github.com/vuejs/core/pull/15251#discussion_r3749378222
- https://github.com/vuejs/core/pull/15107#discussion_r3620889334
- https://github.com/vuejs/core/pull/12445#discussion_r2109983944
- https://github.com/vuejs/core/pull/7297#discussion_r1616401883
- https://github.com/vuejs/core/pull/10187#discussion_r1462856775
- https://github.com/vuejs/core/pull/6138#discussion_r912720935
- https://github.com/vuejs/core/pull/3002#discussion_r603761076
