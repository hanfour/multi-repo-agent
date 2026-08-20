---
id: vue-redundant-legacy-type-property
layer: vue
frameworks: ["vue@^3.0.0"]
severity_default: MEDIUM
---
## 觸發訊號
diff 在一個型別宣告（interface/type）中新增一個成員屬性，而該屬性已經可以透過此型別所擴充（`&` 交集）或繼承的另一個型別取得——例如對 `LegacyPublicProperties` 新增 `$root: LegacyPublicInstance`，但 `LegacyPublicInstance = ComponentPublicInstance & LegacyPublicProperties`，其中 `ComponentPublicInstance` 早已提供 `$root`。PR 描述、commit message 或程式碼註解沒有附上可重現的最小範例（reproduction / repro repo）說明目前的型別鏈為何不夠用，也沒有解釋為什麼要在子型別重複宣告而非依賴繼承。

## 判準
型別新增看起來無害，但若屬性已透過交集型別／繼承鏈提供，重複宣告有兩個實際風險：一是可能與鏈上其他既有型別不一致（例如同類屬性在別處被宣告成不同型別，如 `$children: LegacyPublicProperties[]` 卻不是 `LegacyPublicInstance[]`），造成型別系統給出互相矛盾的提示；二是掩蓋了真正的 root cause——使用者遇到的型別錯誤很可能是別處型別推導失敗（例如某個泛型 `DefineComponent` 沒有正確結合 legacy 型別），而不是「缺少這個屬性」。資深 reviewer 的態度是先要求作者提供 minimal reproduction 並解釋為何現有繼承鏈不夠，而不是先接受新增，避免在不理解問題根因的情況下貿然擴大 public API 型別 surface。

## 嚴重度
CRITICAL：新增/修改的不是純型別欄位，而是實際會影響執行期行為的邏輯（例如把 `||` 誤用在需要區分 falsy 值與 `null`/`undefined` 的 fallback 場景，如 `getInnerChild(root) || root`，導致合法的 falsy 回傳值被錯誤地替換掉），造成 runtime 行為錯誤且被型別系統掩蓋而未被發現。
HIGH：新增的重複型別屬性與繼承鏈上既有型別定義不一致（型別衝突而非單純重複），可能讓使用者拿到錯誤的型別提示、寫出型別檢查通過但實際執行會出錯的程式碼。
MEDIUM：新增屬性單純與既有繼承鏈重複、沒有帶來新資訊，且沒有 reproduction 或測試佐證必要性；若被合併會造成後續維護負擔與型別 API surface 不必要膨脹，且日後很難判斷這個重複宣告是否還有存在意義。

## 反例（不該報）
- 新增的屬性是型別合成鏈上實際缺漏、或子型別刻意 override 父型別以縮窄/放寬型別，且 PR 中有清楚說明或測試佐證原因，不該報。
- PR 已附上具體 minimal reproduction，reviewer 確認問題根因確實在於缺少此型別欄位並放行合併的，不該報。
- 單純的標籤/結構修正（例如把不合法的 HTML 巢狀結構如 `<ul><div>` 改成 `<ul><li>`）屬於既有正確性修正，不落在本規則要攔的「重複型別宣告」範疇內，應視為一般 bug fix 而非本規則對象。
- reviewer 主動要求 revert 一個不必要的簽名/型別改動、恢復到舊版本（例如把新增的 optional 參數移除、保留原本已足夠的型別），這是正常的簡化建議，不是本規則要攔的「新增重複型別屬性未附佐證」情境。

## 出處
- https://github.com/vuejs/core/pull/11959#discussion_r1765919582
- https://github.com/vuejs/core/pull/9394#discussion_r1621491299
- https://github.com/vuejs/core/pull/8998#discussion_r1411479341
- https://github.com/vuejs/core/pull/9394#discussion_r1359204963
- https://github.com/vuejs/core/pull/9394#discussion_r1358100526
- https://github.com/vuejs/core/pull/9394#discussion_r1358076571
- https://github.com/vuejs/core/pull/6708#discussion_r975274061
