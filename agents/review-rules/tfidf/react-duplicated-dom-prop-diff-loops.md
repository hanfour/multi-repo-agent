---
id: react-duplicated-dom-prop-diff-loops
layer: react
frameworks: ["react-dom@*", "react-server@*"]
severity_default: HIGH

---
## 觸發訊號
diff 新增或修改了 DOM host config 裡逐一走訪 props 的 `switch (propKey)` 區塊（例如 `updateProperties`、`diffProperties`、`diffHydratedProperties`、`setInitialDOMProperties`、`pushStartInstance`/`pushAttribute` 這類函式），對特定 tag（input/select/textarea/option/自訂元素）特別處理 `checked`、`value`、`defaultValue`、`defaultChecked`、`children`、`dangerouslySetInnerHTML`、`style`、`type`、`className` 等 prop key。特別是：
- 同一個檔案裡有兩個平行迴圈（`for propKey in lastProps` 處理被移除的 prop、`for propKey in nextProps` 處理新增/變更的 prop），只在其中一個加了新的 case 或改了判斷條件（例如把 `!= null` 改成 `hasOwnProperty`，或反過來）。
- 幾乎相同的 prop 處理邏輯同時存在於多個路徑（client 端 update、hydration、SSR/Flight 序列化）但只改了其中一處。
- 為某個 tag 加了 fast path / 特殊 case，但沒有同步檢查其他 tag 分支或 remove 迴圈是否也需要一致處理。

## 判準
這類逐 tag、逐 prop key 手寫 switch 的程式碼本質上是把同一份邏輯人工複製成好幾份（新增/移除、mount/update/hydrate、client/server），非常容易在其中一份漏改。歷史上這正是導致 controlled input 意外變 uncontrolled、hydration 後 DOM 狀態與 server 端不一致、或警告訊息與實際行為對不上的根因——resident reviewer 明確點出「這個檢查永遠是 `!= null`，所以不會拿到 default 值，很隱晦」「這段邏輯在 hydration 和 client render 應該完全一樣，最好抽成共用函式」等等。這種 bug 不會在型別檢查或一般測試中顯現，只有在特定 prop 從有變無、或從 controlled 變 uncontrolled 的邊界情境才會暴露。

## 嚴重度
CRITICAL：新舊邏輯的分歧會改變 controlled input 的 checked/value 語意（例如 add 迴圈與 remove 迴圈對 `checked`/`defaultChecked` 的判斷不一致），或造成 SSR 輸出與 client hydration 後的 DOM 不一致且沒有警告。
HIGH：在其中一個迴圈/函式（mount、update、hydrate 或 remove）新增了針對某個 propKey 的特殊分支，但沒有在對應的平行迴圈/函式中補上相同分支或判斷式，即使目前尚未觀察到可見的錯誤。
MEDIUM：把幾乎一樣的 prop 處理邏輯複製貼上到多個檔案/函式而不是抽成共用 helper，增加未來悄悄產生分歧的風險，但當下行為已核對一致。

## 反例（不該報）
- 針對已經在其他分支完整涵蓋的 case，純粹加一條 fast path 做效能優化（例如把常見 tag 提前 break），且有既有測試涵蓋、行為不變——這是合理重構，不用當 CRITICAL 報。
- 只在 remove 迴圈刻意省略某個 case，且該 case 本來就標註「defaultValue/defaultChecked are ignored by setProp」之類、由呼叫端另外處理的 documented 例外。
- 純粹加在 `__DEV__` 區塊內的新警告訊息，不影響 production 行為的分支。
- 已經把 add/remove 或 hydrate/update 的邏輯合併成單一共用函式（而不是新增第二份重複邏輯）的重構，這正是修正方向本身，不是問題。

## 出處
- https://github.com/react/react/pull/26596#discussion_r1163116143
- https://github.com/react/react/pull/26583#discussion_r1162130914
- https://github.com/react/react/pull/26551#discussion_r1157765519
- https://github.com/react/react/pull/25107#discussion_r959074609
- https://github.com/react/react/pull/22184#discussion_r697771710
- https://github.com/react/react/pull/21153#discussion_r605305455
- https://github.com/react/react/pull/18676#discussion_r411548313
- https://github.com/react/react/pull/18676#discussion_r411461899
- https://github.com/react/react/pull/13394#discussion_r210730734
- https://github.com/react/react/pull/9858#discussion_r120485981
- https://github.com/react/react/pull/8607#discussion_r95714535
- https://github.com/react/react/pull/8607#discussion_r95706638
- https://github.com/react/react/pull/10453#discussion_r133042219
- https://github.com/react/react/pull/10453#discussion_r133022947
