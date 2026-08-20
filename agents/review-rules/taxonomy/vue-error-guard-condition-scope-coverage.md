---
id: vue-error-guard-condition-scope-coverage
layer: vue
frameworks: ["vue@3.x"]
severity_default: CRITICAL
---
## 觸發訊號
diff 裡新增或修改了一個「依賴特定型別/子情境判斷」的守衛結構——if/else 分支、try/catch、條件型別（conditional type）、或針對某個子類別（如 `DynamicFragment`、`isPromise` 之類的 duck-typing 檢查）新增的特化處理——且該判斷只針對作者手上驗證過的那一種情境。此時要回頭確認：同一個抽象下還有哪些其他變體（sibling subtypes、其他呼叫路徑、其他 fallback 情境）符合相同的邏輯條件，卻沒有被這個新守衛涵蓋到；以及這個新守衛是否會意外攔截/改變原本刻意放行的既有行為（尤其是既有測試依賴的行為）。

## 判準
這類問題不是守衛寫錯了語法，而是守衛只解了作者眼前那一個 case，沒有窮舉同一抽象層下的所有變體。常見兩種失效方向：
1. 新增的 catch/if 分支比原本設計更「收斂」，把本來允許繼續執行、繼續渲染的路徑，變成提早中止或改變終態，卻沒人重新檢視過那些依賴舊行為的既有測試或呼叫者（例如把非終態的 async setup 錯誤，因為新的 catch 而變成終止渲染）。
2. 新增的 if 分支只針對某個具體子型別（如 `DynamicFragment`）寫死判斷式，導致同一基底類別下的其他子型別（如空列表的 `createFor`）落入 else 分支或完全繞過該邏輯，該有的 fallback / 錯誤處理就此消失。
資深 reviewer 抓這類問題的方式是「盯著這個條件式想：還有誰符合這個語意但沒被這行程式碼認出來？」而不是檢查條件式本身有沒有語法錯誤。

## 嚴重度
CRITICAL：守衛遺漏或條件過窄，導致既有測試依賴的行為被打破，或某個 sibling 子型別完全喪失原本該有的處理（例如 fallback 不渲染、subtree 提早中止而破壞現有 Suspense 語意）。
HIGH：守衛條件過寬或依據錯誤前提（例如以「是否在 render 中」為由發警告，卻沒真的檢查是否在 render 中），導致合法情境被誤判為錯誤（如內部 `isPromise`/`toTypeString` 這類 duck-typing 檢查被誤觸發警告）。
MEDIUM：條件涵蓋的邊界情況（如型別系統中排除某個 constructor 分支）在極少數呼叫路徑下行為不一致，但影響範圍侷限、不影響主流程正確性。

## 反例（不該報）
純格式/排版問題（例如換行位置不符 prettier 規則）不屬於這類，即使出現在同一個 diff 附近，也不要當成條件覆蓋問題來報。若守衛條件本身刻意窄化，且 PR 描述或程式碼註解已明確說明只處理特定子集合、其餘情境有另外的既有處理路徑或已有對應測試覆蓋，則不該報——那是刻意的範圍限縮，不是遺漏。

## 出處
- https://github.com/vuejs/core/pull/12601#discussion_r3567819342
- https://github.com/vuejs/core/pull/13669#discussion_r2224184702
- https://github.com/vuejs/core/pull/5010#discussion_r2147413654
- https://github.com/vuejs/core/pull/8953#discussion_r1334079969
- https://github.com/vuejs/core/pull/3682#discussion_r620600580
