---
id: react-missing-state-case-tristate-boolean
layer: react
frameworks: ["react@*"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現以下任一種變更時，去確認被動到的狀態欄位在系統裡實際可能有幾種值、每一種來源分別是什麼：

- 新增或修改一個對「status / state / phase」欄位的判斷，而該判斷用 `if/else`、單一 `===`、或布林旗標把邏輯分成兩支（例如 `if (status === PENDING || status === BLOCKED) { … } else { … }`，或是只用一個 boolean 來收斂一個原本可能有 3 個以上 variant 的 enum）。
- 把一個原本型別是聯集（union type，例如 `Thenable<boolean> | boolean`、`A | B | C`）的欄位或參數，收窄成其中一個分支的型別（例如改成單純 `boolean`），但沒有同步檢查所有寫入該欄位的呼叫點是否都符合新型別。
- 新增或修改非同步流程中的中介狀態（pending / blocked / in-flight / entangled）的 reset、清除、或轉移邏輯，但只處理了「正常完成」與「尚未開始」兩種情況，沒有處理「中途被 abort / reject / 拋出例外 / 被其他事件搶先觸發」時該狀態該落在哪裡。
- 新增一段依賴「某個旗標目前是否為 true/false」來判斷要不要重新進入某段邏輯（例如 restart / resume / re-enter 判斷），但該旗標背後其實對應多個互斥的執行階段（idle / running / interrupted / finishing）。

## 判準
狀態欄位如果背後有 3 個以上可能值（enum、多個旗標組合、或型別是聯集），reviewer 會去想：這次改動涵蓋的兩個分支之外，第三種值是怎麼產生的？通常是併發／abort／錯誤路徑製造出來的，不會出現在正常單元測試路徑裡，所以作者自己也常常想不到。一旦第三態被漏判，常見後果是：狀態卡死在一個不會再被任何後續程式碼清除的值上（永久 pending / 永久 blocked）、或是程式碼把第三態誤判成兩個已知狀態之一而執行了錯誤分支（例如把 ERRORED 誤當成 stream chunk 繼續處理）。這類問題不是「這行寫錯」，而是「這裡的分支覆蓋不完整」，只看被改的那幾行看不出來，必須回頭找這個欄位所有的寫入點與型別定義才能確認第三態是否存在、是否被涵蓋。

## 嚴重度
CRITICAL：遺漏的第三態會讓狀態機卡死且沒有任何後續程式碼會再次清除它（例如 pending flag 永遠不歸零、佇列裡的項目永遠等不到 flush、resource 因此永久洩漏），或是讓已經是錯誤/終態的資料被當成進行中資料繼續處理並外流。
HIGH：遺漏的第三態只在特定的併發／abort／race 情境下觸發，會導致單次操作行為錯誤（丟錯誤的分支、觸發不該觸發的重試或重啟），但系統仍可透過使用者重新操作或下一次事件恢復正常。
MEDIUM：遺漏的第三態只出現在極端邊緣情境（例如需要特定時序視窗才會撞到），影響範圍侷限在單一元件或單次渲染，且有明顯的 fallback 或後續邏輯會自我修正。

## 反例（不該報）
- 該欄位的型別經過確認後真的只有兩個互斥值（例如 strict union 只有兩個 variant，且沒有 Flow/TS 之外的隱藏賦值路徑），二元判斷本來就是完整的，不該報。
- 判斷式雖然只看兩個分支，但另一個分支是透過 exhaustive switch 的 `default` 或型別系統保證的 unreachable case 涵蓋（例如 Flow/TS 會在編譯期擋掉未涵蓋的 variant），不是遺漏而是刻意收斂。
- diff 只是重新命名或搬動既有的兩態判斷邏輯位置，沒有新增或修改判斷條件本身、也沒有改變該欄位可能的取值範圍，不該報。
- 第三態雖然理論上存在，但作者已經在同一個 diff 的其他地方（或既有程式碼中已存在的 guard）明確處理過，只是這次改動的那幾行本來就不需要重複處理，不該報。

## 出處
- https://github.com/react/react/pull/36944#discussion_r3674718476
- https://github.com/react/react/pull/36762#discussion_r3404630395
- https://github.com/react/react/pull/36468#discussion_r3242320562
- https://github.com/react/react/pull/36386#discussion_r3179950277
- https://github.com/react/react/pull/35487#discussion_r2680936216
- https://github.com/react/react/pull/34619#discussion_r2383434081
- https://github.com/react/react/pull/34552#discussion_r2376963568
- https://github.com/react/react/pull/34524#discussion_r2376682928
- https://github.com/react/react/pull/34524#discussion_r2376084419
- https://github.com/react/react/pull/34516#discussion_r2359504295
- https://github.com/react/react/pull/34481#discussion_r2349987269
- https://github.com/react/react/pull/34397#discussion_r2339679851
- https://github.com/react/react/pull/34380#discussion_r2322431846
- https://github.com/react/react/pull/34226#discussion_r2281451765
- https://github.com/react/react/pull/33351#discussion_r2247272687
- https://github.com/react/react/pull/33665#discussion_r2173885122
- https://github.com/react/react/pull/33354#discussion_r2107491419
- https://github.com/react/react/pull/33354#discussion_r2106834484
- https://github.com/react/react/pull/33354#discussion_r2106237074
- https://github.com/react/react/pull/33327#discussion_r2100972746
- https://github.com/react/react/pull/33135#discussion_r2077081456
- https://github.com/react/react/pull/33109#discussion_r2072281001
- https://github.com/react/react/pull/32319#discussion_r1946735009
- https://github.com/react/react/pull/32240#discussion_r1932789934
- https://github.com/react/react/pull/31987#discussion_r1904361523
- https://github.com/react/react/pull/31987#discussion_r1903925611
- https://github.com/react/react/pull/31930#discussion_r1901206087
- https://github.com/react/react/pull/31866#discussion_r1893467847
- https://github.com/react/react/pull/31725#discussion_r1881266453
- https://github.com/react/react/pull/31132#discussion_r1793454408
- https://github.com/react/react/pull/30967#discussion_r1761332463
- https://github.com/react/react/pull/30740#discussion_r1722565306
- https://github.com/react/react/pull/30731#discussion_r1722119668
- https://github.com/react/react/pull/30589#discussion_r1702400042
- https://github.com/react/react/pull/30396#discussion_r1683601528
- https://github.com/react/react/pull/29761#discussion_r1626653055
- https://github.com/react/react/pull/28330#discussion_r1623647116
- https://github.com/react/react/pull/29223#discussion_r1615332677
- https://github.com/react/react/pull/29223#discussion_r1612097104
- https://github.com/react/react/pull/28942#discussion_r1582190769
