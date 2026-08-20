---
id: react-domain-logic-single-instance-assumption
layer: react
frameworks: ["react@>=16"]
severity_default: HIGH
---

## 觸發訊號
diff 新增或修改一段處理「非同步等待後續行為」的邏輯（.then/await/setTimeout、Suspense 或 hydration 的完成回呼、事件監聽器的 attach/detach、context 傳播、cache/pool 的建立與複用），或是新增一段假設「只會有一個 root／一個 boundary／一個 provider／一個執行環境」的分支邏輯。看到這類新函式或新分支時，要去確認：如果同時存在多個 root、多個 Suspense boundary、多層相同 context 的 provider、多個 tab／並發渲染，或者呼叫發生在不同的 DOM 結構位置（例如假設內容一定在 body 而非 head）、不同的 JS 執行環境（例如假設 stack trace 格式一定是 V8 而非其他引擎），這段邏輯是否仍然成立；以及這個回呼／副作用是否可能被重複觸發、或在等待期間讀到過期的外部狀態。

## 判準
這類程式碼在作者自己驗證過的單一、簡單情境下確實能跑，但 React 應用的真實規模（多個並行的 root/boundary/provider、跨瀏覽器/跨執行環境、非同步等待期間外部狀態持續變動）遠比開發時手測的情境複雜。如果新邏輯把「呼叫當下觀察到的狀態」當成「執行到那一行時依然有效的狀態」、把「目前只看到一次呼叫」當成「保證只呼叫一次」、或把「這裡通常長這樣」當成「唯一可能的結構」，一旦遇到並發實例、重入呼叫或非典型結構就會出錯。這類問題往往不會被單元測試在孤立情境下的斷言捕捉到，只有在追問「如果同時有好幾個 X 呢？」「等待期間如果又觸發一次呢？」才會浮現，所以特別容易漏審——也因此在 review 語料裡，作者自己常常在留言裡先承認「這是個 edge case，我還沒想清楚」。

## 嚴重度
CRITICAL：回呼可能被重複觸發並產生使用者可見的副作用（重複 flush、重複執行 handler、狀態被覆寫成不一致值），或多實例並行時會互相讀寫到對方的狀態，導致資料錯亂或渲染錯誤。
HIGH：只有在特定結構位置（例如巢狀在特定容器、多層 provider、內容位於非預期的 DOM 區塊）或特定執行環境（非 V8 引擎、不同瀏覽器）下才會出錯，主流情境下行為正確。
MEDIUM：邏輯上有未涵蓋的分支，但影響僅止於效能或多做一次不必要的計算，不影響最終正確性。

## 反例（不該報）
- diff 只是重新命名變數、抽出函式、調整程式碼風格以配合周邊寫法，沒有改變任何關於「是否只有一個實例」「等待期間狀態是否會變」的假設，不該報。
- 該非同步邏輯的呼叫者本來就保證同步、單例執行（例如只在模組初始化時呼叫一次、且沒有任何並行路徑能重入），不該報。
- 程式碼已經用明確機制防範過期狀態或重複觸發（例如版本號比對、cancellation token、依 instance 存狀態的 WeakMap、noop 化已完成的 callback），即使表面上有等待或多個潛在呼叫點也不該報。
- 作者在 PR 描述或留言中已明確説明這是刻意先落地的簡化版本，且已標註 experimental／will iterate，只是還沒收斂到複雜情境，不構成需要再次提出的新發現。

## 出處
- https://github.com/react/react/pull/34564#discussion_r2372080574
- https://github.com/react/react/pull/32814#discussion_r2305356997
- https://github.com/react/react/pull/32900#discussion_r2044866926
- https://github.com/react/react/pull/32565#discussion_r1987520725
- https://github.com/react/react/pull/31776#discussion_r1885353975
- https://github.com/react/react/pull/31709#discussion_r1876522532
- https://github.com/react/react/pull/30731#discussion_r1720889527
- https://github.com/react/react/pull/29708#discussion_r1623727938
- https://github.com/react/react/pull/29632#discussion_r1621011804
- https://github.com/react/react/pull/29139#discussion_r1605339645
- https://github.com/react/react/pull/28252#discussion_r1479137073
- https://github.com/react/react/pull/27373#discussion_r1331211184
- https://github.com/react/react/pull/27307#discussion_r1310386491
- https://github.com/react/react/pull/27307#discussion_r1309671407
- https://github.com/react/react/pull/26474#discussion_r1148167709
- https://github.com/react/react/pull/26154#discussion_r1103546204
- https://github.com/react/react/pull/25703#discussion_r1045135868
- https://github.com/react/react/pull/25619#discussion_r1012399758
- https://github.com/react/react/pull/24295#discussion_r845345532
- https://github.com/react/react/pull/24276#discussion_r842247688
- https://github.com/react/react/pull/24276#discussion_r842242978
- https://github.com/react/react/pull/23244#discussion_r818296329
- https://github.com/react/react/pull/23207#discussion_r799102378
- https://github.com/react/react/pull/23207#discussion_r796052221
- https://github.com/react/react/pull/22680#discussion_r746022846
- https://github.com/react/react/pull/19855#discussion_r600796259
- https://github.com/react/react/pull/20890#discussion_r584072789
- https://github.com/react/react/pull/20646#discussion_r563904190
- https://github.com/react/react/pull/20463#discussion_r546051648
- https://github.com/react/react/pull/20463#discussion_r546036925
- https://github.com/react/react/pull/20456#discussion_r544722974
- https://github.com/react/react/pull/20299#discussion_r527049824
- https://github.com/react/react/pull/19994#discussion_r524280949
- https://github.com/react/react/pull/19590#discussion_r470149560
- https://github.com/react/react/pull/19322#discussion_r455511342
- https://github.com/react/react/pull/18676#discussion_r411462962
- https://github.com/react/react/pull/18676#discussion_r411461899
- https://github.com/react/react/pull/18292#discussion_r391933125
- https://github.com/react/react/pull/18274#discussion_r391149917
- https://github.com/react/react/pull/18262#discussion_r390120716
