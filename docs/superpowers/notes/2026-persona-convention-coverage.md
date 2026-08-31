# convention-auditor persona 與覆蓋清單回測

`docs/superpowers/notes/2026-rule-extraction-comparison.md` 與
`docs/superpowers/notes/2026-layered-injection.md` 兩輪都卡在同一個天花板：
file_miss_rate（expected finding 所在的檔案裡一條 comment 都沒有）在 0.44 到
0.48 之間，規則改變的是既有注意力落在哪裡，不是它涵蓋的範圍。

`docs/superpowers/specs/2026-08-26-persona-convention-coverage-design.md`
拆解出兩個具體成因（PR#764：判準沒涵蓋跟既有慣例比對；PR#746：注意力被同
PR 裡更大的改動吸走），設計了兩個對應修法：新增 `convention-auditor`
persona、共用 prompt 樣板加覆蓋清單要求。這一輪回測結果是：兩個機制都在
運作，但整體 file_miss_rate 不降反升，根因是新增的工作量在固定 20 輪
turn 預算下讓 persona 個別失敗率從 3 次暴增到 21 次，其中 12 次是
convention-auditor 自己。

## 執行條件

38 個 confirmed PR、54 條 expected finding，`candidates_sha` 未變動（這次
沒有動 `candidates.json`）。personas 模式、輪數 20、claude sonnet、worktree
隔離、三點 range，不帶任何規則注入——跟 `baseline-personas` 唯一的差別是
persona 陣容從 5 個變 6 個，加上共用樣板多了覆蓋清單要求。

| | baseline-personas | personas-with-convention-auditor |
| --- | --- | --- |
| persona 數 | 5 | 6（多 convention-auditor） |
| 覆蓋清單要求 | 無 | 有 |
| PR 成功數 | 38/38 | 38/38（第一輪 OAuth 過期＋synthesize 8 輪上限失敗多次，接手重跑後全過） |

跑這一輪撞到兩類環境問題，跟這次改動本身無關：一次是 claude CLI 的 OAuth
token 被撤銷（401），一次是先前既知的 token 過期，兩次都在確認 auth 恢復後
原地重跑接手，`run-backtest.sh` 的續跑邏輯會自動跳過已成功的 PR。

## 整體指標

| | 容差 5 | 容差 15 |
| --- | --- | --- |
| baseline miss_rate | 0.85 (46) | 0.69 (37) |
| convention-auditor miss_rate | 0.85 (46) | 0.67 (36) |
| baseline file_miss_rate | 0.44 | 0.44 |
| convention-auditor file_miss_rate | 0.48 | 0.48 |
| baseline severity_rate | 0.25 | 0.41 |
| convention-auditor severity_rate | 0.38 | 0.50 |
| baseline comments_total | 217 | 217 |
| convention-auditor comments_total | 180 | 180 |
| baseline unmatched_rate | 0.96 | 0.92 |
| convention-auditor unmatched_rate | 0.96 | 0.90 |

（comments_total 本身不隨容差變，是同一份 review 輸出在不同容差下重算
指標——convention-auditor 這輪兩個容差都是 180，跟 baseline 的 217 不同，
不是巧合。tol5 的 unmatched_rate 兩邊剛好都四捨五入到 0.96，這才是真的
巧合。）

miss_rate 在容差 15 微幅改善（37→36），severity_rate 在數字上從 41%
升到 50%，但這兩個改善都伴隨 comments_total 下降 37 則（217→180）——不是
「講得更少但更準」的正面訊號，而是後面查出來的失敗率問題的副作用。這兩個
彙總指標本身能不能當「改善」或「惡化」的證據，要放進下面〈重複執行雜訊〉
一節裡跟底噪比過才算數。

**file_miss_rate 從 0.44 升到 0.48**，跟設計目標方向相反——但方向對不對
是一回事，這個差距夠不夠大到能下結論，見下一節。

## 為什麼會這樣：persona 個別失敗率暴增

逐 PR 的 `.err` 檔統計「某個 persona 沒有跑完、貢獻零內容」的次數：

| | 個別 persona 失敗次數 |
| --- | --- |
| baseline-personas（5 個） | 3 |
| personas-with-convention-auditor（6 個） | 21 |

21 次裡的分布：

| persona | 失敗次數（滿分 38） |
| --- | --- |
| convention-auditor | 12 |
| test-architect | 5 |
| api-contract-guardian | 4 |

`convention-auditor` 單一 persona 就在 38 個 PR 裡的 12 個（32%）沒能在 20
輪內跑完，遠高於其他 persona。它的 METHOD 要求先判斷每個改動檔案的角色、
再用 Grep 找同角色的 sibling 檔案逐項比對——比其餘 5 個 persona 多一輪
「先搜尋再比對」的往返，在同樣的 20 輪預算下更容易撞頂。

`api-contract-guardian`、`test-architect` 的失敗次數也比 baseline 那輪的
「3 次全部加起來」還高，這是覆蓋清單要求疊加的成本：所有 6 個 persona
（不只 convention-auditor）現在都被要求逐一交代 Changed Files 清單裡每一個
檔案，這道要求本身也吃掉額外的輪次。

一個 persona 在固定 turn 預算下失敗，不是「這個 PR 少一個角度看」而已——
它對這次 review 的貢獻是完全的零，包括它原本可能單獨抓到的任何 finding。
這解釋了 comments_total 為什麼下降：更多 persona 個別失敗，等於更多本來
會產出的 comment 沒有產出。也解釋了 file_miss_rate 為什麼上升：新增的
persona 跟覆蓋清單要求的本意是讓更多檔案被交代到，但如果那個 persona
自己先失敗了，它連「PASS」都交代不出來，覆蓋率反而比它不存在時更差。

## 兩個具體案例的追蹤結果

Task 3 對這兩個案例各自跑了兩次觀察（改動後、脫離基準線的單獨呼叫），
機制驗證分開記錄：

**PR#764**（`device-type-options.ts:22`，expected：query 沒標
`skipGlobalError`）：`convention-auditor` 這次沒有失敗，而且真的做了
sibling 比對——原始輸出裡明確拿同目錄下另一個以 `adFormatTypeId` 為參數的
query（`pricing-model-options.ts`）逐項對照 `enabled`、`staleTime`、key
形狀，判成 PASS。機制在運作，只是這次比對的維度沒有剛好覆蓋到
`skipGlobalError` 這個特定慣例，不是「FOCUS 沒涵蓋」的原始問題重演，是
單次執行下 sibling 比對挑中了哪個維度的變異。

**PR#746**（`$lineItemId.tsx:395`，expected：`useLineItemDetailDraft()` 少帶
`lineItem.id`）：兩次獨立觀察都印證了覆蓋清單機制本身有效——
`refactoring-sage`、`security-auditor` 都在輸出裡明確把 `$lineItemId.tsx`
標成「PASS（純 prop 傳遞）」，不再是先前版本裡「完全沒被提到」的狀態。但
同一個 PR 裡 `convention-auditor` 與 `test-architect` 兩次觀察都撞到 20
輪上限、整份輸出報廢，貢獻的 comment 是 0。這正是上一節整體數字裡看到的
機制，在單一 PR 上重現：機制生效的證據跟機制失敗的證據同時存在同一個
PR 裡。

## 重複執行雜訊

`docs/superpowers/notes/2026-layered-injection.md`〈重複執行基準線〉一節
量過同一組設定（personas 模式、輪數 20、同一批 38 個 PR）連跑兩次，54 條
expected finding 裡有 4 到 5 條的命中狀態會翻面——這是解讀本文任何「幾條
差異」時的底噪。同一次重跑也量到 severity_rate 在兩個容差下各自跳了
17、16 個百分點（33%→50%、47%→63%），comments_total 幾乎不變（194 對
198）。

拿這個底噪回頭看前面兩節的彙總指標：

- **file_miss_rate 從 0.44 升到 0.48**，對應 file_missed 24→26（54 條裡
  差 2 條）。這個差距落在浮動下限（4-5 條）以內甚至更小：方向是錯的，但
  幅度分不出來是真的變差，還是單純換一次執行就會出現的雜訊。
- **severity_rate 從 41% 升到 50%**，9 個百分點的變化，比重複執行基準線
  量到的 16-17 個百分點雜訊還小。這個數字同樣不能當「明顯上升」的證據，
  上一節已把「明顯」拿掉。

修正之後，唯一沒有被這個雜訊蓋過的證據是 persona 個別失敗率：3 次到 21
次是 7 倍的落差，遠超過任何一次重複執行基準線量到的浮動範圍，而且 21 次
失敗裡倖存下來的 20 份 stderr 檔案逐字都寫著同一句 `Error: Reached max
turns (20)`——這不是彙總指標的雜訊，是可驗證、可重現的失敗模式。

## 結論

兩個假設的機制都被證實真實存在——`convention-auditor` 真的會做 sibling
比對並非空談，覆蓋清單要求真的會逼 persona 交代原本會被略過的小改動。但
這次設計低估了新增工作量對固定 turn 預算的壓力，尤其是 `convention-auditor`
的 METHOD 天生比其餘 5 個 persona 貴（多一輪搜尋）。

net 上，這一輪的彙總指標（file_miss_rate、severity_rate）多半分不出「變
差」跟「雜訊」——上一節已經把這兩個數字放進重複執行的底噪比過。真正站得
住腳、不受雜訊影響的證據是 persona 個別失敗率從 3 次暴增到 21 次，而且
根因（20 輪 turn 預算撞頂）逐條 stderr 都能驗證。這才是下面判斷「不能算
達標」的主要依據，彙總指標只是附帶、方向正確但幅度不確定的旁證。

以「拿去解決 file_miss_rate 天花板」這個目標衡量，這次改動目前**不能算
達標**，需要下一輪處理 turn 預算問題才能重新驗證原本的假設。

## 驗證：convention-auditor 專屬 turn 上限（2026-08-31）

上一節〈下一步〉第一點的子選項（b）：`run_persona_review` 讓
`convention-auditor` 可以用新環境變數
`MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS` 單獨拉高 turn 上限，不動其餘
5 個 persona 共用的 `MRA_REVIEW_PERSONA_MAX_TURNS`（`lib/review-personas.sh`
`run_persona_review`，commit `cb6df82`）。不動 persona 的 METHOD，也不動
`run_synthesize`。

### 執行條件

label `personas-with-convention-auditor-turns30`，跟前兩輪同一份
`candidates_sha`（`7a8226ee333100a9`）、同一批 38 個 PR、容差 15。
`MRA_REVIEW_PERSONA_MAX_TURNS=20`（跟上一輪一致），
`MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS=30`（拉高 50%，沒有量測依據，
是先驗一次可行性的起始值）。跑完整 38 個 PR 之前，先單獨重跑 PR#746 當
sanity check——這個 PR 先前兩次獨立觀察 convention-auditor 都撞了 20 輪
上限——這次沒有出現任何 persona 失敗紀錄，才進到完整回測。

### persona 個別失敗率：驗證有效

| | baseline-personas（5 個 persona） | with-auditor 共用 20 輪（6 個） | with-auditor-turns30（6 個，這輪） |
| --- | --- | --- | --- |
| 個別失敗總次數 | 3（未逐一細分是哪個 persona） | 21 | 9 |
| convention-auditor | 不存在 | 12 | 1 |
| test-architect | — | 5 | 7 |
| api-contract-guardian | — | 4 | 1 |

convention-auditor 從 12 次降到 1 次，是這次改動要驗證的目標，機制生效。
test-architect 的失敗次數（7）沒有跟著下降，甚至比前兩輪都高，說明它的
失敗成因跟 convention-auditor 的 turn 上限無關——上一節〈下一步〉第二點
點出的覆蓋清單成本，這輪同樣沒有動它，還是原封不動地在吃預算。

### 新問題：瓶頸下推到 debate/synthesize 層

前兩輪 PR 成功數都是 38/38，這輪掉到 35/38——PR#752、#780、#817 完全
失敗，三份 `.err` 檔案裡的訊息都是 `[debate] claude failed ... Error:
Reached max turns (8)`，即 `MRA_REVIEW_SYNTH_MAX_TURNS`（正式名稱更正：
不是 `MRA_REVIEW_AGENT_MAX_TURNS`，那個預設 20，是給 debate 路徑 Agent
A/B 分析階段用的；這裡撞頂的是 `run_synthesize` 用的
`MRA_REVIEW_SYNTH_MAX_TURNS`，預設 8，這次沒有調整）撞頂，不是任何一個
persona 本身失敗。

PR#817 是最乾淨的案例：6 個 persona 全部成功，`.err` 檔案裡沒有任何一條
persona 層的失敗紀錄，但 debate 階段自己撞了 8 輪上限，整個 review 輸出
報廢。瓶頸沒有消失，只是從「persona 層 20 輪」移到了「debate 層 8
輪」——convention-auditor 這次確實把原本會空手而回的內容交了出來，但
下游處理這些材料的預算沒有跟著放寬。

### 彙總指標：分母縮水，不能跟前兩輪直接比

3 個失敗 PR 各自帶走 2、1、1 條 expected finding，共 4 條。
`run-backtest.sh` 對失敗的 PR 一律排除、不計入任何統計，這輪的分母因此
從前兩輪的 54 條縮成 50 條。下面只列絕對值，不直接比較比例：

| | baseline-personas | with-auditor 共用 20 | with-auditor-turns30 |
| --- | --- | --- | --- |
| expected_total | 54 | 54 | 50 |
| missed | 37 | 36 | 33 |
| miss_rate | 0.69 | 0.67 | 0.66 |
| file_missed | 24 | 26 | 24 |
| file_miss_rate | 0.44 | 0.48 | 0.48 |
| comments_total | 217 | 180 | 152 |
| severity_agree | 7 | 9 | 8 |
| severity_rate | 0.41 | 0.50 | 0.47 |
| PR 成功數 | 38/38 | 38/38 | 35/38 |

file_missed 的絕對數（24）回到了 baseline 的水準，但因為分母從 54 縮到
50，比例仍是 0.48，沒有反映出這個回落——分母裡消失的那 4 條 expected
finding 命中與否完全未知，不能假設它們原本會被抓到或漏掉，所以這裡不能
說「file_miss_rate 其實已經改善只是被分母蓋過」，只能說絕對值跟比例在
這輪呈現不同方向，兩個都要保留，都不能單獨拿來下結論。

comments_total 從 180 降到 152，同樣主要是少了 3 個 PR。換算成每個成功
PR 的平均值：baseline 5.7、上一輪 4.7、這輪 4.3，持續下降，跟 persona
個別失敗總次數下降（21→9）方向相反。比較合理的解讀：這 3 個完全失敗的
PR，正是 persona 層產出內容最多、才會讓 debate 撞頂的那幾個，被踢出樣本
之後系統性拉低了剩餘 35 個 PR 的平均值——不是「這次設定讓 persona 講得
更少」，是「講得最多的幾個 PR 直接報廢，不計入平均」。

### 結論

子選項（b）本身驗證有效：convention-auditor 的個別失敗率如預期壓下來
了，機制運作方式跟預期一致。但整體目標（file_miss_rate 天花板）仍然
沒有被這輪回答——即使不考慮分母縮水的問題，0.48 也還沒回到 baseline 的
0.44；而且解決 persona 層瓶頸之後，debate/synthesize 層固定的 8 輪
預算變成了新的撞頂點，比前兩輪多損失 3 個 PR、4 條 expected finding 的
資訊。

## 下一步

一、`MRA_REVIEW_SYNTH_MAX_TURNS`（synthesize 層，目前固定 8）需要跟
persona 層同樣的處理——先用單一 PR（例如 PR#817，6 個 persona 全過但
debate 撞頂的最乾淨案例）驗證拉高之後真的能跑完，再跑一輪完整回測。在
這個問題解決之前，重跑任何一輪都會撞到同樣的下推瓶頸。

二、覆蓋清單要求對 test-architect、api-contract-guardian 的成本仍然沒有
被單獨量化——這輪它們的失敗次數（7、1）比 baseline（5 個 persona 合計
3 次）高，需要一輪只加覆蓋清單、不加新 persona／不動 turn 上限的對照組
才能回答。

三、`2026-rule-extraction-comparison.md` 與 `2026-layered-injection.md`
共同指出的 file_miss_rate 天花板依然沒有被回答，要等第一點的 debate 層
瓶頸解決、能拿到一輪 38/38 全過的完整資料後，才有資格重新檢驗。
