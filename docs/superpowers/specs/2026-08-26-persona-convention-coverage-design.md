# persona 慣例比對與覆蓋清單 — 設計

**Date:** 2026-08-26
**Status:** Approved (brainstorming)

## 問題

`docs/superpowers/notes/2026-rule-extraction-comparison.md` 與
`docs/superpowers/notes/2026-layered-injection.md` 兩輪回測都指出同一個天花板：
不管規則怎麼組織、分不分層，file_miss_rate（expected finding 所在的檔案裡一條
comment 都沒有）一直卡在 0.45 到 0.48。規則改變的是既有注意力落在哪裡，不是
它涵蓋的範圍。

先拆解這批 file_miss 案例的成因：taxonomy-layered 那輪 26 個案例，逐一比對
PR 的實際 diff（`gh api repos/.../pulls/.../files`），結果是 26/26 全部
`IN_DIFF_IGNORED`——檔案都在這次 PR 改動範圍內，reviewer 只是沒講。

再往下查兩個具體案例，看 5 個 persona 的原始輸出（在 `run_persona_review`
臨時插入除錯輸出，跑完即還原，未進版控），確認是兩種不同機制：

- **acme/nest-monorepo-2.0#764**（`device-type-options.ts:22`，expected：
  「query 沒標 `skipGlobalError`，跟其他 query 的既有慣例重複跳全域錯誤
  toast」）：`api-contract-guardian`、`security-auditor`、`test-architect`
  三個都讀過這個檔案，各自做出「沒問題」的具體判斷（契約 shape 對、驗證邏輯
  對、測試品質另外有兩條進了最終 comment）。沒有人讀是假的，是五個 persona
  的 FOCUS 裡沒有一個是「跟專案裡同類程式碼比對慣例」——這種缺陷只看這份
  diff 看不出來，得知道別的 query 怎麼標這個 flag。
- **acme/nest-monorepo-2.0#746**（`$lineItemId.tsx:395`，expected：
  「`useLineItemDetailDraft()` 少帶 `lineItem.id`，草稿變成跨明細共用」）：
  5 個裡只有 1 個提到這個檔案，而且只是拿它當「呼叫端有沒有正確傳新 props」
  的佐證，從未把這 7 行的 diff 當成獨立要檢查的目標。同一個 PR 裡另一個檔案
  改動比較大、比較「有戲」，吃走了全部注意力。

兩種機制、兩種修法：前者要給 reviewer 對照既有慣例的能力，後者要確保每個
改到的檔案都被獨立檢視一次，不因為同 PR 裡有更大的改動就被略過。

## 目標

在 `mra review --strategy personas` 這條路徑上，同時處理這兩個機制，用同一批
38 個 PR 的 personas 基準線（不帶任何規則注入）重跑，看 file_miss_rate 有沒有
從 0.45～0.48 往下動。

不處理的事：規則注入（tfidf／taxonomy／分層）本身、synthesize 階段的
token 預算問題、debate 策略（Agent A/B）路徑。這些是獨立的既有機制，這次
設計只動 personas 陣容與 persona prompt 的共用樣板。

## 設計

### 一、新增第 6 個 persona：慣例比對

新檔 `agents/personas/convention-auditor.md`，格式比照既有 5 份
（`ROLE`/`STYLE`/`FOCUS`/`METHOD`/`OUTPUT FORMAT`，`agents/personas/README.md`
的既定慣例）：

```
ROLE: Convention Auditor
STYLE: 資深維護者 — 不問「這樣寫對不對」，問「跟旁邊那份比一致嗎」。

FOCUS:
- 新增/修改的函式跟同目錄或同 feature 裡同類型的其他檔案（同樣是 query、
  mutation、hook、middleware……）比，行為模式是否一致
- 錯誤處理、loading/empty state、權限守門的慣例是否跟 sibling 程式碼一樣
- 有沒有本該套用某個既有 helper／wrapper 卻手刻一份
- 命名以外的行為慣例（helper 呼叫順序、flag 預設值、錯誤吞不吞）

SCOPE NOTE: 不管命名／結構整潔（那是 refactoring-sage 的事），只管「這裡
跟別處的實際行為是否一致」。

METHOD:
1. 對每個改動的檔案，判斷它屬於哪一種角色（query/mutation/hook/component…）。
2. 用 Grep 找同角色的其他檔案（同目錄或同 feature 家族）。
3. 逐項比對行為慣例，只在真的找到至少一個 sibling 可比對時才報。找不到
   sibling 就略過，不要用「應該要」的臆測取代真的比對過的證據。

OUTPUT FORMAT:
- [HIGH] `file:line` — <跟哪個 sibling file:line 比對出的不一致>
- [MEDIUM] `file:line` — <輕微的行為慣例落差>
```

`default_review_personas()`（`lib/review-personas.sh:5`）加入
`convention-auditor`，5 個變 6 個，跟其餘 5 個一樣平行跑，不拉長總時間，
只多約 1/6 的 token 成本。

### 二、共用樣板加一道覆蓋清單要求

`build_persona_prompt`（`lib/review-personas.sh:9`）的樣板在
`%CHANGED_FILES%` 之後加一段：

```
## 覆蓋確認
結束前，把上面 Changed Files 清單裡的每一個檔案都列出來，each 各自標
PASS（看過、沒問題）或列出你的 finding。不能悄悄跳過任何一個檔案。
```

這是給既有 5 個 persona（連同新的第 6 個）共用的一道要求，不是新 persona
專屬。目的是把 PR#746 那種「大改動吃走全部注意力」的情況變成「至少要交代
一句」，用很輕的成本換一個不會被靜默略過的下限。

### 三、跟規則注入機制的相容性

`lib/rule-inject.sh` 的 `rule_inject_all`／`rule_inject_layers` 是對
`default_review_personas()` 回傳的清單逐一注入 FOCUS 區塊，加了
`convention-auditor` 之後兩者都會自動把它算進去，不用改注入邏輯本身。
但要注意兩處假設要更新：

- `run-rule-backtest.sh` 與既有回測筆記裡多處寫死「5 個 persona」、
  「4/5 有 FOCUS」的敘述（例如 `run-rule-backtest.sh` 檔頭註解、
  `2026-rule-extraction-comparison.md` 的執行條件段），改動落地後這些數字
  會變成 6 跟 5/6，屬於文件更新，不是程式邏輯風險。
- `test-architect.md` 目前沒有 `FOCUS:` 錨點（用「KENT BECK 11
  PRINCIPLES:」取代），注入時會被跳過。`convention-auditor.md` 一定要帶
  `FOCUS:` 錨點，否則規則注入時會被誤判成第二個「無法注入」的 persona。

### 四、驗證

用 `scripts/run-backtest.sh` 對同一批 38 個 confirmed PR、`candidates_sha`
仍要是 `7a8226ee333100a9`，跑一輪不帶規則注入的 personas 基準線（不透過
`run-rule-backtest.sh`，因為那支腳本的用途是「帶規則」，這裡要測的是
persona 陣容本身的改動）。跟 `baseline-personas` 那輪（38/38、38 個
confirmed PR）比 `file_miss_rate`、`miss_rate`、`comments_total`：

- `file_miss_rate` 是這次設計要動的主要指標，預期往下降。
- `comments_total` 預期會上升（多一個 persona、覆蓋清單逼出更多「至少交代
  一句」的內容），這本身不是問題，但要留意 `unmatched_rate` 會不會跟著漲
  太多——如果新增的 comment 大部分是雜訊，等於用噪音換覆蓋率，不算真的解決
  問題。
- 兩個追蹤過的具體案例（PR#764、PR#746）值得單獨重跑確認：`device-type-
  options.ts` 有沒有被 `convention-auditor` 抓到、`$lineItemId.tsx:395`
  有沒有因為覆蓋清單要求而被單獨交代。

## 這個設計刻意不做的事

- 不改 synthesize 階段的邏輯或輪數：那是另一個已知瓶頸（8 輪上限），跟這次
  的兩個機制無關，混在一起改會讓後續回測分不出改善來自哪裡。
- 不對 debate 策略（Agent A/B）做同樣的改動：目前的回測基準線都是 personas
  模式，debate 路徑的覆蓋率問題留待需要時另外處理。
- 不追求覆蓋清單的完整性驗證（例如自動比對 persona 輸出是否真的窮舉了
  Changed Files 清單）：這是一道 prompt 層級的要求，不是結構性強制，驗證
  仰賴人工抽查跟回測結果，不在這次設計範圍內加自動檢查機制。
