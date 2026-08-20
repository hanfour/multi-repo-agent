---
id: react-owner-devtools-compat
layer: react
frameworks: ["react@0.14 - 19.x"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中出現以下任一情形：
- 讀取 `owner` / `_owner` / `_currentElement._owner` / `ownerStack`，並直接呼叫 `owner.getName()`、`owner.stack`、`owner.getPublicInstance()` 等方法，而沒有先做 `owner != null` / `owner !== null` 的存在性檢查
- 修改 fiber 或 legacy stack renderer 中被 `packages/react-devtools-shared/src/backend` 讀取的內部欄位（如 `_debugID`、`_debugSource`、`owner`、`tag`、`stateNode` 等），卻沒有在 PR 中處理「舊版 DevTools / 舊版 React 內部結構」的相容性
- 為 client component 與 server/Flight component 的 owner stack 錯誤訊息各自實作了不對稱的邏輯（例如只在其中一側檢查 `owner.stack !== ''` 或才往上追 `owner.owner`）
- 把 dev-only 的 owner 名稱解析、stack 組裝挪出 `if (__DEV__)` 區塊，變成 prod 也會執行

## 判準
`owner` 是 React 內部 dev 警告、"rendered by X" 錯誤歸因、以及 DevTools 元件樹/owner stack UI 的骨幹資料。`owner` 在合法情況下可以是 `null`（root 層元件、非 JSX 呼叫點建立的元素、Flight/server boundary 節點），因此任何不檢查就存取 `owner.xxx` 的程式碼，會恰好在「最沒有 owner、對使用者最難除錯」的那批元件上崩潰或給出錯誤資訊。另外，DevTools 擴充套件與 React core 是分開發布、版本可能不同步的，任何對這些內部欄位的 rename/移除/改形狀，如果沒有相容性處理，會讓舊版 DevTools 悄悄壞掉（使用者只看到 UI 壞了，沒有任何錯誤訊息可供追查），這也是為什麼審查時要特別把這類相容性檢查明講出來，而不是指望測試會抓到。

## 嚴重度
CRITICAL：owner 欄位的形狀/名稱變更沒有任何向後相容處理就上線，導致搭配舊版 DevTools 的使用者元件檢查功能整個壞掉（React core 與 DevTools 擴充套件版本無法強制同步升級）
HIGH：在 root 層元件或其他合法 ownerless 路徑可達的程式碼中，對 `owner` 呼叫 `.getName()` / 讀 `.stack` 前沒做 null 檢查，導致錯誤回報路徑本身拋例外
MEDIUM：owner/stack 的 dev-only 運算被移到 `__DEV__` 保護區塊之外（prod 也要付出運算成本），或 client / server component 的 owner stack 處理邏輯出現不對稱

## 反例（不該報）
- `owner` 存取緊接在上一行的 `if (owner !== null) { ... }` 保護內，屬於已守衛過的巢狀存取，不需要重複標
- 測試檔案刻意建構 ownerless 的 element，用來驗證「沒有 owner 時的 fallback 行為」是否正確
- 整段程式碼本來就在 `__DEV__` 區塊內，且外層已經處理過 `owner == null` 的 early return，不必逐行重複標記
- 只服務同一份、未發布的內部 DevTools 分支（不會被獨立版本的舊 DevTools 讀取），不需要相容性檢查

## 出處
- https://github.com/react/react/pull/32540#discussion_r1985378288
- https://github.com/react/react/pull/32426#discussion_r1968101220
- https://github.com/react/react/pull/30174#discussion_r1661399255
- https://github.com/react/react/pull/7911#discussion_r82813170
