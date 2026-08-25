---
id: common-stale-rule-name-after-widened-condition
layer: common
frameworks: ["*"]
severity_default: LOW
---
## 觸發訊號
diff 修改了一個「具名規則 / 規則表項目」的判斷條件（例如 `rule("SomeName", leftTokenRange, rightTokenRange, [predicate1, predicate2, ...], action)` 這類規則表、或以字串/常數命名的 lookup table entry、switch-case 分支），把原本只匹配單一 token/enum 值的條件擴大成陣列或聯集（例如從 `SyntaxKind.FunctionKeyword` 改成 `[SyntaxKind.FunctionKeyword, SyntaxKind.AsteriskToken]`），但規則的名稱字串/identifier（如 `"SpaceAfterAnonymousFunctionKeyword"`）維持不變，沒有跟著調整以反映新涵蓋的情境。

## 判準
規則名稱本質上是給未來維護者（含日後的 code search / grep）看的文件。當條件被悄悄擴大但名字沒跟上，後續有人依賴名字判斷規則涵蓋範圍時會做出錯誤假設：可能誤以為某情境沒有被任何規則覆蓋，因而新增一條重複/衝突的規則；也可能在除錯格式化或分派邏輯時，只看名字就跳過本該檢查的這條規則。這類 rule-table/lookup-table 系統（formatting rules、驗證規則、feature flag 規則等）通常規則數量多、彼此隱含互斥假設，命名與實際條件的落差會隨規則表成長而放大維護成本。

## 嚴重度
CRITICAL：規則名稱本身被程式邏輯當作 key 使用（例如序列化後拿去比對、當作外部可見的 rule ID/feature flag key），名實不符會直接導致執行期行為錯誤，而不只是誤導人類讀者。
HIGH：規則屬於對外/跨團隊的 API 表面（exported constant、有文件的 linter rule ID），下游使用者會依名稱字面意義判斷規則行為。
MEDIUM：規則僅存在於內部規則表，名實落差只影響未來維護者閱讀/除錯時的理解成本（本 cluster 中最常見的情況）。

## 反例（不該報）
- 作者在同一個 PR 已經主動把名稱一併改掉、使其對齊新條件（如「重新命名了一堆舊東西，應該合理多了」這類 PR 說明）——這是修正而非問題，不該報。
- 作者明確承認名字現在是「有點誤稱」，但基於實際使用者心智模型／既有 issue 討論，判斷保留舊名更符合直覺，並在 PR 留言中說明理由——這是經過權衡的決定，只能標記為建議層級（LOW/MEDIUM），不應要求強制改名。
- 條件的擴大只是同一抽象層級的自然延伸（例如「anonymous function keyword」延伸到涵蓋 generator 的 `*`），沒有引入語意上完全不同的新情境。

## 出處
- https://github.com/microsoft/TypeScript/pull/51432#discussion_r1015878900
- https://github.com/microsoft/TypeScript/pull/33402#discussion_r328771651
- https://github.com/microsoft/TypeScript/pull/30743#discussion_r271980875
- https://github.com/microsoft/TypeScript/pull/19744#discussion_r149513856
