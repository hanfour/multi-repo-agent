---
id: common-comment-explains-nonobvious-code
layer: common
frameworks: []
severity_default: LOW
---
## 觸發訊號
diff 新增了不直觀的邏輯區塊、workaround、bitmask/型別欄位、codemod script、build/工具設定檔（如 eslint config、closure compiler wrapper）或刻意保留的怪異程式碼（如註解掉的 flag、臨時腳本），但沒有註解解釋「為什麼」；或反過來，新增/移除的註解本身內容模糊、只重複程式碼在做什麼、或已經過時但未同步更新。

## 判準
資深 reviewer 在意的不是「有沒有註解」，而是「下一個看到這段程式碼的人能不能不用問作者就懂為什麼這樣寫」。純粹重複程式碼字面意思的註解（what）沒有價值甚至是雜訊；解釋不明顯的約束、bug workaround、命名不到位但暫時沒空改、工具鏈依賴（如 haste `@providesModule`、closure compiler 對 multiline comment 的特殊處理）這類「why」如果沒寫下來，會變成團隊共享的隱性知識，離職或忘記後沒人能安全修改或刪除這段程式碼。同樣地，過時但保留的舊註解（例如描述已不存在行為的區塊）會誤導未來的讀者，比沒有註解更糟。

## 嚴重度
CRITICAL：（此類問題本身不會造成程式錯誤，通常不會到 CRITICAL）
HIGH：刪除或修改邏輯後，遺留的舊註解描述的是已不存在的行為，會誤導後續維護者做出錯誤修改（例如仍寫著「stash 一個 reference」但程式碼已不再這樣做）
MEDIUM：新增了非顯而易見的邏輯（workaround、隱藏的工具鏈依賴、bitmask/特殊欄位、暫時保留但預期會被移除的 script）卻完全沒有註解說明原因，導致後續維護者只能靠猜或問人

## 反例（不該報）
- 程式碼本身已經透過良好命名、型別、或明顯的控制流程自我解釋，不需要額外註解
- 註解只是命名/措辭上主觀不夠精準（例如「Shared 這名字不夠好」），屬於風格討論而非缺陷
- PR 描述或 commit message 已經清楚說明了原因，且該程式碼片段的生命週期本來就短（例如作者明確聲明會在後續 commit 移除的暫存腳本）
- 純粹重構、搬移程式碼位置且語意未變，原有註解仍然準確

## 出處
- https://github.com/react/react/pull/31987#discussion_r1903916717
- https://github.com/react/react/pull/29708#discussion_r1623730912
- https://github.com/react/react/pull/27671#discussion_r1387848312
- https://github.com/react/react/pull/25105#discussion_r965008670
- https://github.com/react/react/pull/18612#discussion_r413534066
- https://github.com/react/react/pull/14144#discussion_r237711217
- https://github.com/react/react/pull/12793#discussion_r187841318
- https://github.com/react/react/pull/11794#discussion_r155786576
- https://github.com/react/react/pull/11794#discussion_r155610210
- https://github.com/react/react/pull/9448#discussion_r111838292
- https://github.com/react/react/pull/8097#discussion_r85038000
- https://github.com/react/react/pull/7840#discussion_r81657032
