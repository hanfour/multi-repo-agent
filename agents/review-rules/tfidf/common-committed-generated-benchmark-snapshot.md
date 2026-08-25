---
id: common-committed-generated-benchmark-snapshot
layer: common
frameworks: ["*"]
severity_default: LOW
---
## 觸發訊號
diff 中包含一個由建置/CI 腳本自動產生的快照或量測結果檔（例如 `results.json`／bundle size 報告，欄位長得像 `filename`、`bundleType`、`packageName`、`size`、`gzip`），而且：
- PR 的主要目的是別的邏輯改動，這個檔案只是連帶被 `yarn build` 之類指令重新產生後一起 commit 進來；或
- 這個檔案本身完全沒有搭配任何原始碼改動（純數字漂移）；或
- 有人手動編輯裡面的數字，而不是透過建置流程重新產生。

## 判準
這類檔案不是人手寫的，是建置腳本的副產品，內容只反映「跑一次 build 得到什麼」，不反映開發者的意圖或正確性。把它的每次數字漂移都攤在 PR diff 裡，會製造 reviewer 無法判讀、也不需要判讀的雜訊（一堆 +/- 幾百 bytes 的無意義行），稀釋掉真正該被看見的邏輯改動；久而久之 reviewer 會養成無視這類 diff 的習慣，一旦裡面真的混入手動竄改或該次建置環境異常（例如 stale error-codes JSON 造成的不等價輸出），也會被略過而未被發現。正確做法通常是把它排除在版控/PR diff 之外（gitignore、CI 產物、或至少獨立成不需人工審的自動化 commit），而不是每次都要 reviewer 逐行確認「這個數字漲跌合理嗎」。

## 嚴重度
CRITICAL：（此規則通常不會到 CRITICAL）
HIGH：快照檔被手動編輯（而非重新跑建置產生），導致回報的數字與實際建置輸出不一致，可能誤導之後依賴這份數字做 size-regression 判斷的自動化或人工決策。
MEDIUM：快照/量測結果檔案在與其目的無關的 PR 中被一起 commit，混雜進本應聚焦於邏輯改動的 diff，且沒有任何說明這些數字漂移是預期的還是建置環境差異造成的。

## 反例（不該報）
- PR 的目的本身就是縮減 bundle size 或修正建置流程，這個檔案裡的數字變化正是這次改動要被審查的核心內容（例如「移除某個 external import 後 size 降了多少」）——此時數字漂移是訊號，不是雜訊，不該報。
- 該檔案是專案明確保留、且有文件說明「這是唯一的 ground truth，每次 PR 都必須手動更新」的情況（此組意見中出現過相反聲音，例如維護者說「其實可以整個刪掉」，代表這類檔案的存廢本身有爭議，若專案已明確決議保留並要求同步更新，就不該對「它出現在 diff 裡」本身報問題）。

## 出處
- https://github.com/react/react/pull/14085#discussion_r230846726
- https://github.com/react/react/pull/13534#discussion_r214537975
- https://github.com/react/react/pull/12063#discussion_r194494611
- https://github.com/react/react/pull/12063#discussion_r194239912
- https://github.com/react/react/pull/11865#discussion_r159548081
- https://github.com/react/react/pull/11260#discussion_r145576258
- https://github.com/react/react/pull/11260#discussion_r145567662
