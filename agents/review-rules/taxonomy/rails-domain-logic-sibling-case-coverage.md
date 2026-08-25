---
id: rails-domain-logic-sibling-case-coverage
layer: rails
frameworks: ["rails@>=6.0"]
severity_default: HIGH
---
## 觸發訊號
diff 修正或新增行為時，改動只落在「一個具體實例」上，而這個實例明顯是某個共用抽象、共用機制或結構相同的清單/家族裡的其中一員，且家族其他成員在這次 diff 裡完全沒被觸碰。具體要看：

- 被改的方法是某個 module/concern/父類別的方法在某個「子類別」裡的 override 或延伸（例如 `ActiveRecord::Type` 底下某個 adapter-specific type 覆寫了共用的 `TimeZoneConverter`），而 diff 裡沒有出現任何其他 include 同一 module 的手足類別
- 被改的是一份「對照表」裡的其中一筆（例如 timezone identifier 映射、locale 映射、error code 映射），commit message 或 PR 描述只解釋了這一筆為什麼要改，沒有交代其他結構相同的項目是否有同樣問題
- 被改的是文件或 API 說明裡針對某個方法「一種輸入/一種情境」新增的行為描述（例如「當 count = 1」），但該方法明顯還有其他數量級/其他分支（例如 count = 0、count > 1）會走到不同結果，而 diff 沒有一併補齊

## 判準
Bug 或行為缺口幾乎不會只長在一個具體實例上——它源自共用的根因（同一段共用邏輯、同一種資料結構、同一種輸入分類方式）。只 patch 遇到問題的那一個實例，等於把根因留在原地，其餘手足會在未來被使用者以另一條路徑重新踩到同一個雷；而且因為第一次已經「修過」，之後除錯的人會誤以為這類問題已經處理掉，反而更難聯想到還有兄弟案例沒修。這類遺漏在 review 裡特別容易被放過，因為改動本身是正確的、測試也綠燈——盲區不在「這行寫得對不對」，而在「範圍夠不夠」。

## 嚴重度
CRITICAL：遺漏的手足實例會造成資料正確性錯誤（例如時區換算錯誤導致寫入資料庫的時間值不對），且可以在 diff 裡直接指認出哪個手足類別/哪一筆對照表項目共用同一段邏輯卻沒被觸碰。
HIGH：遺漏會造成使用者可觀察到的行為不一致（例如同一個共用 concern 底下，一個 adapter 修好了、另一個 adapter 卻還是舊行為），但不到資料損毀等級。
MEDIUM：遺漏侷限在文件、錯誤訊息或極少數情境（例如 edge case 只在特定數量的資料下出現），對正常路徑無影響。

## 反例（不該報）
- 該實例的行為本身就被設計成與手足不同（例如兩個 adapter 名稱相似，但底層資料庫語意本來就不同，這次改動是刻意的差異化，不是遺漏）
- 其他手足實例已經在同一個 PR 的其他 commit 或相鄰檔案裡一併修正，只是不在你正在看的這個 diff hunk 裡
- 所謂「共用」只是命名或表面相似（例如兩個類別都叫 `XxxHelper`），實際上彼此邏輯完全獨立，沒有共用的根因或抽象可言

## 出處
- https://github.com/rails/rails/pull/52699#discussion_r1731972740
- https://github.com/rails/rails/pull/52699#discussion_r1733574464
- https://github.com/rails/rails/pull/56127#discussion_r2531294129
- https://github.com/rails/rails/pull/50578#discussion_r1443080574
