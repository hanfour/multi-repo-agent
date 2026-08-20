---
id: common-explain-static-analysis-workarounds
layer: common
frameworks: ["knip@*"]
severity_default: LOW
---
## 觸發訊號
diff 中新增或修改死碼／未使用匯出偵測工具（如 knip）的設定檔（例如 `knip.jsonc` 的 `entry`/`ignore` 清單）或原始碼中的抑制標記（移除 `@internal`、加 eslint-disable 等），目的是繞過該工具對某段程式碼的誤判——例如工具看不到透過間接路徑（re-export、walker 類別引用）被使用的符號，或工具不理解自訂 build script（如 `Herebyfile.mjs`）產生的進入點——但沒有留下對應的註解說明「為什麼要手動加這筆」以及「是工具的哪個限制造成的」。

## 判準
這類手動 workaround 完全依賴讀者對特定工具（knip 等）內部行為的假設。沒有註解時，後續維護者不知道這行設定或這個抑制標記是刻意為了繞過工具限制而保留的，容易在「清理死碼」時誤刪、誤判為真正未使用，或在工具升級/換工具後忘了重新檢查這個 workaround 是否還有必要。這不是工具本身的 bug，而是「已知限制、暫時接受」的技術債，若不記錄下來就會隨時間變成無人能解釋的黑盒設定。

## 嚴重度
CRITICAL：（不適用於此類情境）
HIGH：手動 override 涉及會被 CI 自動化流程依賴判斷正確性的入口清單（例如影響 build 是否失敗），且完全沒有任何說明，導致無法驗證 override 是否仍然必要就被合併
MEDIUM：workaround 範圍較小、只影響單一模組的誤判，但仍缺乏說明，增加日後排查與清理的成本

## 反例（不該報）
單純為了精簡輸出或效能所做的資料過濾（例如先算出 `changeTracker.getChanges()` 的結果，再 filter 掉空的 `fileTextChanges` 才回傳給呼叫端）屬於正常的邏輯最佳化，並非在繞過靜態分析工具的限制，不該套用本規則。

## 出處
- https://github.com/microsoft/TypeScript/pull/56817#discussion_r1647957390
- https://github.com/microsoft/TypeScript/pull/56817#discussion_r1442145232
- https://github.com/microsoft/TypeScript/pull/38123#discussion_r413352731
