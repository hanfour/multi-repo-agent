---
id: common-missing-convention-untested-logic-branch
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現以下任一種變更，且同一個 diff 裡沒有新增或修改任何測試檔（tests/、__tests__/、*.test.*、*.spec.*，或該專案用來鎖定行為的 baseline/fixture/snapshot 檔）：
- 新增、刪除或改寫了一個既有的條件分支（if/else/switch/三元運算式），包含移除某個 `else if`、讓原本會報錯或特殊處理的路徑改為直接放行
- 修改了布林運算子的優先權、短路邏輯，或調整了既有括號/運算順序而改變了判斷結果
- 新增了一個先前不存在的 guard clause／early return／邊界值判斷（例如針對 null、undefined、空集合、無法解析、不支援的輸入等特殊狀態新增分支）
- 改寫了一段被多處呼叫、且行為會外溢到呼叫端的共用函式邏輯（例如把巢狀迴圈順序互換、把遍歷對象從 A 換成 B）

## 判準
條件邏輯的改動最容易在修 bug 或重構時「順手」波及旁邊沒被驗證過的路徑——寫代碼的人通常只驗證了自己要修的那條路徑，卻沒意識到相鄰分支的行為也一起變了。資深 reviewer 會反射性地問「這條新分支被什麼測試釘住」，因為沒有測試保護的分支變更在下一次重構時會被靜默破壞，而且往往正是這種「看起來影響範圍很小」的判斷邏輯改動才是真正引入 regression 的地方——不是因為代碼寫錯了，而是因為沒有東西能證明它是對的、也沒有東西能在未來守住這個行為。

## 嚴重度
CRITICAL：修改的邏輯位於核心正確性路徑（型別檢查、權限判斷、金額或計數計算等），且改動會讓原本該報錯/失敗的輸入變成靜默通過，或反過來讓本該成功的輸入被拒絕，而沒有任何測試鎖住這個行為
HIGH：新增或修改了一個會影響多數使用者可觀察行為的條件分支（公開 API、CLI 參數解析、設定檔解析、語言服務/編輯器互動），沒有新增測試覆蓋新行為
MEDIUM：修改的是內部工具函式、格式化邏輯或診斷訊息文字的邊界情況，影響範圍有限但仍缺對應測試

## 反例（不該報）
- 純粹的重新命名、格式化（加括號但不改變運算優先權、調整縮排、拆行）且不改變任何輸出結果，不該報
- 把重複邏輯抽成共用函式、行為完全不變的純重構（no functional change），不該報
- 同一個 PR 裡已經新增或更新了 tests/baselines、fixture 或 snapshot 來鎖定這個新分支/新行為的結果，即使沒有寫成獨立的 `*.test.*` 檔也不該報——已經有東西能在未來守住行為即可
- 修改發生在測試程式碼本身或測試輔助工具（fixtures、mocks、test harness）內，不是被測的產品邏輯

## 出處
- https://github.com/microsoft/TypeScript/pull/63581#discussion_r3468850566
- https://github.com/microsoft/TypeScript/pull/63072#discussion_r2749230511
- https://github.com/microsoft/TypeScript/pull/63070#discussion_r2748043741
- https://github.com/microsoft/TypeScript/pull/63070#discussion_r2748041697
- https://github.com/microsoft/TypeScript/pull/62418#discussion_r2414479499
- https://github.com/microsoft/TypeScript/pull/62496#discussion_r2396088566
- https://github.com/microsoft/TypeScript/pull/62477#discussion_r2395475463
- https://github.com/microsoft/TypeScript/pull/62435#discussion_r2376564729
- https://github.com/microsoft/TypeScript/pull/62162#discussion_r2246525866
- https://github.com/microsoft/TypeScript/pull/62104#discussion_r2221711296
- https://github.com/microsoft/TypeScript/pull/62103#discussion_r2220753548
- https://github.com/microsoft/TypeScript/pull/61909#discussion_r2160279436
- https://github.com/microsoft/TypeScript/pull/61901#discussion_r2155613167
- https://github.com/microsoft/TypeScript/pull/61901#discussion_r2155604555
- https://github.com/microsoft/TypeScript/pull/61589#discussion_r2049027382
- https://github.com/microsoft/TypeScript/pull/61492#discussion_r2042583330
- https://github.com/microsoft/TypeScript/pull/61263#discussion_r1974209339
- https://github.com/microsoft/TypeScript/pull/61233#discussion_r1968453802
- https://github.com/microsoft/TypeScript/pull/60898#discussion_r1920983844
- https://github.com/microsoft/TypeScript/pull/60068#discussion_r1901386705
- https://github.com/microsoft/TypeScript/pull/60890#discussion_r1900201031
- https://github.com/microsoft/TypeScript/pull/60710#discussion_r1874561188
- https://github.com/microsoft/TypeScript/pull/60662#discussion_r1868496884
- https://github.com/microsoft/TypeScript/pull/60393#discussion_r1826596654
- https://github.com/microsoft/TypeScript/pull/60005#discussion_r1825145252
- https://github.com/microsoft/TypeScript/pull/56941#discussion_r1823185567
- https://github.com/microsoft/TypeScript/pull/60061#discussion_r1778799858
- https://github.com/microsoft/TypeScript/pull/59933#discussion_r1777469500
- https://github.com/microsoft/TypeScript/pull/60005#discussion_r1775148517
- https://github.com/microsoft/TypeScript/pull/60005#discussion_r1774071915
- https://github.com/microsoft/TypeScript/pull/59866#discussion_r1745246981
- https://github.com/microsoft/TypeScript/pull/59844#discussion_r1744024291
- https://github.com/microsoft/TypeScript/pull/59817#discussion_r1740049803
- https://github.com/microsoft/TypeScript/pull/59609#discussion_r1717380148
- https://github.com/microsoft/TypeScript/pull/59428#discussion_r1695812316
- https://github.com/microsoft/TypeScript/pull/59428#discussion_r1692671841
- https://github.com/microsoft/TypeScript/pull/55887#discussion_r1692030292
- https://github.com/microsoft/TypeScript/pull/58608#discussion_r1685165333
- https://github.com/microsoft/TypeScript/pull/58608#discussion_r1685164427
- https://github.com/microsoft/TypeScript/pull/59352#discussion_r1684916729
