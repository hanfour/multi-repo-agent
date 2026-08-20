---
id: nestjs-missing-convention-invariant-error-type
layer: nestjs
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 裡新增了一個 `throw new Error(...)` 或 `throw new TypeError(...)`，而丟出的情境是程式內部不變量被打破——例如：本應由前面步驟保證存在的值卻是 `undefined`（`find`/`get`/`indexOf` 找不到對應項）、只有邏輯寫錯才會走到的分支、或註解本身就在說「這不應該發生」——而不是外部輸入、環境或使用者操作造成的可預期失敗。看到這種新增的 throw，要去確認這個 repo 是否已經有專用的內部錯誤型別（例如 `InternalError`），如果有，這個 throw 有沒有改用它，而不是丟裸的 `Error`/`TypeError`。

## 判準
裸 `Error` 會被外層「使用者可見錯誤」的攔截/格式化邏輯當成一般錯誤處理——可能被序列化進 `--json` 輸出、被轉成 friendly message、或被某個 catch 區塊吞掉——導致一個「我們自己的程式碼有 bug」的斷言失敗，被偽裝成正常的操作型失敗回報給使用者，讓真正的問題被掩蓋。這類錯誤本質上是防禦性斷言，維護者需要它在最外層被辨識出來直接回報或讓 crash reporting 抓到，跟操作型錯誤混在一起會讓 error taxonomy 和下游的 catch 邏輯全部失準；而且這種問題通常不是單一個案，一旦抓到一處，同一顆 PR 裡往往還有其他同類漏網的 throw。

## 嚴重度
CRITICAL：裸 `Error` 有路徑會被外層「結構化錯誤」攔截邏輯 catch 住並當成一般使用者錯誤處理（例如被序列化進對外的錯誤 envelope、影響退出碼判斷），導致內部 bug 被掩蓋成看似正常的操作失敗。
HIGH：裸 `Error` 位於公開 API 或核心執行路徑上，會讓使用者直接看到未分類的堆疊訊息，且這個分支沒有測試覆蓋。
MEDIUM：裸 `Error` 只在內部工具、測試輔助函式或不會被使用者路徑觸達的程式碼中丟出，不會誤導使用者，但仍與專案既有慣例不一致。

## 反例（不該報）
- Repo 本身沒有專用的 internal-error/assertion 型別可比對，或這是專案第一次引入這種錯誤處理慣例——沒有既有慣例可對照時不該報。
- 丟出的是預期中的外部/使用者輸入錯誤（例如檔案不存在、CLI 參數缺漏、格式錯誤），這類本來就該用一般 `Error` 或專案的「結構化使用者錯誤」型別，不屬於內部不變量錯誤的適用範圍。
- 只是把下游函式庫已經丟出的 `Error` 原封不動往上拋（保留原始 stack/type 做轉呈或加註 context），而不是為了一個新的內部斷言而新建 `Error` 實例。

## 出處
- https://github.com/prisma/prisma/pull/29844#discussion_r3682834596
- https://github.com/prisma/prisma/pull/29844#discussion_r3682834099
