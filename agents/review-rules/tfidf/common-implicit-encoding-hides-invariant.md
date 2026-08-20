---
id: common-implicit-encoding-hides-invariant
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM

---
## 觸發訊號
diff 出現以下任一種「用隱含編碼取代明確不變量」的寫法：
1. 把一個原本非零、有獨立語意的 enum 成員改成 `0`（或跟另一個成員同值），理由只是「反正它 desugar/預設就是 0」；
2. 新增或修改條件式時，用某個具體的 AST node/token kind（例如 `n.kind === SyntaxKind.EndOfFileToken`）當作某個結構性屬性（寬度、位置、是否為空）的代理判斷，而不是直接檢查該屬性本身；
3. 在同一個 interface 裡同時宣告 instance 成員與建構子簽名（`new(...): T`），而不是拆出獨立的 `TConstructor`/static interface。

## 判準
這三種寫法的共同問題是「編碼方式跟真正想表達的語意/不變量不是一一對應的」，資深 reviewer 會擋下來是因為：
- enum 成員值改成 0 後，未來如果要再區分「這個 case」跟「真正的 None/預設」，會失去可辨識性，且這層意圖沒有留下任何說明（如 ClassHeritageClauses 從 256 改成 0 引發的討論）；
- 用 token/node kind 當某個結構性屬性的代理，只有在兩者是嚴格 1:1 對應時才安全；一旦該屬性其實會因其他條件變化（例如 EOF token 有沒有 trailing trivia 決定它是否為 zero-width），這個代理判斷就會在部分輸入下算錯；
- 把建構子簽名混進 instance interface，會讓型別系統認為每個 instance 都有 `new` 成員，這在語意上是錯的，正確做法是拆出獨立的 constructor interface 再用 `declare var Foo: FooConstructor` 綁定。

## 嚴重度
CRITICAL：kind-as-proxy 的假設實際上不成立，且已經造成邏輯錯誤（例如 missing-node 判斷用 `kind !== EndOfFileToken` 排除 EOF，但 EOF token 的 zero-width 與否其實取決於是否有 trailing trivia，導致該判斷在部分情況下誤判）。
HIGH：interface 結構本身就是錯的（建構子簽名混入 instance interface），導致公開型別的形狀不正確。
MEDIUM：enum 成員被改成跟另一個成員同值（尤其是 0）卻沒有留下說明，削弱未來可擴充性/可讀性，但目前尚未觸發實際 bug。

## 反例（不該報）
- enum 成員本來就是要表達「None/預設值」而設為 0，且沒有其他 case 會跟它搶語意，這是正常寫法，不該報；
- 用 node/token kind 做條件判斷時，如果該 kind 本身就是要檢查的目標（例如只是要跳過 EOF node 的處理，而不是拿它去推論寬度或其他屬性），這是正常用法，不該報；
- 已經正確拆出獨立的 `XxxConstructor` interface，再用 `declare var Xxx: XxxConstructor` 綁定，只有把建構子簽名直接塞進 instance interface 的寫法才該報。

## 出處
- https://github.com/microsoft/TypeScript/pull/46682#discussion_r743149916
- https://github.com/microsoft/TypeScript/pull/22801#discussion_r176569866
- https://github.com/microsoft/TypeScript/pull/18860#discussion_r150370995
- https://github.com/microsoft/TypeScript/pull/4306#discussion_r37019480
- https://github.com/microsoft/TypeScript/pull/1363#discussion_r21284026
