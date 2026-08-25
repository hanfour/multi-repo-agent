---
id: react-jsx-children-attribute-name-assumption
layer: react
frameworks: ["react@*", "typescript@>=3.0"]
severity_default: MEDIUM
---
## 觸發訊號
Diff 新增或修改了「找出 JSX children 該放進哪個 prop」的邏輯 —— 例如硬編字面量 `"children"`、或讀取/比對 `ElementChildrenAttribute`（或框架對應的「哪個 prop 承接 children」設定）來決定型別檢查或執行期行為，但整份 diff（含新增測試）裡沒有任何一個案例把該屬性名稱改成非預設值（例如自訂 JSX namespace 把 `ElementChildrenAttribute` 設成 `"children"` 以外的名字）來驗證新邏輯在這種情境下仍正確、或仍如預期被忽略。

## 判準
JSX 的 children 屬性名稱在語言/工具鏈層是可設定的（透過 `ElementChildrenAttribute` 這類 per-namespace 設定），不是永遠等於字面量 `"children"`。當程式碼開始對這個名稱做特殊判斷（例如「就算 `ElementChildrenAttribute` 指到別的欄位，也要優先用硬編的 `children`」），這正是最容易被忽略、也最難靠一般測試自然覆蓋到的 corner case —— 因為預設設定下這條分支根本不會被觸發，回歸測試也不會失敗，直到有人真的自訂了這個屬性名稱才會炸。resident reviewer 在這種「新增特殊判斷邏輯」的 PR 上，會直接要求補一個「把設定改成非預設值」的測試，而不是等使用者回報。

## 嚴重度
CRITICAL：（不適用 —— 這是測試覆蓋缺口，非執行期立即致命問題）
HIGH：受影響的邏輯決定公開 API 的型別檢查/編譯正確性，且整個測試套件裡完全沒有任何案例覆蓋「自訂屬性名稱」路徑
MEDIUM：該區域已有一般性測試涵蓋，但新加入的硬編判斷分支本身未被任何自訂設定案例觸發到

## 反例（不該報）
- 純粹讀取 `props.children`（React 內建、應用層程式碼不可改名）的一般元件邏輯，不涉及任何「查詢/比對可設定的屬性名稱」邏輯 —— 不需要這類測試。
- 該段程式碼本身就是在讀取既有測試 baseline 或 CI log 的 diff（例如建置輸出、`.log`/`.types` 快照變動），不是新加的邏輯分支。
- PR 本身就是被要求的那個測試（即該意見已被採納補上），不用重複報。
- 對非 children 相關的重構（例如把迴圈換成 helper function、把陣列參數換成從節點取得 children 的方式）而產生的行為等價性疑問，屬於一般 review 問題，不屬於本規則範圍。

## 出處
- https://github.com/microsoft/TypeScript/pull/60880#discussion_r1899461274
- https://github.com/microsoft/TypeScript/pull/60377#discussion_r1823305824
- https://github.com/microsoft/TypeScript/pull/47500#discussion_r788044876
- https://github.com/microsoft/TypeScript/pull/42149#discussion_r553666937
- https://github.com/microsoft/TypeScript/pull/40953#discussion_r500574723
- https://github.com/microsoft/TypeScript/pull/40156#discussion_r487306967
- https://github.com/microsoft/TypeScript/pull/37697#discussion_r407611095
- https://github.com/microsoft/TypeScript/pull/31480#discussion_r286613761
- https://github.com/microsoft/TypeScript/pull/29264#discussion_r246974918
- https://github.com/microsoft/TypeScript/pull/24518#discussion_r194924632
- https://github.com/microsoft/TypeScript/pull/19249#discussion_r147000128
- https://github.com/microsoft/TypeScript/pull/18557#discussion_r139524352
- https://github.com/microsoft/TypeScript/pull/13640#discussion_r99244976
- https://github.com/microsoft/TypeScript/pull/8824#discussion_r64838983
