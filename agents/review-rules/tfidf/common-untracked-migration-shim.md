---
id: common-untracked-migration-shim
layer: common
frameworks: []
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或修改的程式碼帶有「這是暫時的」性質的標記，但沒有可追蹤的移除機制。具體型態包括：
- 註解寫 "TODO: temporary while we ..."、"DO NOT USE: Temporarily exposed to migrate off of X"、"Copied from X. Don't do this!"、"We should get rid of this hack at some point" 之類，但沒有連結 issue/PR 或明確的移除條件。
- 為了遷移舊 API 到新 API，寫出「雙重包裝」(double wrapping) 的橋接函式，且註解承認這是暫時的但未附完成遷移的追蹤方式。
- 把另一個內部模組的常數/邏輯手動複製貼上（而非 import），並註明「之後會替換掉」。
- 為了相容性把內部 API 暫時對外 export（如標成 `unstable_` / `DO NOT USE`），供外部遷移用。

## 判準
資深 reviewer 對這類 code 的疑慮不是「現在會不會壞」，而是「這段程式碼有極高機率永久留下來」。沒有 tracking issue、owner、或自動化移除條件（例如 feature flag 到期、call site 歸零就報錯）的暫時程式碼，一旦合併就會被遺忘——尤其當它是複製貼上的常數（會跟來源模組失去同步）或是雙重包裝的橋接邏輯（增加認知負擔，且掩蓋了真正該解決的架構問題）。這類程式碼也常常是後續 bug 的溫床，因為維護者未必知道它「本不該存在」。

## 嚴重度
CRITICAL：複製貼上的常數/邏輯屬於安全或優先權敏感（例如硬編碼一個原本應該從單一來源讀取的數值範圍），一旦來源模組變動就會靜默產生行為分歧。
HIGH：為遷移對外 export 的暫時 API（如 `DO NOT USE` / 雙重包裝的橋接函式），已被其他呼叫方依賴，但沒有任何機制標記何時該移除或呼叫方是否已清空。
MEDIUM：註解坦承是暫時的 hack 或應在某個 rollout 後移除，但沒有連結 tracking issue，也沒有移除條件；程式碼本身風險有限，主要是技術債累積。

## 反例（不該報）
- 明確標註為長期支援的相容層（例如公開 API 的向後相容包裝，設計上就是要長期存在），不是遷移過渡產物。
- 暫時程式碼已經連結到具體的 tracking issue、里程碑或自動化移除條件（例如「當某個 flag 全量後這段程式碼會被下個 PR 移除，見 #1234」）。
- 純測試輔助程式碼、與生產行為無關，且已在測試檔案的既有慣例範圍內（例如既有的 `unstable_flushAll` 測試工具擴充，非新增的遷移橋接）。
- 只是把既有邏輯搬移或重新命名（如 `handleError` 拆成 `logError` 以便未來擴充呼叫方式），本身沒有「暫時、之後要刪」的語意。

## 出處
- https://github.com/react/react/pull/31755#discussion_r1884107958
- https://github.com/react/react/pull/26719#discussion_r1175897095
- https://github.com/react/react/pull/20958#discussion_r590764984
- https://github.com/react/react/pull/19342#discussion_r454489266
- https://github.com/react/react/pull/19121#discussion_r445055453
- https://github.com/react/react/pull/16027#discussion_r299254268
