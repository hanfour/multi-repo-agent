---
id: common-incomplete-or-noisy-test-fixtures
layer: common
frameworks: ["*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 新增或修改測試 fixture／expect／snapshot 檔案時出現以下任一情況：
- fixture 用真實 I/O（檔案系統讀寫、真實 timer、真實網路請求）去建構測試資料，而該資料本可直接用字串常數或簡化 mock 表達
- 新增的 `.expect.md`／snapshot 類檔案裡，eval/output 區塊仍顯示未實作的 placeholder（例如 "Fixture not implemented"）或明顯是空殼
- 新增的 lint／compiler rule 測試案例只覆蓋表面寫法，沒有覆蓋該規則說明文件本身承諾要驗證的關鍵邊界情況（例如具名函式表達式 vs 匿名賦值、MemberExpression 賦值等會影響判斷邏輯的寫法）
- diff 中夾帶與本次改動主題無關的大範圍重新格式化（既有測試被 prettier 重排、單純刪掉檔尾換行）之類的雜訊，混在功能改動裡一起送出

## 判準
測試 fixture 存在的目的是把「這段程式行為會被驗證」變成可信的事實；如果 fixture 本身沒有真正跑出結果、用不必要的重量級手段（真實 I/O）取代簡單輸入、或根本沒測到規則宣稱要處理的情境，CI 綠燈只是一個假象，之後行為壞掉不會被任何人發現。另外，把大範圍格式化雜訊夾在功能 diff 裡，會讓 reviewer 沒辦法用 diff 快速判斷實際改了什麼，等於強迫 reviewer 逐行比對，拖慢審查也提高漏看真正改動的機率。

## 嚴重度
CRITICAL：fixture／expect 檔案的輸出區塊仍是未實作的 placeholder（如 "Fixture not implemented"），代表這條測試完全沒有驗證任何行為，卻會讓 PR 看起來已經補了測試。
HIGH：測試改用真實 I/O（檔案系統、網路、真實計時器）去產生原本可以用簡單字串／固定值表達的輸入，導致測試變慢、跨平台或 CI 環境下容易 flaky。
MEDIUM：fixture 沒有覆蓋規則文件宣稱要處理的關鍵邊界情況；或 diff 夾帶與本次改動無關的大範圍重新格式化，讓實際改動被淹沒在雜訊裡。

## 反例（不該報）
- 真實 I/O 是被測功能本身的一部分（例如正在驗證「大字串序列化到磁碟再讀回時，debug 字串是否依門檻被截斷」這種行為本身就依賴檔案系統語意），此時用真實 I/O 是必要手段，不該報
- fixture 的輸出區塊留白，但 PR 描述已明確說明這是先建骨架、之後會有後續 PR 補上真正輸出（例如新語法尚未支援，先佔位），且審查者已知情，不該報
- 大範圍重新格式化就是該 PR 唯一且明確的目的（例如獨立提交的「統一跑 prettier」PR），而非夾帶在功能改動裡，不該報

## 出處
- https://github.com/react/react/pull/36570#discussion_r3324087819
- https://github.com/react/react/pull/35365#discussion_r2621184850
- https://github.com/react/react/pull/34100#discussion_r2252031866
- https://github.com/react/react/pull/26287#discussion_r1130793958
- https://github.com/react/react/pull/9101#discussion_r104212612
- https://github.com/react/react/pull/6946#discussion_r65452232
