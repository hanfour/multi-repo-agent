---
id: common-domain-logic-uncovered-sibling-case
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現以下任一種變更時，要去確認結構上對稱、理論上也該套用同一邏輯的其他情境是否被同步處理：
- 把一段只處理單一 case 的邏輯泛化成迴圈、多分支、或抽成共用 helper 給多個呼叫點使用（例如把一次性判斷改成 for 迴圈逐一處理、把一個 case 的檢查抽成函式後給另一個相似 case 呼叫）。
- 新增一個針對特定輸入型態、方向、或列舉值的特殊判斷／early return（例如 `if (isX) { special-case }`），但同一函式或同一資料流裡還存在其他型態相似的輸入（例如另一個 enum 值、反方向的操作、另一個呼叫路徑、集合的第一筆或最後一筆、空集合、預設/fallback 分支）。
- 修改索引、位置計算、迭代順序，或把「先算全部再切片」改成「邊迭代邊累加」等控制流重構。
- 對外部或共享狀態（如某個物件、tsconfig 的 include/exclude/files 三種來源、多個列舉的 matching mode）新增處理，但只涵蓋了其中一部分來源/模式。

## 判準
資深 reviewer 的直覺是：程式碼裡「長得像」的東西通常必須「被一致地處理」，否則就是留了一個之後才會被使用者踩到的邊界案例。這類遺漏最危險的地方不是新加的那個 case 本身（那通常有對應測試保護），而是它旁邊、結構相似卻沒被觸及的 case——因為沒有對應測試，CI 不會抓到，錯誤會一路留到 production 或下一次重構才爆出來，且往往是靜默的錯誤結果而不是直接崩潰，難以事後定位。

## 嚴重度
CRITICAL：漏掉的對稱情境會產生靜默的錯誤結果（錯誤的型別判斷、錯誤的資料、錯誤的輸出），且該情境屬於常見輸入模式，不是罕見組合。
HIGH：漏掉的對稱情境會導致明顯錯誤或例外，但只在特定輸入排列下觸發（需要 fuzzing 或不常見的呼叫順序才會發現）。
MEDIUM：漏掉的對稱情境只影響次要體感（如提示訊息、補全建議不一致），不影響核心正確性。

## 反例（不該報）
- 作者已經明確評估過該對稱情境，並在 PR 描述、程式碼註解或討論串中說明為何刻意不處理（例如「這是很罕見的邊界案例，先跳過」），且此取捨已被 reviewer 確認接受——這是已知的、經過討論的權衡，不是遺漏。
- 該對稱情境在型別系統或語言規格層級上本來就不可能發生（例如 exhaustive switch 搭配 never 型別保證涵蓋所有分支）。
- 新增的分支只是效能優化的 fast path，邏輯上其他路徑本來就會產生相同結果，只是比較慢，並非正確性差異。

## 出處
- https://github.com/microsoft/TypeScript/pull/63070#discussion_r2748228419
- https://github.com/microsoft/TypeScript/pull/60378#discussion_r1920713163
- https://github.com/microsoft/TypeScript/pull/57679#discussion_r1540094336
- https://github.com/microsoft/TypeScript/pull/55015#discussion_r1402377010
- https://github.com/microsoft/TypeScript/pull/47829#discussion_r874113851
- https://github.com/microsoft/TypeScript/pull/53542#discussion_r1162180845
- https://github.com/microsoft/TypeScript/pull/55991#discussion_r1349143700
- https://github.com/microsoft/TypeScript/pull/55991#discussion_r1347786462
- https://github.com/microsoft/TypeScript/pull/54623#discussion_r1245549244
- https://github.com/microsoft/TypeScript/pull/39016#discussion_r439593500
- https://github.com/microsoft/TypeScript/pull/58608#discussion_r1685164427
- https://github.com/microsoft/TypeScript/pull/54849#discussion_r1696242264
- https://github.com/microsoft/TypeScript/pull/54546#discussion_r1218703231
- https://github.com/microsoft/TypeScript/pull/52291#discussion_r1074032943
- https://github.com/microsoft/TypeScript/pull/59332#discussion_r1691879016
