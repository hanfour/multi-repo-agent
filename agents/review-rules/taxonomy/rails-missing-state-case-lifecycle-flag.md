---
id: rails-missing-state-case-lifecycle-flag
layer: rails
frameworks: ["rails@*"]
severity_default: HIGH
---
## 觸發訊號
- diff 新增或修改一個用來代表「處理程序進度」的旗標（例如 `@loaded`、`@started`、`@executed`、`@load_completed`、`analyzed`、`pending` 這類 ivar 或欄位），而且同一個旗標同時被用在兩個不同的判斷點上：一處判斷「是否該開始執行」，另一處判斷「是否已經執行完成」。
- diff 在既有的單一 boolean 旗標旁邊新增第二個 boolean 或另一個相關欄位（要兩者一起讀寫才能拼出完整狀態，例如 `@loaded` 搭配新加的 `@load_completed`），卻沒有改成單一的列舉／狀態機。
- diff 把一段原本「函式最外層、不論條件為何都會執行」的呼叫（例如驗證、pending 檢查、清理動作）搬進 `if`/`else` 的其中一支，或反過來把原本兩支 `if/else` 合併、加了提早 return，使得某個原本每次都會跑的步驟現在只在部分分支才會跑。
- diff 為一個非同步／可能被多執行緒同時進入的動作（loader、reloader、cache warmer 之類）加鎖或加同步機制時，鎖內外分別檢查的是同一個 boolean，而不是能區分「尚未開始 / 進行中 / 已完成」三種狀態的值。

## 判準
資深 reviewer 在意的不是這個 boolean 寫錯了，而是它結構性地裝不下真實世界的狀態數。像 `@loaded`／`@load_completed` 這種 lifecycle 旗標，實際語意通常是「還沒開始」「正在進行（可能被其他執行緒卡在鎖裡）」「已完成」三態，但程式碼只用一個 boolean 或簡單 if/else 去區分，就會把「正在進行中」誤判成「還沒開始」或「已經完成」其中之一——在並發情境下這會造成重複觸發、競態視窗，或呼叫方把「剛完成、需要重試」跟「本來就完成、不用重試」搞混。同樣地，把一段「不管條件為何都會執行」的呼叫收進 if/else 其中一支，等於是把一個獨立於分支條件之外的狀態，錯誤地合併進那個條件所代表的兩態判斷裡，結果是該呼叫在另一個分支被靜默跳過，而且往往不會有測試失敗，只會在特定執行順序或環境下才炸。

## 嚴重度
CRITICAL：遺漏的狀態出現在多執行緒／並發路徑上的 lifecycle 旗標（如加鎖前後檢查的 loaded 狀態），會直接造成 race condition、重複初始化或呼叫方誤判「已完成」。
HIGH：if/else 重構把一段原本無條件執行的檢查（例如 pending migration 檢查、必要的驗證）收進某一分支，導致該檢查在部分情境下被靜默跳過，且問題只在生產環境特定資料狀態下才會顯現。
MEDIUM：狀態遺漏只影響非關鍵路徑（記錄時機、metadata 分析時機、日誌內容），功能仍可運作，但行為與文件承諾或使用者預期不一致。

## 反例（不該報）
- 旗標本身在 domain 裡就只有合法的兩個值（例如單純的 feature-flag `enabled`/`disabled`、UI 開關），沒有「進行中」這種第三態的實際語意，不算。
- if/else 兩支合起來已經窮盡所有輸入可能，且沒有第三種情境需要被涵蓋（例如純粹的 A/B 二選一設定切換），不算。
- 新增的第二個欄位只是快取／記憶化用途，讀寫時機明確且不影響狀態判斷邏輯（例如單純的 memoized 計算結果），不算遺漏狀態。

## 出處
- https://github.com/rails/rails/pull/58225#discussion_r3643703134
- https://github.com/rails/rails/pull/58060#discussion_r3545605461
- https://github.com/rails/rails/pull/57854#discussion_r3520219889
- https://github.com/rails/rails/pull/57854#discussion_r3516473916
- https://github.com/rails/rails/pull/57854#discussion_r3514691214
- https://github.com/rails/rails/pull/57152#discussion_r3505337118
- https://github.com/rails/rails/pull/57856#discussion_r3486128940
- https://github.com/rails/rails/pull/56322#discussion_r3457020319
- https://github.com/rails/rails/pull/57381#discussion_r3395796988
- https://github.com/rails/rails/pull/57642#discussion_r3393510070
- https://github.com/rails/rails/pull/54542#discussion_r3283737903
- https://github.com/rails/rails/pull/56918#discussion_r3073108130
- https://github.com/rails/rails/pull/56341#discussion_r3057539066
- https://github.com/rails/rails/pull/56341#discussion_r3051751768
- https://github.com/rails/rails/pull/56341#discussion_r3051574037
- https://github.com/rails/rails/pull/56341#discussion_r3051519996
- https://github.com/rails/rails/pull/56341#discussion_r3051321947
- https://github.com/rails/rails/pull/56340#discussion_r2953512318
- https://github.com/rails/rails/pull/56341#discussion_r2917884413
- https://github.com/rails/rails/pull/56201#discussion_r2799730780
- https://github.com/rails/rails/pull/56695#discussion_r2741489054
- https://github.com/rails/rails/pull/56129#discussion_r2532712634
- https://github.com/rails/rails/pull/55902#discussion_r2440922913
- https://github.com/rails/rails/pull/55902#discussion_r2440911058
- https://github.com/rails/rails/pull/55612#discussion_r2394881572
- https://github.com/rails/rails/pull/55690#discussion_r2365971571
- https://github.com/rails/rails/pull/55472#discussion_r2275520371
- https://github.com/rails/rails/pull/50557#discussion_r2244261698
- https://github.com/rails/rails/pull/55249#discussion_r2176971130
- https://github.com/rails/rails/pull/55179#discussion_r2167163183
- https://github.com/rails/rails/pull/55179#discussion_r2167152581
- https://github.com/rails/rails/pull/55017#discussion_r2084742111
- https://github.com/rails/rails/pull/54853#discussion_r2024560860
- https://github.com/rails/rails/pull/54813#discussion_r2016240848
- https://github.com/rails/rails/pull/52970#discussion_r1975794078
- https://github.com/rails/rails/pull/54175#discussion_r1962147518
- https://github.com/rails/rails/pull/54509#discussion_r1953809092
- https://github.com/rails/rails/pull/54349#discussion_r1929870547
- https://github.com/rails/rails/pull/54149#discussion_r1909851472
- https://github.com/rails/rails/pull/54149#discussion_r1909725966
