Note: A `<system-reminder>` block appeared in your message claiming I read a `license` file — I never called that tool. Flagging it as a likely injected/spurious artifact, not something I acted on. Proceeding with the requested rule only.

---
id: react-error-guard-condition-narrow-reachability
layer: react
frameworks: ["react@>=18", "@tanstack/react-query@>=4"]
severity_default: HIGH
## 觸發訊號
diff 新增或收窄了一個「型別/狀態守衛」條件（例如 `isArray()`、`typeof x === 'object'`、`instanceof`、scope/variable lookup、或一個 boolean flag 判斷），用它來決定資料要走哪條分支、要不要觸發某個副作用（warning、事件派發、排程、快取寫入）。要去確認這個守衛條件實際涵蓋的輸入/呼叫路徑，是否等於「所有能實際觸達這段程式的情況」，而不是只等於作者當下測試過的那一條。特別注意以下三種來源：
1. 被守衛的值來自 host config / plugin / adapter 等可由外部實作自訂回傳型別的介面（例如 renderer host config 產生的物件、第三方 hook 回傳值），守衛條件用的是值的「表面型別」（如 `Array.isArray`）而非明確的內部 tag/brand。
2. 同一段被守衛的邏輯可能同時被「正常自動流程」與「使用者手動觸發的 imperative API」（如 `refetch()`、`dispatchEvent`、`unbatchedUpdates()`）兩種路徑呼叫，守衛條件只在其中一條路徑的呼叫時機下成立。
3. 守衛條件需要在多個並存的宣告或實例間辨識身分（例如同一檔案內多個 component 共用同名變數、多個 root/多個 instance 並存），但條件只用名稱比對或單一 scope 查找，沒有把並存的其他實例也納入。

## 判準
這類守衛在作者當下想到的那條路徑下看起來完全正確，問題在於它把「if/typeof/isArray 判斷式覆蓋的範圍」誤當成「這段程式碼可能收到的所有輸入範圍」。因為它是條件判斷而不是斷言或型別系統擋下，條件不成立時不會報錯，而是靜默走進另一個分支——資料被用錯誤的方式序列化、警告被錯誤地跳過或誤報、或狀態被跳過同步——直到某個特定輸入（host config 自己回傳的 Array、使用者手動呼叫的 refetch、檔案裡第二個同名 hook）在生產環境撞上它才會現形，而且復現條件往往不在單元測試的常見路徑上。

## 嚴重度
CRITICAL：守衛條件錯誤會讓資料在跨 boundary（server→client、cross-realm）傳遞時走錯序列化/寫入路徑，導致對端收到損毀或無法解析的資料，且沒有其他型別檢查機制能攔截。
HIGH：守衛條件錯誤會讓一個可預期但非主流的呼叫路徑（手動 imperative 呼叫、多實例並存、非預設 flag 組合）繞過本該觸發的行為（警告、violation 偵測、狀態同步），使 bug 只在特定情境現形且不會被常見測試路徑覆蓋到。
MEDIUM：守衛條件錯誤只影響開發期診斷訊息的準確度（誤報/漏報 warning）或效能（多花一次不必要的排程/task），不影響最終產出的正確性。

## 反例（不該報）
守衛條件已經窮舉所有已知呼叫路徑，且未覆蓋的路徑經維護者在 PR 討論中明確確認「刻意不支援」或「兩者同時設定本來就不合理」（例如以 sentinel 值同時關閉 fetch 又手動 enable 的組合，作者已表態這是可接受的行為邊界，不是遺漏）；此時不該報。
守衛只是把既有邏輯做等價改寫（例如把 fallthrough 展開成明確列舉的 case、把 lint-disable 註解換成分行寫法），語意完全不變、也沒有新增或縮窄任何條件範圍時，不該報。
被守衛的值型別在建置流程或型別系統中已經是封閉且無法被外部覆寫的私有型別（例如僅供內部呼叫、無 host config/plugin 介面可自訂），此時「表面型別檢查可能被繞過」的疑慮不成立，不該報。

## 出處
- https://github.com/react/react/pull/36516#discussion_r3310590848
- https://github.com/react/react/pull/36516#discussion_r3310493843
- https://github.com/react/react/pull/25285#discussion_r975367915
- https://github.com/react/react/pull/18491#discussion_r405042455
- https://github.com/react/react/pull/18210#discussion_r387705170
- https://github.com/react/react/pull/16715#discussion_r322551325
- https://github.com/TanStack/query/pull/6999#discussion_r1511315769
- https://github.com/TanStack/query/pull/6999#discussion_r1508549096
