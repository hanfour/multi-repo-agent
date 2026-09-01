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

（2026-09-02 更正：這段結論是在只看得到最終 JSON 的情況下推論的。留存
persona 原始輸出之後，同樣設定重跑這個 PR，convention-auditor 覆蓋到了
那個維度，而且報成 HIGH，是 synthesize 沒有把它留下來。見
〈persona 抓到了，synthesize 丟掉了〉一節。）

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
  （2026-09-01 更正：這裡把 missed 的 4-5 條門檻套到 file_missed 上是
  沒有依據的，那個門檻沒有在 file_missed 這個度量上量過。見
  〈對照組：只加覆蓋清單，不加新 persona〉的〈彙總指標〉一節。）
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

## 驗證：personas 路徑 synthesize 專屬 turn 上限（2026-08-31）

上一節〈下一步〉第一點：`run_synthesize` 加一個可選的 `max_turns` 參數
（commit `8ec40fd`），debate 路徑的 4 個既有呼叫點不動，只在 personas
路徑（`lib/review.sh`）顯式傳入新環境變數
`MRA_REVIEW_PERSONA_SYNTH_MAX_TURNS`，未設定時退回共用的
`MRA_REVIEW_SYNTH_MAX_TURNS`（預設 8）。

### 執行條件

label `personas-with-convention-auditor-turns30-synth16`，跟前三輪同一
份 `candidates_sha`、同一批 38 個 PR、容差 15。`MRA_REVIEW_PERSONA_MAX_TURNS=20`、
`MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS=30`（跟上一輪一致），
`MRA_REVIEW_PERSONA_SYNTH_MAX_TURNS=16`（共用值 8 的兩倍，沒有量測依據，
起始值）。先用 PR#817（上一輪 6 個 persona 全過、debate 自己撞頂的最乾淨
案例）單獨驗證：這次順利跑完，沒有任何失敗紀錄，才進到完整回測。

完整回測第一次跑到 25/38 時，`run-backtest.sh` 自己的覆蓋率門檻
（`COVERAGE_TOO_LOW`，低於 0.8 直接判定「這一輪的數字不可用」）擋下了
一份不能用的結果——`.err` 檔案顯示從某個時間點開始，大量 PR 撞到
`You've hit your session limit · resets 8pm (Asia/Taipei)`，是 claude
CLI 的帳號用量額度耗盡，跟這次程式改動無關，是環境問題（跟
`docs/superpowers/plans/2026-08-26-persona-convention-coverage.md` 記錄
過的 OAuth 過期是同一類狀況）。額度重置時間過後，原地重跑同一個
`--label` 指令接手——`run-backtest.sh` 的續跑邏輯確認只重跑了失敗的
PR（已成功 PR 的檔案時間戳沒有變動），最終拿到一份完整、乾淨的結果。

### PR 成功數：這系列回測第一次 38/38 全過

| | baseline-personas | with-auditor 共用 20 | with-auditor-turns30 | 這輪（turns30+synth16） |
| --- | --- | --- | --- | --- |
| PR 成功數 | 38/38 | 38/38 | 35/38 | **38/38** |
| 個別失敗總次數 | 3 | 21 | 9 | 8 |
| convention-auditor | 不存在 | 12 | 1 | 2 |
| test-architect | — | 5 | 7 | 4 |
| api-contract-guardian | — | 4 | 1 | 2 |

上一輪的 3 個完全失敗（persona 層修好、瓶頸下推到 synthesize 層撞頂）
這輪全部消失，沒有出現新的完全失敗案例。convention-auditor 的個別失敗
次數比上一輪（1 次）略回升到 2 次，但仍遠低於共用 20 輪那輪的 12 次。

### 彙總指標：這次跟 baseline 分母一致（都是 54 條），可以直接比

| | baseline-personas | 這輪（turns30+synth16） | 差距 | 落在雜訊底噪內？ |
| --- | --- | --- | --- | --- |
| expected_total | 54 | 54 | — | — |
| missed | 37 | 35 | -2 條 | 是（底噪 4-5 條） |
| miss_rate | 0.69 | 0.65 | -0.04 | 是 |
| file_missed | 24 | 23 | -1 條 | 無法判斷（見下方更正） |
| file_miss_rate | 0.44 | 0.43 | -0.01 | 無法判斷 |
| severity_rate | 0.41 | 0.53 | +0.12 | 是（底噪 16-17 個百分點） |
| comments_total | 217 | 175 | -42 則 | — |
| unmatched | 200 | 156 | -44 則 | — |
| unmatched_rate | 0.92 | 0.89 | -0.03 | — |

底噪引用 `2026-layered-injection.md`〈重複執行基準線〉：同一組設定連跑
兩次，54 條裡有 4-5 條命中狀態會翻面，severity_rate 在兩個容差下各自
跳了 16-17 個百分點，comments_total 幾乎不變（194 對 198，差 4 則）。
miss_rate、severity_rate 這兩個的差距都落在或接近這個底噪範圍內，不能
斷言「改善」。file_miss_rate 這一列原本也寫「在底噪內」，
2026-09-01 更正：那個 4-5 條的門檻是在 missed 上量的，沒有在 file_missed
上量過，這一格應該是「無法判斷」。可以確定的只有 file_missed 這輪是 23，
是四輪裡最低的一個（baseline 24、with-auditor 26、turns30 24），至於這
算不算改善，要等 file_missed 自己的浮動被量出來才知道。

comments_total 下降 42 則、unmatched 下降 44 則，兩者幾乎完全對應：
少掉的 comment 幾乎都是先前會被判成 unmatched 的那些。跟先前重複執行
底噪「comments_total 幾乎不變」的量測相比（差距 4 則），42 則的落差
跨得出去，是有意義的訊號。

2026-09-01 更正：這裡原本把 unmatched 稱作「噪音」，並據此說「下降的
主要是噪音、不是有用的 finding」。unmatched 的定義只是「跟基準集裡任何
一條 expected finding 都對不上」，而基準集是從後續修 bug 的 commit 反推
出來的，涵蓋不到所有真實有效的 review 意見。正確的說法是「跟基準集對不
上的 comment 少了 44 則」，那些 comment 有沒有價值，這份資料回答不了。

### 結論

給 personas 路徑一個獨立、更寬的 synthesize turn 上限之後，PR 成功數
第一次達到 38/38，且沒有引入任何新的完全失敗案例。這是可以確定的事實。

「`MRA_REVIEW_SYNTH_MAX_TURNS` 是真正的瓶頸」這個因果解釋，在
2026-09-01 那輪之後要打折：同樣是 synth 8，PR#817 在某些設定下跑得完、
某些跑不完（見〈#817：五種設定下的結果不構成一致模式〉），所以 synth
從 8 放寬到 16 跟 38/38 之間的關係，比原本寫的更弱。

file_miss_rate 天花板本身仍然沒有被打破——但「這輪 0.43 跟 baseline
0.44 的差距在雜訊範圍內」這句話也是誤用了 missed 的門檻，見上面的更正。
可以確定的是：這是第一次能在同樣的 54 條分母、38/38 全過的乾淨資料上跟
baseline 直接比較，不用再像前三輪一樣先扣掉分母縮水或失敗率暴增的干擾。

## 下一步（2026-08-31）

一、覆蓋清單要求對 test-architect、api-contract-guardian 的成本仍然沒有
被單獨量化——這輪它們的失敗次數（4、2）比 baseline（5 個 persona 合計
3 次）高，需要一輪只加覆蓋清單、不加新 persona／不動 turn 上限的對照組
才能回答，是不是這道要求本身在吃預算，還是純粹跟這輪的隨機波動有關。

二、`2026-rule-extraction-comparison.md` 與 `2026-layered-injection.md`
共同指出的 file_miss_rate 天花板，這輪雖然拿到了乾淨資料，但差距在雜訊
範圍內，還不能下結論。要看到明確、超出底噪範圍的改善，可能需要再往前
一步——例如 convention-auditor 的 METHOD 本身（先前〈下一步〉子選項
（a），這一系列一直沒有動過）是不是也該調整，或者這個天花板本身有別的
成因，兩個追蹤過的成因（PR#764、PR#746）已經被機制證實存在，但沒有大到
能穿透底噪的程度。

三、convention-auditor 失敗次數這輪回升到 2 次（上一輪 1 次），樣本數
太小（38 個 PR 裡的 1-2 次差距）分不出是雜訊還是 30 輪真的偶爾不夠，
不需要單獨追——如果之後某一輪它的失敗次數明顯升高，才需要回頭檢視
`MRA_REVIEW_CONVENTION_AUDITOR_MAX_TURNS=30` 這個起始值夠不夠。

## 對照組：只加覆蓋清單，不加新 persona（2026-09-01）

回答上一節〈下一步〉第一點。label `personas-coverage-checklist-only`：
5 個 persona（跟 baseline 同陣容，`MRA_REVIEW_ENABLE_CONVENTION_AUDITOR=0`）、
`MRA_REVIEW_ENABLE_COVERAGE_CHECKLIST=1`、persona 20 輪、synthesize 維持
預設 8 輪（刻意不放寬，才能只留覆蓋清單這一個變因）。同一份
`candidates_sha`、容差 15。37/38 成功（`failed_count=1`），覆蓋率 0.97
高於 `run-backtest.sh` 的 0.8 門檻，數字可用。

過程中同樣撞到一次 claude CLI 額度耗盡（`resets 1am`），一樣被
`COVERAGE_TOO_LOW` 擋下（0.42），額度重置後原地重跑接手。連續兩輪都在
跑到 17-25 個 PR 時撞到額度上限，是規劃後續回測要納入的執行條件。

### 兩筆成本各自的數字

四輪擺在一起，前兩維剛好構成「有無 convention-auditor」×「有無覆蓋
清單」的對照：

| | persona 陣容 | 覆蓋清單 | turn 預算 | 個別失敗總次數 |
| --- | --- | --- | --- | --- |
| baseline-personas | 5 | 無 | 共用 20／synth 8 | 3 |
| coverage-checklist-only（這輪） | 5 | 有 | 共用 20／synth 8 | 8 |
| with-convention-auditor | 6 | 有 | 共用 20／synth 8 | 21 |
| turns30+synth16 | 6 | 有 | 30／synth 16 | 8 |

逐 persona 拆開：

| | baseline | coverage-only | with-auditor | turns30+synth16 |
| --- | --- | --- | --- | --- |
| test-architect | 未逐一細分 | 6 | 5 | 4 |
| api-contract-guardian | （合計 3） | 2 | 4 | 2 |
| convention-auditor | 不存在 | 不存在 | 12 | 2 |

覆蓋清單本身的成本：3 → 8，多 5 次個別失敗，5 個 persona 陣容不變、
turn 預算不變，唯一的差別就是這道要求。convention-auditor 自己的成本：
`with-auditor` 那輪 21 次裡它佔 12 次，其餘 9 次（test-architect 5 ＋
api-contract-guardian 4）跟這輪的 8 次（6＋2）落在同一個量級。

這兩個數字有兩個限制。第一，這是 2x2 設計裡的三格，缺「開
convention-auditor、關覆蓋清單」那一格，所以只能說兩筆成本可以各自估出
一個數，不能說它們之間沒有交互作用。第二，baseline 那輪的 3 次沒有逐
persona 細分，「多 5 次」是總數相減，不是同一個 persona 前後比。

### #817：五種設定下的結果不構成一致模式

這輪唯一失敗的 PR#817，`.err` 寫的是 `Reached max turns (8)`，5 個
persona 全部成功、synthesize 自己撞頂。把這個 PR 在五輪裡的結果全部
攤開：

| 設定 | PR#817 |
| --- | --- |
| 5 persona ＋ 無覆蓋清單 ＋ synth 8（baseline） | 跑完 |
| 6 persona ＋ 覆蓋清單 ＋ 共用 20 輪 ＋ synth 8 | 跑完 |
| 6 persona ＋ 覆蓋清單 ＋ auditor 30 輪 ＋ synth 8 | 撞頂失敗 |
| 5 persona ＋ 覆蓋清單 ＋ synth 8（這輪） | 撞頂失敗 |
| 6 persona ＋ 覆蓋清單 ＋ auditor 30 輪 ＋ synth 16 | 跑完 |

同樣是覆蓋清單加 synth 8，第二列跑完、第三與第四列撞頂。單一 PR、每種
設定各跑一次，分不出這是設定造成的差異還是同一設定下的執行浮動。可以
說的只有兩件事：synth 8 之下這個 PR 至少失敗過兩次、synth 16 之下跑完
過一次。不能說撞頂的主因是覆蓋清單，也不能說跟 persona 數量無關：
第二列跟第三列的 persona 陣容與覆蓋清單都一樣，差別只在
convention-auditor 的 turn 上限，而那個參數理論上不影響 synthesize 的
輸入量。

`MRA_REVIEW_PERSONA_SYNTH_MAX_TURNS`（commit `8ec40fd`）之後那一輪拿到
38/38，這個事實不變；但「為什麼 synth 8 有時候不夠」目前沒有乾淨的
解釋，「覆蓋清單讓每個 persona 的輸出變長」是一個跟資料相容的推測，
沒有量過 persona 輸出長度，不能當結論。

### 彙總指標

| | baseline | coverage-only（這輪） | turns30+synth16 |
| --- | --- | --- | --- |
| expected_total | 54 | 53 | 54 |
| missed | 37 | 38 | 35 |
| miss_rate | 0.69 | 0.72 | 0.65 |
| file_missed | 24 | 25 | 23 |
| file_miss_rate | 0.44 | 0.47 | 0.43 |
| comments_total | 217 | 172 | 175 |
| unmatched | 200 | 157 | 156 |
| unmatched_rate | 0.92 | 0.91 | 0.89 |
| severity_rate | 0.41 | 0.53 | 0.53 |
| PR 成功數 | 38/38 | 37/38 | 38/38 |

missed 跟 baseline 差 1 條（37 → 38），落在 `2026-layered-injection.md`
量到的 4-5 條浮動內，不能說覆蓋清單讓漏抓變差。

file_missed 差 1 條（24 → 25）不能用同一句話帶過：那個 4-5 條的浮動是
在 missed 上量的，file_missed 從來沒有量過重複執行浮動。兩者不是同一個
度量。file_missed 問的是「這個檔案裡有沒有任何 comment」，對錨點漂移
免疫，浮動應該比 missed 小，但小多少沒有數字。這一節（以及本文前面
所有拿 4-5 條門檻去判斷 file_missed 的地方）都受這個限制影響：目前無法
判斷 24 → 25 → 26 → 23 這些變化是不是雜訊。

comments_total 是唯一有底噪可比、且明顯跨出去的：`2026-layered-injection.md`
量到重複執行下它幾乎不變（194 對 198，差 4 則），而這裡 217 → 172 少了
45 則。三輪帶覆蓋清單的結果分別是 172、180、175；因為 PR 數不同（37 或
38），換成每個 PR 平均比較公平：baseline 5.71，三輪帶覆蓋清單的是
4.65／4.74／4.61。開不開 convention-auditor 都落在 4.6-4.7 之間，
baseline 明顯較高。review 講得比較少這件事跟覆蓋清單同時出現，跟
convention-auditor 沒有對應關係。

unmatched 同步從 200 降到 157／156。unmatched 的定義是「跟基準集裡任何
一條 expected finding 都對不上」，這不等於「是噪音」：基準集是從後續修
bug 的 commit 反推出來的，本來就涵蓋不到所有真實有效的 review 意見。
所以只能說「跟基準集對不上的 comment 少了 43 則」，不能說「噪音少了 43
則」。少掉的那些是不是真的沒價值，這份資料回答不了。

severity_rate 兩輪都是 0.53、baseline 0.41，差 12 個百分點，仍在底噪
（16-17 個百分點）內，不能當證據。

### 結論

覆蓋清單要求算得出來的帳：個別 persona 失敗從 3 次增為 8 次（總數相減，
baseline 未逐一細分）、每個 PR 的 comment 從 5.71 則降到 4.65 則、跟
基準集對不上的 comment 少 43 則、missed 的變化落在浮動內。

算不出來的帳：file_missed 的變化無法判斷（沒有這個度量的浮動基準）；
少掉的 comment 有沒有價值（基準集涵蓋不到的部分無法評估）；覆蓋清單跟
convention-auditor 之間有沒有交互作用（缺 2x2 的第四格）；synth 8 撞頂
的成因（同設定下有成功有失敗）。

convention-auditor 的成本是另外一筆：在共用 20 輪預算下是 12 次失敗，
給它 30 輪之後降到 2 次。

## 下一步（2026-09-01）

一、先補量 file_missed 的重複執行浮動。這是解鎖其他判斷的前提：本文
（以及前面幾節）所有關於 file_missed 的「在底噪內」判斷，都是把 missed
的 4-5 條門檻挪用過來的，沒有依據。做法跟
`2026-layered-injection.md`〈重複執行基準線〉一樣，同一個 label 跑第二
次，逐條比對檔案層級的命中狀態。成本是一輪回測。

在那之前，「file_miss_rate 天花板沒有被打破」這句話本身也是證據不足的：
四輪的 file_missed 是 24、25、26、23，如果 file_missed 自己的浮動其實
只有 1-2 條，這幾個數字就不是「都在同一區間」，而是有方向的變化。
目前無法分辨。

二、補跑 2x2 的第四格：`MRA_REVIEW_ENABLE_CONVENTION_AUDITOR=1` ＋
`MRA_REVIEW_ENABLE_COVERAGE_CHECKLIST=0`。有了這格才能講「兩筆成本
獨立」，沒有的話只能各自報一個數。

三、convention-auditor 的 METHOD（先前子選項（a），一直沒動過）仍是
未試過的變因，但在第一、二點補齊之前動它，等於在看不清底噪的情況下再
加一個機制，沒有比前四輪更多的依據。

四、覆蓋清單要不要改成預設開（目前預設關），取捨是「每個 PR 少講 1.06
則、其中多數跟基準集對不上」對上「多 5 次 persona 個別失敗」。這是產品
決定不是量測問題，但要注意「少講的那些沒價值」目前沒有證據，基準集
涵蓋不到的部分這份資料回答不了。

## 逐條分析：file_missed 這個數字底下是什麼（2026-09-01）

〈下一步（2026-09-01）〉第一點的重跑還在進行，但在等它的期間，四輪既有
資料本身還能回答一些問題，成本是零：把每一條 expected finding 在四輪的
「檔案層級命中與否」逐條攤開，而不是只看 file_missed 的總數。

做法照 `lib/backtest-metrics.sh` 的 `backtest_file_missed` 同一套判斷
（該 PR 所有 comment 的 path 取集合，這條 expected finding 的 path 在不
在裡面），逐條輸出而不是加總。先用四輪既有結果驗證這套重算：MISS 數
分別是 24、25、26、23，跟四輪 `summary.json` 記的 file_missed 完全一致
（coverage-only 那輪另有 1 條 SKIP，對應 #817 失敗帶走的那條）。

### 總數穩定，底下卻一直在翻面

| 兩輪比較 | 只有前者命中 | 只有後者命中 | churn 合計 |
| --- | --- | --- | --- |
| baseline vs coverage-only | 5 | 3 | 8 |
| baseline vs with-auditor | 7 | 5 | 12 |
| baseline vs turns30+synth16 | 4 | 5 | 9 |
| coverage-only vs with-auditor | 4 | 3 | 7 |
| coverage-only vs turns30+synth16 | 3 | 6 | 9 |
| with-auditor vs turns30+synth16 | 4 | 7 | 11 |

四輪的 file_missed 總數只在 23-26 之間（差 3 條），但任兩輪之間有 7 到
12 條的命中狀態翻面，而且方向大致對稱。總數的穩定是雙向翻面互相抵消的
結果，不是同一批條目穩定地被漏掉。54 條裡 21 條四輪都命中、15 條四輪
都漏、17 條會翻面。

這解釋了先前幾節拿 23 對 24 去談「有沒有改善」為什麼問不出東西：那個
數字對「哪些條被抓到」幾乎沒有解析度。

### 基準集的條目不獨立

54 條裡有 12 條的 note 都在講同一件事的兩種型態：「useLineItemDetailDraft()
沒帶 lineItem.id」8 條、「丟棄草稿綁在元件卸載」4 條，分散在 11 個 PR。
查 `candidates.json` 的 fix_commits 可以確認它們同源：#746、#750、#785
三個 PR 的 fix_commits 都包含同一個 sha（`4518e2af`），是同一個修正被
反推到三個 PR 上。這批 PR 集中在 2026-07-30 到 08-07。

拆開這 12 條跟其餘 42 條分開算：

| | 草稿那組 | 其餘 42 條 |
| --- | --- | --- |
| baseline | 7/12 漏（58%） | 17/42 漏（40%） |
| coverage-only | 6/11 漏（55%） | 19/42 漏（45%） |
| with-auditor | 7/12 漏（58%） | 19/42 漏（45%） |
| turns30+synth16 | 9/12 漏（75%） | 14/42 漏（33%） |

`turns30+synth16` 那輪的 file_missed 總數是四輪最低（23），前一節據此說
「第一次沒有比 baseline 差」。逐條拆開之後，那個 -1 條是兩個相反方向
抵消的結果：其餘 42 條少漏 3 條（40% → 33%），草稿那組多漏 2 條
（58% → 75%）。單看總數看不到這件事。

要注意這 12 條的權重問題：它們在指標裡算 12 條，但代表的是 2 個缺陷
型態。任何對這兩型缺陷的系統性敏感或盲點，都會被放大成 12 條的變化。

### 這 15 條「四輪都漏」不是一個穩定的集合

把第五輪 `personas-with-convention-auditor-turns30`（35/38，先前因為
3 個 PR 失敗而沒有納入比較）也算進來，五輪都漏的只剩 13 條；五取四的
五種組合，全漏數分別是 13、14、15、14、14。「15」是這幾種切法裡最大的
一個。交集的成員資格本身就隨輪數與輪次選擇而變，這跟上面量到的 7-12
條翻面是同一件事的兩種說法。

### 一個被推翻的歸納，跟一個更強的解釋

看到這 15 條的 note 之後，本文作者先歸納成「它們都需要跨檔案的狀態
一致性推理，現有 6 個 persona 沒有一個負責這個角度」。這個歸納經不起
逐條檢查：

- 15 條對應的相異缺陷只有 10 個，其中符合「跨檔案狀態一致性」描述的
  最多 5 條（草稿 key 3 條、mutation 後漏失效 2 條），而且收斂成 2 個
  缺陷家族。
- `#410`（`STUDIO_URL` 只驗證是不是合法 URL、沒限制 scheme）是反例：
  單行內就看得完，不需要任何跨檔案資訊，而且正落在 security-auditor
  FOCUS 明文列的 XSS 上。
- 逐條對照六個 persona 的 FOCUS，至少 7 條落在既有 persona 的明文職責
  之內，「沒有 persona 負責這個角度」對整組不成立。

另一次獨立分析（跑了 git diff 取每個檔案在該 PR 的改動行數）提出一個
解釋力更強的因子：**這個檔案在該 PR 裡的改動量排名**。該分析報告的
數字：21 條全中裡 16 條落在該 PR 的 churn 前 2 名，churn 第 6 名之後的
20 條有 50% 全漏；照觀察到的評論預算建一個均勻隨機 null，預期四輪全漏
12.0 條，實際 15 條。這組 churn 數字本文沒有逐一重算（需要 38 次
git diff，快取裡沒有 base/head SHA），以下兩個相關數字則是本文自己
重算確認的：

- 每個 PR 每輪只評到 **3.46 個相異檔案**（四輪平均再跨 PR 平均）。
- 全漏 15 條所在的 PR，該輪平均評到 3.63 個檔案；全中 21 條所在的 PR
  是 3.60 個。兩者幾乎一樣，所以不是「漏掉的那些 PR 被評得比較少」，
  是固定的三個多的名額在改動檔案多的 PR 裡分不到。

該分析還舉了一個個案：`use-list-data.ts` 這支檔案在 #148（churn 排第
29）四輪全漏，同一支檔案在 #176 被評到了，而且評的內容正是跨檔案的
同儕比對。同一批 persona、同一個系統，差別在它在該 PR 裡的改動排名。

severity 的分布本文也重算確認：CRITICAL 1/7 全漏（14%）、HIGH 4/24
（17%）、MEDIUM 10/23（43%）。MEDIUM 的全漏率是另外兩個的 2.5 倍以上。

### file_missed 不等於「reviewer 沒讀到」

`backtest_file_missed` 判的是「這個檔案裡有沒有任何一則 comment」。
判成 PASS 不會產生 comment，所以「讀了、比對過、判定沒問題」跟「完全
沒看到」在這個指標裡是同一格。本文前面就記過兩個這樣的案例：#764 的
convention-auditor 確實拿 `pricing-model-options.ts` 逐項比對過才判 PASS
（見〈兩個具體案例的追蹤結果〉），#746 的 refactoring-sage 與
security-auditor 都明確把 `$lineItemId.tsx` 標成「PASS（純 prop 傳遞）」。
這兩條在 file_missed 裡都算「完全沒被提到」。

這個限制沒辦法用現有資料繞過：run 目錄只留最終 JSON 與 `.err`，persona
的原始輸出沒有落盤。所以「persona 沒抓到」跟「persona 抓到了、synthesize
把它丟掉」目前分不出來，而這兩者的處置完全不同。

## 下一步（2026-09-01 修正版）

一、`personas-turns30-synth16-repeat` 跑完之後，除了算 file_missed 的
浮動，還要用同一套逐條明細算「同設定重跑的翻面條數」，拿去跟上面跨設定
的 7-12 條比。如果同設定重跑的翻面數也在這個量級，四輪之間的差異就完全
被浮動蓋過。

二、**留存 persona 原始輸出**。這是目前所有「persona 涵蓋度」推論的
共同盲點：分不出 persona 沒抓到還是 synthesize 丟掉。成本很低（多存
幾個檔案），但沒有它，改 persona 跟改 synthesize 的 Rule 4/5 之間無法
選擇。這一點的優先序在其他介入之前。

三、資料指向的介入方向是「檔案選取」，不是再加一個 persona。可證偽的
最小介入：讓評論的注意力與 churn 排名解耦。判準很直接：churn 第 6 名
之後那 20 條的全漏率有沒有從 50% 掉下來。

四、原本〈下一步（2026-09-01）〉第二點（補跑 2x2 第四格）與第三點
（動 convention-auditor 的 METHOD）都往後排。第四格回答的是「兩筆成本
獨立嗎」，在 file_missed 的浮動還沒量出來之前，那個問題的答案也讀不
出意義；METHOD 則是「再加一個機制」，而這一節的證據指向瓶頸不在
persona 的判準上。

## 重複執行浮動：四輪的 file_missed 差異全部在雜訊內（2026-09-01）

〈下一步（2026-09-01 修正版）〉第一點的結果。label
`personas-turns30-synth16-repeat`，跟 `personas-with-convention-auditor-turns30-synth16`
逐項對齊（6 個 persona、覆蓋清單開、persona 20 輪、convention-auditor
30 輪、synth 16 輪、容差 15、同一份 candidates_sha），什麼都沒改，只是
再跑一次。38/38 全過，沒有撞到額度。

### 彙總指標：同一組設定，兩次執行

| | 原輪 | 重跑 | 差距 |
| --- | --- | --- | --- |
| expected_total | 54 | 54 | — |
| missed | 35 | 40 | +5 |
| miss_rate | 0.65 | 0.74 | +0.09 |
| file_missed | 23 | 26 | **+3** |
| file_miss_rate | 0.43 | 0.48 | +0.05 |
| comments_total | 175 | 170 | -5 |
| unmatched | 156 | 156 | 0 |
| unmatched_rate | 0.89 | 0.92 | +0.03 |
| severity_agree | 10 | 6 | -4 |
| severity_rate | 0.53 | 0.43 | -0.10 |

missed 差 5 條，跟 `2026-layered-injection.md` 在同一個度量上量到的
4-5 條一致。severity_rate 差 10 個百分點，跟那裡量到的 16-17 個百分點
同量級。comments_total 差 5 則，跟那裡的「幾乎不變」（194 對 198，差 4）
一致。三個先前有底噪的度量，這次重跑的浮動都落在同一個量級。

**這一次重跑的 file_missed 差 3 條**（23 對 26），而四輪（24、25、26、
23）之間的全部差距也是 3 條。這是先前一直缺的那個數字，不過下一小節會
說明：總數的差異會低估真正的浮動。

### 逐條翻面：改設定跟不改設定，沒有差別

| 比較 | 只有前者命中 | 只有後者命中 | 翻面合計 |
| --- | --- | --- | --- |
| **turns30+synth16 vs 重跑（同設定）** | **7** | **4** | **11** |
| baseline vs coverage-only | 5 | 3 | 8 |
| baseline vs with-auditor | 7 | 5 | 12 |
| baseline vs turns30+synth16 | 4 | 5 | 9 |
| coverage-only vs with-auditor | 4 | 3 | 7 |
| coverage-only vs turns30+synth16 | 3 | 6 | 9 |
| with-auditor vs turns30+synth16 | 4 | 7 | 11 |

同一組設定連跑兩次，54 條裡有 11 條的檔案層級命中狀態翻面。跨設定的
六組比較是 7 到 12 條。**改變 persona 陣容、加覆蓋清單、調兩層 turn
預算，對檔案層級命中造成的變化，跟什麼都不改再跑一次沒有差別。**

### 第二組同設定資料：總數相同，底下照樣翻 8 條

`2026-layered-injection.md`〈重複執行基準線〉那組（`rules-taxonomy` 與
`rules-taxonomy-repeat`）也是同設定重複執行，快取裡還在。用同一套逐條
明細算：

| 同設定重複執行 | file_missed | 翻面條數 |
| --- | --- | --- |
| turns30+synth16 vs 其重跑 | 23 → 26（差 3） | 7 + 4 = 11 |
| rules-taxonomy vs 其重跑 | 25 → 25（差 0） | 4 + 4 = 8 |

第二組兩輪的 file_missed 完全相同，底下卻有 8 條翻面，而且剛好對稱
（4 條變命中、4 條變漏掉）。

這修正上一小節的說法：把 file_missed 的浮動說成「3 條」是不對的，那是
雙向翻面抵消之後的表象。兩組同設定資料的總數差異是 3 條與 0 條，但底層
命中狀態的浮動是 11 條與 8 條，跟跨設定六組比較的 7-12 條完全重疊。

也就是說 file_missed 這個總數不只解析度不夠，它的穩定本身是假的：兩輪
可以拿到同一個數字，而其中 15% 的條目命中狀態已經翻過面。任何用這個
總數做的前後比較，都同時受兩層問題影響（浮動本身、以及浮動被抵消後
看不出來）。

### 這推翻了什麼

前一節（〈逐條分析〉）拆出「turns30+synth16 那輪其餘 42 條少漏 3 條
（40% → 33%）、草稿那組多漏 2 條」。重跑之後：

| 輪次 | 草稿那組 | 其餘 42 條 |
| --- | --- | --- |
| baseline | 7/12（58%） | 17/42（40%） |
| turns30+synth16 | 9/12（75%） | 14/42（33%） |
| 重跑（同設定） | 9/12（75%） | 17/42（40%） |

「其餘 42 條從 40% 改善到 33%」是浮動：同設定重跑回到 40%，跟 baseline
一樣。草稿那組的 75% 在重跑裡重現（兩輪都是 9/12），沒有被反駁，但那
一組只有 12 條、只有兩輪同設定資料，樣本撐不起「這組確實惡化了」的
結論，只能說「重跑沒有推翻它」。

連帶要更正的還有本文更早的幾處判斷：

- 〈驗證：personas 路徑 synthesize 專屬 turn 上限〉說 file_missed 23
  是「四輪裡最低的一個」，當時已標注「算不算改善要等浮動量出來」。現在
  量出來了：同設定重跑的翻面是 8-11 條，23 到 26 全部在裡面，那句話
  沒有意義。
- 〈驗證：convention-auditor 專屬 turn 上限〉說 file_missed 24→26 是
  「方向錯但幅度分不出來」。現在可以說得更明確：2 條在 3 條的浮動內。
- 〈對照組〉說覆蓋清單讓 file_missed 從 24 變 25。同樣在浮動內。

也就是說，這一系列四輪加上前面兩份筆記（`2026-rule-extraction-comparison.md`、
`2026-layered-injection.md`）在 file_miss_rate 上做的所有比較，都在量
一個浮動大於效果的東西。真正站得住的是那些不受這個浮動影響的觀測：
persona 個別失敗次數（3、21、9、8，其中 21 那次逐條 stderr 都能驗證）、
PR 成功數（38/38 對 35/38）、以及每個 PR 只評到 3.46 個相異檔案這個
結構性數字。

## 下一步（2026-09-02 起）

一、**停止用 file_miss_rate 當這條線的主要指標。** 同設定重跑的底層
浮動是 8-11 條翻面，跟跨設定的 7-12 條重疊；而總數看起來只差 0-3 條，
是雙向翻面抵消出來的假穩定。要繼續用它，得先讓單輪的樣本大到
浮動佔比夠小，也就是擴大基準集，而不是繼續在 54 條上跑更多設定。

二、**留存 persona 原始輸出**（前一節第二點，維持最高優先）。這是唯一
不需要更大樣本就能拿到新資訊的方向：現在連「persona 有沒有讀到這個
檔案」都不知道，而 file_missed 已經證實無法回答這個問題（判 PASS 不
產生 comment）。

三、若要驗證「檔案選取」那個假設（每個 PR 只評到 3.46 個檔案、集中在
改動量前幾名），判準不能再用 file_miss_rate。可以直接量的是「每輪評到
的相異檔案數」與「被評到的檔案在 PR 內的改動量排名分布」，這兩個都是
單輪就能算、不受命中判定浮動影響的量。

四、基準集本身有 12 條同源條目（2 個缺陷型態、11 個 PR），佔 22%。
擴大基準集時要處理這個問題，否則單一缺陷型態的系統性表現會被放大成
12 條的變化。

## persona 抓到了，synthesize 丟掉了（2026-09-02）

> **這一節的結論已被推翻**，見下面〈更正：上一節的結論錯了，而且基準集
> 本身有問題〉。這裡的 `#764` 案例被判定為「persona 抓到了同一個缺陷」，
> 逐條比對後確認 `throwOnError` 與 `skipGlobalError` 是兩個獨立機制，
> 不是同一件事；而且那條 expected finding 在受審當下不成立。內容保留
> 當推論過程的記錄。

〈下一步（2026-09-02 起）〉第二點的機制做好之後（commit `9475013`，
`MRA_REVIEW_PERSONA_DUMP_DIR`／`MRA_BACKTEST_PERSONA_DUMP_BASE`），第一次
單 PR 試跑就撞到一個直接的反例。

### 案例：PR#764

這個 PR 是本文最前面那份 spec 追蹤的兩個原始案例之一。設定跟
`turns30+synth16` 那輪一致，6 個 persona 全部跑完（六份 `.err` 都是 0
bytes，沒有任何一個撞 turn 上限）。

最終 review JSON 只有一則 comment，落在 `device-type-picker.test.tsx`，
summary 寫著「無安全性、契約破壞或效能問題」。expected finding 所在的
`device-type-options.ts` 一則 comment 都沒有，照 `backtest_file_missed`
的判準記成 file_missed。

但 persona 的原始輸出裡，六個 persona 全部都提到了這個檔案，其中三個
各自產出了帶 severity 的 finding。convention-auditor 那條是：

> **[HIGH]** `device-type-options.ts:24` — 同樣「依 `adFormatTypeId`
> 門控」的選項 query，`pricing-model-options.ts:22-24` 與
> `media-options.ts:22-23` 都明確覆寫 `throwOnError: false`，蓋掉
> `src/lib/tanstack/query.ts` 的全域預設（403/404 會拋給 route
> errorComponent）。這支漏寫，若該格式的裝置選項 API 回 403/404，會把
> 使用者導向整頁錯誤，而非像兩個 sibling 一樣把錯誤留在對話框內處理。

對照 expected finding：

> `device-type-options.ts:22` [MEDIUM] — 選項查詢沒有標記
> `skipGlobalError`，背景載入失敗時會跳全域錯誤 toast，與呼叫端自己的
> 錯誤處理重複。

兩條講的是同一件事：這支 query 沒有覆寫全域錯誤處理（一邊寫
`skipGlobalError`、一邊寫 `throwOnError: false`，是同一個機制的兩種
說法），行號差 2，在容差 15 下算命中。persona 抓到了，而且嚴重度還報得
比 expected 高一級。

### 這推翻了什麼

本文〈兩個具體案例的追蹤結果〉當時對這個 PR 的結論是：convention-auditor
真的做了 sibling 比對，但「這次比對的維度沒有剛好覆蓋到 `skipGlobalError`
這個特定慣例」。那是在只看得到最終 JSON 的情況下做的推論。現在看得到
原始輸出，同樣的設定下它覆蓋到了，還報成 HIGH。

更要緊的是前四輪的歸因方向：新增 persona、加覆蓋清單、調 persona 層與
synthesize 層的 turn 預算，全部都在處理「persona 沒產出」這個假設。這個
案例顯示至少有一條路徑不是那樣：persona 產出了，synthesize 沒有留下來。
一條 HIGH、兩條 MEDIUM，三個 persona 各自獨立提到同一個檔案，最終 JSON
一條都沒有。

`run_synthesize` 的 prompt（`lib/review-debate-agents.sh`）有三條丟棄
規則：Rule 4「Drop any finding that does not explain scope relation,
reachable path, concrete impact」、Rule 5「Drop ... cosmetic gaps ...
unless they create a concrete reachable bug now」、Rule 7「APPROVED only
if zero CRITICAL or HIGH」。哪一條丟掉了這則 HIGH，這個案例還看不出來，
但丟棄發生在 synthesize 這一層是可以確定的。

### 這個案例能撐多少

只有一個 PR、一次執行。它證明的是「persona 抓到、synthesize 丟掉」這條
路徑真實存在，而且就發生在原始 spec 追蹤的案例上。它沒有證明的是這條
路徑佔 file_missed 的多少比例：要回答那個，得對更多 PR 做同樣的比對
（每個 PR 逐條檢查 persona 原始輸出有沒有提到 expected finding 的檔案，
再跟最終 JSON 對照）。

不過就算比例未知，這個案例已經足以說明前四輪的一個共同問題：把
file_missed 全部歸因到 persona 層，在沒有原始輸出的情況下是無法驗證的
假設，而不是觀察。

## 下一步（2026-09-02 更新）

一、跑一輪帶 `MRA_BACKTEST_PERSONA_DUMP_BASE` 的完整回測，對每一條
expected finding 做三段分類：persona 原始輸出提過且有 finding、提過但
判 PASS、完全沒提。這是第一次能把 file_missed 拆成「persona 沒看到」、
「persona 看到判沒問題」、「persona 報了但 synthesize 丟掉」三類，而
這三類要修的地方完全不同。

二、上一版〈下一步〉第三點（驗證「檔案選取」假設）維持，但判準要改：
有了原始輸出，「每個 PR 只評到 3.46 個相異檔案」這個數字要重新算一次，
因為那是從最終 JSON 算的，現在知道最終 JSON 是 synthesize 過濾後的結果，
不等於 persona 看過的範圍。

三、擴大基準集（處理 12 條同源條目）仍然需要，但排在一、二之後：先弄
清楚現有 54 條裡的漏抓各自屬於哪一類，比拿更多條目跑同一套分不出類別的
指標更有價值。

## 更正：上一節的結論錯了，而且基準集本身有問題（2026-09-02）

上一節〈persona 抓到了，synthesize 丟掉了〉的核心宣稱是錯的。對 13 個
PR（「四輪都漏」的那 15 條所在，共 18 條 expected finding）跑完帶 dump
的 review 之後，逐條做語意比對，結論翻轉。

### 先修一個會毀掉整份分析的比對錯誤

第一版分類腳本在完整路徑找不到時退回純檔名比對。這是 monorepo，
`list-actions.tsx`、`use-list-data.ts` 這種檔名在多個 feature 目錄下都
存在，結果把 persona 對「另一支同名檔案」的 finding 算成命中。修正前是
C 8 條、A 0 條，全部是誤判。改成「完整路徑優先、退回路徑後三層、不退回
裸檔名」之後才是下面的數字。

### 修正後的分佈

| 類別 | 條數 | 意義 |
| --- | --- | --- |
| C 報了但最終 JSON 沒有 | 4 | persona 對這個檔案報了 finding，被 synthesize 丟掉 |
| B 提到但沒報 finding | 6 | 有 persona 明確判 PASS |
| A 完全沒提到 | 4 | 六個 persona 的原始輸出都沒出現這個檔案 |
| HIT 這次命中 | 4 | 對照組，最終 JSON 有這個檔案 |

（C 從 5 改成 4：`#410` 那條的 security-auditor finding 主體是
`redis.service.ts`，`env.schema.ts` 只出現在括號裡的跨檔案對照引用，
分類腳本的「同一行含路徑且含 severity 標記」判準會把這種引用算成報了
finding。實際上四個 persona 都對那個檔案給了 PASS，應歸 B。）

### C 類 4 條，沒有一條是「抓到了正確答案被丟掉」

逐條比對 persona 報的內容與 expected 的缺陷，四條全部是**同一個檔案的
不同問題**，沒有一條是同一個缺陷。上一節拿來當決定性證據的 `#764` 也
不成立：

- convention-auditor 報的是這支 query 沒有覆寫 `throwOnError: false`，
  後果是 403/404 上拋給 route errorComponent、使用者看到整頁錯誤。
- expected 說的是沒有標 `meta.skipGlobalError`。

讀 PR#764 head 的 `lib/tanstack/query.ts` 可以確認這是兩個獨立機制：
`throwOnError` 決定錯誤上不上拋，`skipGlobalError` 是 `queryCache.onError`
裡的分支，管 toast 與 console。加 `throwOnError: false` 不會影響
`onError` 那條路徑，真正的修法也不是它。三條做過反向關鍵字檢查（拿
expected 的關鍵詞回頭搜六份 persona 輸出全文），`hasMonthlyRows`、
`STUDIO_URL`／`scheme`／`javascript:`、`skipGlobalError`／`toast` 全部
零命中。

synthesize 確實會丟東西，而且會丟掉標成 HIGH 的 finding（`#764` 那則
HIGH 與另一則 MEDIUM 都沒進最終 JSON，`#145`、`#410` 也各有整個檔案的
finding 消失）。但這 18 條裡沒有一條能證明它丟掉的是正確答案。

### 更根本的問題：基準集有無效條目

比對過程中去核對了受審 PR 的 head 版本與修 bug 的 commit，10 條詳查的
條目裡有 5 條的 expected finding 站不住：

| 條目 | 問題 |
| --- | --- |
| `#410` `env.schema.ts:41` | 這一行 PR#410 一個字都沒改（是更早的 commit `9f66825b` 引入），修 bug 的 commit 是 12 天後獨立提的安全性收緊 |
| `#764` `device-type-options.ts:22` | expected 描述的「會跳全域錯誤 toast」在受審當下不成立：當時的 `onError` 只有標了 `errorToast` 才跳 toast，這支沒標，失敗只會 `console.error`。是修 bug 那個 commit 自己重寫 `onError` 才讓 `skipGlobalError` 變必要 |
| `#746` `$lineItemId.tsx:395` | note 說的 `useLineItemDetailDraft()` 沒帶 id 在第 251 行，PR#746 沒碰那行；第 395 行的實際內容是一個 `<div className=...>` |
| `#750` `$lineItemId.tsx:411` | 同上，第 411 行是 `onCostEffectiveTrafficChange={...}` |
| `#791` `line-item-setting-checklist.tsx:32` | note 描述的 `isPending` 回 `undefined` 是**另一個檔案**（`line-item-audience-targeting-section.tsx`）的缺陷 |

成因是 `candidates.json` 的建構方式：拿 fix commit 的 hunk 範圍去跟受審
PR 的改動範圍取行號交集。行號交集不等於「同一個缺陷在這個 PR 裡就存
在」，也不保證交集算出來的那一行就是缺陷所在。`#746`／`#750` 是最清楚
的例子：fix commit 有好幾個 hunk，真正改 draft hook 的那個沒有跟 PR 相
交，相交的是別的 hunk，於是行號落在無關的位置上。

### 這對前面幾節的意義

四輪都打不破 file_miss_rate 天花板，現在多一個候選解釋：有一部分「漏
抓」是不可能抓到的。PR 沒改那一行、或缺陷在受審當下還不存在，任何
reviewer 都不該報。詳查的 10 條裡佔 5 條，但這 10 條是刻意挑「四輪都
漏」的難例，不能直接外推到 54 條的比例。

也要收回上一節那句「前四輪的歸因方向錯了」的說法：那是建立在 `#764`
是 C1 的判斷上，而 `#764` 已確認是 C2。前四輪的歸因是不是錯的，這份
資料回答不了。

### 這一輪能站住的

1. 三類的機制都真實存在，而且可以分辨了：A（沒提到）、B（提到判 PASS）、
   C（報了被丟掉）在 18 條裡分別是 4、6、4 條。這是先前拿不到的資訊。
2. synthesize 會丟掉 HIGH 等級的 finding，有多個案例。丟的是不是正確
   答案，這批資料回答不了。
3. 基準集有無效條目，成因（行號交集）可以驗證，也可以修。
4. A 類 4 條裡，`#785`、`#791` 所在的 PR 有一個 persona（test-architect）
   撞 `max turns (20)` 掛掉，輸出只有 29 bytes。這 13 個 PR 裡有 3 個
   出現同一個狀況，跟前四輪觀察到的 test-architect 失敗率一致。

## 下一步（2026-09-02 第二次更新）

一、**先修基準集，再談任何漏抓率**。`candidates.json` 的行號交集法會產
出「PR 沒改過那行」與「缺陷當下不存在」兩類無效條目。可驗證的修法：對
每條 expected finding 檢查它的 path 與 line 是否落在該 PR 的實際 diff
hunk 內，落不進去的標記出來。這是純程式檢查，不用跑任何 review。

二、上一節列的「跑完整 38 個 PR 帶 dump」往後排。在基準集的無效條目
清掉之前，跑更大樣本只會得到更多無法解讀的數字。

三、`test-architect` 在 20 輪下的失敗率是這份資料裡少數乾淨的訊號
（13 個 PR 裡 3 個），可以比照 convention-auditor 給它獨立的 turn 上限，
判準是它的個別失敗次數，不牽涉 file_miss_rate。
