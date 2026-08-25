---
id: react-test-expectation-encodes-known-bug
layer: react
frameworks: ["react@*"]
severity_default: LOW

---
## 觸發訊號
測試的 expected 值/序列被改成「跟現在的實際輸出一致」，但 diff 或殘留的舊 comment 顯示這個行為其實是已知 bug、TODO 待修、或兩種 reconciler（Stack vs Fiber）不一致的產物；常見形式是刪掉解釋性 comment（例如「TODO: We should fix this」「due to the bug in #xxxx」）同時把條件分支（`if (ReactDOMFeatureFlags.useFiber) {...} else {...}`）攤平成單一寫死的期望陣列。

## 判準
測試應該斷言「正確行為」，不是「目前行為」。當作者為了讓測試通過而把已知錯誤的輸出寫死進 expected，且順手刪掉解釋這個怪異順序為何存在的 comment，之後的人讀到這條測試會誤以為這是設計如此，而不是待修的 bug——追蹤 issue 和意圖就這樣不見了。尤其當同一份 diff 同時在消除兩個 reconciler 之間的行為分支（用把其中一邊悄悄改成另一邊看齊）時，更需要先確認這是「行為統一」還是「掩蓋不一致」。

## 嚴重度
CRITICAL：（不適用於此類問題）
HIGH：把已知 bug 的行為寫死為 expected，且沒有任何 TODO/issue 連結或 comment 說明，導致該 bug 事實上被永久鎖定為「規格」。
MEDIUM：刪除了原本解釋 bug/差異成因的 comment，或把 Stack/Fiber 的條件分支合併卻沒有討論這是否代表 bug 已修好。

## 反例（不該報）
- expected 值的改動有對應的行為修正（bug 真的被修掉了），測試只是反映新的正確行為。
- 保留或新增了解釋性 comment／TODO／issue 連結，說明這個 expected 值目前反映的是已知限制。
- 純粹的程式碼風格清理（例如把陣列 push 改成字面量宣告）沒有改變任何斷言內容或刪除任何解釋性 comment。

## 出處
- https://github.com/react/react/pull/9101#discussion_r104095811
- https://github.com/react/react/pull/8585#discussion_r93339643
- https://github.com/react/react/pull/8127#discussion_r85642218
