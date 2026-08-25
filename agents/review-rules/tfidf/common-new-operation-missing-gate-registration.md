---
id: common-new-operation-missing-gate-registration
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增一個掛在既有共用服務／API 介面上的新操作或新公開函式（尤其是會呼叫既有的同步／讀取外部狀態機制，例如 `synchronizeHostData()` 之類的呼叫），但沒有同步把這個新操作加進既有的「窮舉式」清單／開關／case 分派（例如某種 mode 下的排除清單、允許清單、protocol command 註冊表），也沒有附上對應的單元測試來驗證新操作接到了正確的狀態／資料。

## 判準
這類清單、開關、case 分派通常是系統其他部分假設「本身就是完整的」來做守門判斷（例如某種受限模式下判斷哪些操作可以執行）。新增操作時若沒有同步登記，等於讓這個守門機制對新操作形同虛設——新操作可能在應該被限制的情境下仍被放行，或者根本沒有被納入該有的保護路徑。這類 bug 通常只有在特定執行環境或模式下才會被觸發（例如某種輕量/受限模式、關閉某 feature 時），一般測試很難覆蓋，事後定位成本高，屬於「新增功能時遺漏維護系統不變式」的典型模式；同理，新公開行為若沒有測試把「用了正確的資料來源／狀態」這件事釘死，之後有人改動內部實作細節也不會被抓到。

## 嚴重度
CRITICAL：新操作會存取或同步外部狀態（檔案系統、網路、host 環境等），且遺漏登記會導致在應被限制的模式下仍執行，可能產生錯誤結果、效能劣化或當機。
HIGH：新操作雖是純讀取／計算，但仍應納入既有清單以維持窮舉不變式；或新增的公開 API 完全沒有對應單元測試驗證其正確性（例如驗證用了正確的 program/file 內容）。
MEDIUM：遺漏的登記或測試只影響邊緣情境（如僅供診斷/debug 用途），或屬於文件/註解層級的缺失（例如刻意保留的魔術數字沒有加註解說明其背後的限制，導致未來有人誤把它「簡化」掉）。

## 反例（不該報）
- 新操作本身不依賴、也不會觸發任何需要清單守門的共用機制（例如純粹的內部 helper、不做任何 IO 或狀態同步），不需要登記。
- diff 已經同步更新了所有相關清單與測試，只是尚未被完整看到（需先確認 diff 全貌再判斷，不要只看局部 hunk 就下結論）。
- 純格式調整（空白、逗號位置、換行等不影響語意的變動）——這屬於 lint/format 問題，不屬於本規則涵蓋範圍。
- 針對常數本身數值的討論（例如是否要用 `1 << 29`）如果純粹是設計選擇的溝通、且並未牽涉任何清單同步或測試缺失，不套用本規則。

## 出處
- https://github.com/microsoft/TypeScript/pull/59963#discussion_r1759566807
- https://github.com/microsoft/TypeScript/pull/57262#discussion_r1585389099
- https://github.com/microsoft/TypeScript/pull/44031#discussion_r629762984
- https://github.com/microsoft/TypeScript/pull/33537#discussion_r328817115
- https://github.com/microsoft/TypeScript/pull/27087#discussion_r217617980
- https://github.com/microsoft/TypeScript/pull/14774#discussion_r111496143
