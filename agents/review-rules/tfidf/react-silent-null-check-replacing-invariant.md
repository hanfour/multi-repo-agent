---
id: react-silent-null-check-replacing-invariant
layer: react
frameworks: ["react@*"]
severity_default: HIGH
---
## 觸發訊號
diff 把原本會炸掉的一致性檢查（`invariant(...)`、`warning(...)`、或明確 throw）換成一個安靜的 `if (x != null) { ... }`／optional chaining／直接刪掉檢查，尤其發生在 fiber/component tree 的 bookkeeping 上：child↔parent 對應（`parentID`）、`nextChild`/`prevChild`/`existingInstance` 這類「應該已經被前一步驟註冊過」的查找、或 devtools/reconciler 內部狀態機的順序假設（例如「parent 必須在 child 之後才處理」）。也包含：新增一段跳過邏輯的 null check，但沒有註解解釋為什麼這個 null 分支是合法、可預期的。

## 判準
這些 invariant 存在是因為違反它代表真的有 state 管理 bug（child 沒有在 parent 引用它之前完成註冊、parentID 不一致、該找到的 Fiber 沒找到）。把它悄悄換成 `if` 判斷，bug 不會消失，只是訊號被吃掉了——之後會在下游變成很難追的 crash、UI 錯誤，或 devtools 節點無故消失，而且失去了原本「炸在源頭」的除錯線索。同樣地，為了效能移除 invariant 也常常是不成立的，因為正常路徑下 invariant 檢查成本可忽略，真正付出代價的只有「本來就該報錯」的錯誤路徑。

## 嚴重度
CRITICAL：直接刪除既有的 invariant/error，換成完全靜默跳過（沒有 log、沒有 fallback、沒有任何訊號），可能導致資料錯亂或難以追蹤的 crash。
HIGH：在新增的 child/parent tree bookkeeping 路徑上加了 nullable 分支，卻沒有 invariant 也沒有註解說明「為什麼這裡的 null 是預期內」。
MEDIUM：把原本的 invariant 降級成 warning（不再 throw），或是明明鄰近程式碼都有對等的一致性檢查（如 parentID 一致性），這處卻沒補上，但整體功能不受影響。

## 反例（不該報）
- null check 旁邊有清楚註解解釋為何這條路徑保證非 null（例如「We can only get here if prevChild is non-null since otherwise existingInstance will be null」），代表作者已經證明過安全性，只是省略了 invariant 本身。
- 新增的 null 分支對應到一個新的、合法的呼叫情境（例如元件尚未掛載就呼叫 blur()），且這是有意的功能擴充而非移除既有保護——但仍應確認 PR 討論裡有明確說明，而不是單純猜測「大概沒事」。
- 純粹的效能/命名/重構變動，沒有觸及任何一致性檢查或 tree bookkeeping 邏輯。

## 出處
- https://github.com/react/react/pull/30822#discussion_r1733147712
- https://github.com/react/react/pull/22699#discussion_r743095746
- https://github.com/react/react/pull/7464#discussion_r74341645
- https://github.com/react/react/pull/6771#discussion_r63282703
- https://github.com/react/react/pull/2520#discussion_r20331611
