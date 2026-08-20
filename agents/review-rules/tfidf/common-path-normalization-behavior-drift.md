---
id: common-path-normalization-behavior-drift
layer: common
frameworks: []
severity_default: MEDIUM
---
## 觸發訊號
diff 修改了路徑正規化 / 檔案解析相關的核心函式（如 `normalizePath`、`getNormalizedAbsolutePath`、`combinePaths`、module/config 解析邏輯、watcher 的 path key 產生），且伴隨大量測試 baseline（`.js`/`.txt` snapshot、tsserver log baseline）跟著變動，尤其是 diff 只呈現最終文字差異、看不出來語意變化的那種。也包含把 `undefined`/`null` 路徑片段丟進 `combinePaths` 之類、依賴「函式對非字串值很寬鬆」這種隱性行為的重構。

## 判準
路徑處理程式碼常年積累了大量隱性契約（例如「不存在的 outDir 應該被當作真的沒設定，而不是退回 currentDirectory」），這些契約通常沒有寫在型別或註解裡，只活在測試 baseline 的具體輸出中。當重構把手寫邏輯換成新的正規化路徑（efficiency 導向的 fast-path、快取等）時，很容易在不知不覺間「修正」或「引入」一個行為差異——過去的做法可能因為某個副作用而「意外正確」，新做法在乾淨地重寫後反而打破了它。resident reviewer 的做法是把每一筆 baseline diff 都當一等公民去讀，追問「這個字元差異背後真正代表的語意是什麼」，而不是看到測試還是綠燈就放行；因為 snapshot 測試只驗證「沒變」，不驗證「這樣是對的」。

## 嚴重度
CRITICAL：baseline diff 顯示的行為變化會影響到 emit 輸出路徑（outDir/rootDir 解析錯誤導致檔案覆寫或漏編譯）或跨平台路徑判斷（UNC path、大小寫、volume separator）沒有對應測試覆蓋。
HIGH：正規化/解析邏輯的行為改變沒有在 PR 描述或 commit message 中明確說明「這是預期的修正」，而是被開發者自己都需要重新解釋（"let me check if this is actually correct"）。
MEDIUM：baseline 測試因為新邏輯而改變，但變化看起來是良性的（如日誌訊息格式、測試不再命中原本要測的 code path，需要改成 wildcard 才能繼續覆蓋原意圖）。

## 反例（不該報）
- baseline 只是格式化/空白/時間戳這類與路徑語意無關的雜訊變化。
- reviewer 已在同一段討論中確認並解釋清楚行為差異的來源與正確性（如 outDir/rootDir 案例已有明確 before/after 語意說明），且該解釋已被採納。
- 純效能優化但輸出經測試證明 byte-identical（如新增 fast-path 前先做等價性判斷、有專門測試涵蓋所有輸入分支）。

## 出處
- https://github.com/microsoft/TypeScript/pull/63031#discussion_r2733343887
- https://github.com/microsoft/TypeScript/pull/60812#discussion_r1908059014
- https://github.com/microsoft/TypeScript/pull/60812#discussion_r1893227070
- https://github.com/microsoft/TypeScript/pull/60755#discussion_r1890809189
- https://github.com/microsoft/TypeScript/pull/60755#discussion_r1889486923
- https://github.com/microsoft/TypeScript/pull/49990#discussion_r927903960
- https://github.com/microsoft/TypeScript/pull/22420#discussion_r1930520818
- https://github.com/microsoft/TypeScript/pull/25838#discussion_r204897971
