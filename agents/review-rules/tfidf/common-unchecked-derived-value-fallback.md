---
id: common-unchecked-derived-value-fallback
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
- 程式碼從「非本檔案直接產生」的來源取值後，用 non-null assertion（`!`）或直接假設一定存在的方式使用該值，尤其是傳給 `createDiagnosticForNodeInSourceFile` 之類需要 AST node 的 API（例如該屬性可能是從 extends 的設定檔繼承而來，此檔案的 `sourceFile` 裡根本沒有對應節點）。
- 新增或重構暫存/快取結構時，捨棄原本語意清楚的 key（如完整路徑）改用簡化過的 key（如把 index 字串化成 `"" + raw.sourceIndex`），且沒有註解說明為何改動、也未評估是否還需要這層快取。
- 新型別或欄位命名沿用既有前綴造成疊字/贅字（例如介面已叫 `ConfigFileSpecs`，內部欄位又叫 `filesSpecs`，多一個不必要的 `s`），讓後續維護者難以快速分辨這是陣列還是單一值。

## 判準
資深 reviewer 在意的是「這個值是不是真的保證存在」——當資料來源從單一檔案擴展成可能來自 extends chain 或合併結果時，原本「這裡一定有 AST node」的假設會悄悄失效，non-null assertion 會在執行期丟例外，或是診斷訊息定位到錯的地方（用整個檔案的通用診斷取代原本該指到的正確 node）。快取 key 或命名上的簡化如果沒有明確理由，會讓下一個讀者以為背後有特殊語意（例如以為把 sourceIndex stringify 是為了避免碰撞），實際上只是抄捷徑；長期會增加維護成本與誤讀風險。

## 嚴重度
CRITICAL：非本檔案來源的值被 `!` 斷言後直接使用，且該路徑在正常輸入下就會觸發（例如 extends 一個沒有 `files` 節點的 base config 就會炸掉，不需要刻意構造的邊角案例）。
HIGH：同樣是「值可能不存在但被當作一定存在」，但只影響診斷訊息的精準度（fallback 到粗略錯誤而非崩潰），或影響是否選對了正確的 fallback 路徑。
MEDIUM：純粹是命名贅字、快取 key 選擇不直觀等可讀性／一致性問題，不影響行為正確性。

## 反例（不該報）
- 值的來源明確保證在本檔案一定存在（例如剛從同一個 `sourceFile` parse 出來、沒有經過 extends/merge），此時用 `!` 或直接存取是安全的，不必要求額外的 undefined 檢查。
- 快取 key 或變數命名雖然簡短，但在該檔案的既有慣例下是一致的（例如整個檔案都用 index 當 key，不是這次改動臨時引入的特例），不應單獨挑出來報。
- 屬性名稱雖有輕微贅字，但已經是既有 public API/型別的一部分、改名會是破壞性變更，此時應建議留待下次 major 版本，而不是當作本次 PR 的阻塞問題。

## 出處
- https://github.com/microsoft/TypeScript/pull/26865#discussion_r216044228
- https://github.com/microsoft/TypeScript/pull/25425#discussion_r200483719
- https://github.com/microsoft/TypeScript/pull/17269#discussion_r132572920
