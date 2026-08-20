---
id: common-incomplete-sibling-case-handling
layer: common
frameworks: ["*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 新增了一個針對「已知封閉集合裡某個特定 kind/variant」的處理分支，但集合裡其他語意平行的成員沒有比照辦理。具體可比對的形態：
- 新增 `isFooType()` / `isXxxType()` 這類針對單一 `shapeId`／type 常數的 helper，但同一個 family 裡還有其他已知 shapeId 沒有對應 helper（例如已有 `isUseStateType`、`isUseTransitionType`，卻只給新 hook 加了一個，其他仍留在原地手寫判斷）
- `switch (value.kind)` 或一系列 `if` 只處理了 `CallExpression`，沒有處理語意上完全平行的 `MethodCall`（反之亦然），而檔案裡其他地方已經證明這兩者必須成對處理
- 追蹤/量測某個事件時只記了 `xxxStart`，沒有對稱記 `xxxEnd`，或只補了「開始」沒補「結束」的收尾邏輯
- dispatch table／whitelist／whitelist-like set 裡新增一筆條目，但同檔案其他地方明顯存在的兄弟條目沒有同步新增

## 判準
針對 discriminated union 或「kind 欄位」寫邏輯時，漏掉一個兄弟分支通常不會報錯——程式照樣編譯過、測試照樣綠燈，只有輸入剛好命中被漏掉的那個 kind 時才會出錯或靜默地什麼都不做。這類遺漏很容易在 review 時被忽略，因為表面上邏輯看起來「已經處理完了」，但只有真正熟悉整個 kind 集合全貌的 reviewer 才會注意到少了一支。這也是資深 reviewer 常見的評語模式：「i think we just didn't add isFooType() helpers for all the types checked here」「reminder to handle the React.useEffect() case (MethodCall)」「where's the renderEnd?」。

## 嚴重度
CRITICAL：漏掉的兄弟分支會導致編譯器產生錯誤程式碼或執行期行為錯誤，且完全沒有錯誤訊號（例如安全轉換只處理 CallExpression、MethodCall 形式的呼叫會靜默繞過該轉換）
HIGH：漏掉的分支使一個原本設計用來抓某類 bug 的驗證/lint pass 對該 kind 產生假陰性，讓它本該攔下的錯誤溜過去
MEDIUM：遺漏只影響對稱性、debug 輸出或開發工具，不影響正式行為（例如量測指標只有 start 沒有 end）

## 反例（不該報）
- 作者已明確留 TODO／註解說明該兄弟 case 是刻意延後支援、範圍外決定，而非疏漏
- 所謂的「兄弟 case」其實在語意上並不平行——這類建議在討論串中已被作者釐清、reviewer 也接受並收回意見
- 新分支處理的已經是該呼叫點唯一可能出現的 kind（其他 kind 在該 context 下靜態上不可能出現），所以根本沒有兄弟 case 需要補
- 只是為了形式上的完整性，硬要求對一個大型 union 裡每個成員都補 helper，但實際上只有這一個 kind 會影響行為（過度設計，屬於 YAGNI，不該被要求）

## 出處
- https://github.com/react/react/pull/35141#discussion_r2528937403
- https://github.com/react/react/pull/31796#discussion_r1887692793
- https://github.com/react/react/pull/33045#discussion_r2064457066
- https://github.com/react/react/pull/34462#discussion_r2337459529
- https://github.com/react/react/pull/30894#discussion_r1750990574
- https://github.com/react/react/pull/33403#discussion_r2126746118
- https://github.com/react/react/pull/33136#discussion_r2078033795
