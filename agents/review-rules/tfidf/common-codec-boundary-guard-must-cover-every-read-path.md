---
id: common-codec-boundary-guard-must-cover-every-read-path
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號

diff 內容符合下列任一種時套用本規則：
- 新增或修改某個 codec 的 `encode`/`decode`/`encodeJson`/`decodeJson`（或等價的 wire-value 轉換函式），處理的是數值（整數/浮點/decimal）、時間、或需要按資料庫實際輸出格式解析的字串。
- 在某一條讀取路徑（例如 `query()`）加上數值安全範圍檢查（`Number.isFinite`、`^-?\d+$` 之類的 regex、safe-integer 判斷）或格式 grammar 檢查，但同一個 codec/欄位也會被另一條讀取路徑讀到（例如 `queryPrepared()`／prepared statement execute、`include()`／nested projection 的 decode、聚合 `sum`/`avg` 的兩種變體），而該路徑沒有同樣的檢查。
- 變更小數位／精度計算的四捨五入或截斷方式（例如秒的小數部分、貨幣位數），且該行為必須與資料庫本身的捨入規則一致。
- 新增或修改某個「canonical JSON」的宣告（`projectJson()`、`encodeJson()`），聲稱它產生的形狀與資料庫端 SQL 投影出的 JSON 相同，但沒有針對真實資料庫跑過的一致性測試（conformance test）驗證兩者逐 byte 相同。

## 判準

數值／時間邊界上的 codec 錯誤在一般測試裡幾乎不可見，因為測試值通常都落在 JS 安全整數範圍內、或沒有小數部分；問題只有在正式環境出現一個真的很大的計數、聚合總和、或超過微秒精度的時間戳時才會爆出來，而且爆出來的方式常常是「悄悄地把值變錯」而不是丟例外——這比拋錯誤更糟，因為沒有任何訊號能讓使用者發現資料已經壞掉。

當同一份邏輯資料存在兩條不同的讀取路徑（ad-hoc query vs. prepared statement、頂層 select vs. nested include/JSON 投影）時，只在其中一條路徑加上的 guard／cast／安全範圍檢查會製造分裂：同一筆資料透過路徑 A 會正確地丟出結構化錯誤，透過路徑 B 卻悄悄回傳一個錯誤的值（或直接回傳 stub 的結果，完全沒進到正確的分支）。這種分裂在 review 時特別容易被忽略，因為表面上看起來「已經處理過了」。

codec 的「canonical JSON」是其他機制（client hydration、diff、drift 偵測）賴以運作的契約；如果 codec 的 `encodeJson` 跟它聲稱要對齊的 SQL 端 JSON 投影實際上不一致，任何消費這個 canonical 形式的下游都會悄悄拿到錯的資料，而且沒有任何一層（型別檢查、mock driver 的單元測試）能抓到——只有對真實資料庫跑的 conformance test 才抓得到。

## 嚴重度
CRITICAL：分裂導致對資料庫寫入或讀出悄悄變錯的資料且沒有任何例外（例如：截斷小數而非四捨五入導致與資料庫實際儲存值不符；`encodeJson` 聲稱的 canonical 形式其實跟資料庫投影出的不一樣），已經或即將污染資料，或讓依賴 canonical JSON 的下游全部拿到錯誤資料。

HIGH：分裂導致使用者可觀察到的失敗模式不一致——某條路徑正確丟出結構化的 decode/range 錯誤，而另一條實質相同的路徑（prepared statement、include/nested projection）卻悄悄回傳錯誤值或錯誤的 stub 結果，而非同樣的錯誤。

MEDIUM：guard／grammar 比實際需要嚴格或寬鬆（接受了不該接受的輸入，或拒絕了合法輸入），但實際執行時的數值範圍在業務上不可能碰到受影響的邊界，或者這個分裂會被既有的型別錯誤／立即拋出的例外攔下，不會悄悄往下傳播一個錯的值。

## 反例（不該報）
- 這個數值／時間 guard 只定義在一個共用 helper 裡，每一條讀取路徑（query、queryPrepared、include-decode）都透過同一個 helper 呼叫——只因為 guard 的實作只寫在一個函式裡就報，是誤報。
- 該 codec 對應的欄位型別本身已經在範圍上被資料庫限制住（例如綁定 `smallint`/`int4` 的 codec，數學上不可能超過 32 位元）——在這種 codec 上要求「補安全整數範圍檢查」是假警報。
- 捨入/截斷行為的差異已經有對真實資料庫跑的 conformance case 把正確行為釘死（而不是憑假設寫的），且這正是本次 diff 要修的內容——這是修復本身，不是要報的問題。
- codec 的 `encodeJson` 目前確實還不是 canonical，但這件事已經被明確追蹤記錄（例如 conformance suite 裡標成 `notYetCanonical` 並附原因）——這是已知且有留痕的技術債，不用重複回報。

## 出處
- https://github.com/prisma/prisma/pull/29830#discussion_r3674815168
- https://github.com/prisma/prisma/pull/29830#discussion_r3674783646
- https://github.com/prisma/prisma/pull/29830#discussion_r3674782722
- https://github.com/prisma/prisma/pull/29830#discussion_r3674774703
- https://github.com/prisma/prisma/pull/29830#discussion_r3666543319
- https://github.com/prisma/prisma/pull/29830#discussion_r3666954260
- https://github.com/prisma/prisma/pull/29902#discussion_r3728461188
- https://github.com/prisma/prisma/pull/29902#discussion_r3728483170
- https://github.com/prisma/prisma/pull/29997#discussion_r3767171084
- https://github.com/prisma/prisma/pull/29997#discussion_r3767299299
