---
id: common-error-guard-condition-incomplete-category-coverage
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號

diff 新增或修改一個用來判斷「是否要對某個分支/某類資料執行特殊處理（或跳過處理）」的布林守衛條件，且該條件是靠下列方式之一分類輸入：

- type-flag / kind 檢查（例如 `isXxxType(...)`、`node.kind === X`、`symbol.flags & X`）
- 集合成員資格判斷（例如某個 `isXxxSymbol` / `isXxxKind` 的輔助函式）
- 數值邊界比較（例如 `length !== 1`、`length > 1`、`count === 0`）
- 字串/列舉比對（例如 `moduleKind !== ESNext`、`relation !== comparableRelation`）

出現這種變更時，要去確認：這個條件所依賴的分類方式，是否窮舉了呼叫端實際會傳進來的所有子類型/子情況——尤其是新加的參數形式、新的 literal 種類、或條件判斷式本身合併/簡化前後的邊界值是否一致。

## 判準

這類守衛條件的問題不是「這行邏輯寫錯」，而是「這行邏輯看起來對，但分類本身不完整」。常見成因：

- 用來分類的輔助函式（如 `isUnitType`）本身就有已知的涵蓋範圍缺口，作者在寫守衛時假設它是完整的
- 數值邊界條件在新增一種合法輸入形式後沒有跟著放寬（例如允許第二個參數後，仍用舊的「剛好等於 1」判斷）
- 條件只驗證「本地」/「最常見」的情況，沒有考慮跨模組、跨檔案、或延遲載入的情況會導致同一個判斷提早/在資料還沒齊全時執行
- 因為主流程測試都命中「常見分類」，這種缺口不會讓建置失敗、不會丟例外，只會在特定子類型輸入時悄悄算出/處理錯的結果，所以很難靠常規測試撈到

## 嚴重度
CRITICAL：守衛條件錯誤會讓核心正確性判斷（型別可賦值性、資料一致性、序列化正確性）在特定子型別或邊界值下產生**錯誤但不報錯**的結果，使用者難以察覺（例如 `isUnitType` 沒把 enum literal type 算進去，導致特定型別的可賦值性檢查悄悄放行本該報錯的賦值）

HIGH：守衛條件遺漏的分支會造成明確可觀察的功能錯誤（例如參數解析、輸出格式不符預期），使用者或整合方會踩到但不會被靜默吞掉

MEDIUM：守衛條件遺漏的分支只影響邊緣情境、內部工具或開發環境行為，影響範圍小，或有其他防護機制（例如上層已先擋掉非法輸入）兜底

## 反例（不該報）
- 守衛條件是明確的效能優化早退路徑（fast path），漏掉某些分支時會落到正確但較慢的慢路徑，不影響結果正確性——這不算本類問題
- 條件範圍的縮限是刻意且已知的設計取捨，並有註解、issue 或測試明確標註「暫不支援 X，之後再處理」——不該視為漏抓
- 純粹重新排列既有條件式的寫法（如把 `!(a || b)` 換成 `!a && !b`）而語意完全等價，沒有改變涵蓋範圍——不算本類問題

## 出處
- https://github.com/microsoft/TypeScript/pull/51140#discussion_r993857211
- https://github.com/microsoft/TypeScript/pull/40698#discussion_r705688674
- https://github.com/microsoft/TypeScript/pull/35764#discussion_r359647264
- https://github.com/microsoft/TypeScript/pull/32372#discussion_r328362555
- https://github.com/microsoft/TypeScript/pull/32517#discussion_r321461079
- https://github.com/microsoft/TypeScript/pull/47732#discussion_r805019894
