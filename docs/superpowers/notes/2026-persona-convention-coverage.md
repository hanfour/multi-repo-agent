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

## 基準集的行號檢查：問題比上一節說的小，但方向反過來也有問題（2026-09-02）

上一節〈下一步〉第一點：對每條 expected finding 檢查它的 path 與 line
是否落在該 PR 的實際 diff 內。純程式檢查，不跑 review，不用模型額度。

做法是用 GitHub 的 PR files API 拿每個檔案的 patch，解析 hunk 標頭
（`@@ -a,b +c,d @@`）取新版行號區間，再看 expected 的 line 落不落在裡面。
判準是寬鬆的：hunk 標頭的範圍含 context 行，也就是把「沒被改、只是顯示
在 diff 裡」的行也算進去，所以「不在裡面」的判定偏保守。

### 結果

54 條裡 44 條落在 diff hunk 內，10 條（19%）不在。

但這 10 條要對照回測的容差 15 才有意義：reviewer 報最接近的改動行，只要
距離不超過 15 就會被算成命中。

| 條目 | 距最近改動區間 | 容差 15 下 |
| --- | --- | --- |
| `#150` list-actions.tsx:192 | 1 行 | 仍可能命中 |
| `#153` list-actions.tsx:192 | 1 行 | 仍可能命中 |
| `#176` list-actions.tsx:175 | 1 行 | 仍可能命中 |
| `#866` $lineItemId.tsx:380 | 1 行 | 仍可能命中 |
| `#817` $lineItemId.tsx:125 | 3 行 | 仍可能命中 |
| `#201` adjustment-types.tsx:52 | 4 行 | 仍可能命中 |
| `#410` env.schema.ts:41 | 6 行 | 仍可能命中 |
| `#813` use-cross-channel-tracker-form.ts:19 | 7 行 | 仍可能命中 |
| `#760` update-line-item.use-case.ts:72 | 8 行 | 仍可能命中 |
| `#743` $lineItemId.tsx:390 | 17 行 | 超出容差 |

只有 1 條真的因為行號落點而無法命中。四條只差 1 行，多半是 hunk 邊界的
算法差異，不是實質問題。

### 這修正上一節的一句話

上一節說「天花板多一個候選解釋：有一部分漏抓是不可能抓到的」。從行號
落點這個角度看，54 條裡只有 1 條符合，撐不起「一部分」這個講法。要收回。

上一節逐條詳查找到的問題仍然成立，但那些是語意層面的：`#764` 的缺陷在
受審當下不成立（是修 bug 的 commit 自己改了 `onError` 才讓它成立）、
`#791` 的 note 描述的是另一個檔案的缺陷、`#746`／`#750` 的行號落在與
note 無關的內容上。這幾條的 line 都落在 diff hunk 內，程式檢查抓不到，
只有逐條讀 PR head 與 fix commit 才看得出來。

### 反方向的問題：容差也會讓報錯東西算成命中

`#410` 是最清楚的例子。expected 指的是第 41 行的 `STUDIO_URL` 沒限制
scheme，而 PR#410 改的是第 47-57 行（新增 `SLACK_WEBHOOK` 等環境變數），
距離 6 行。reviewer 只要對 PR 真正改的那幾行報任何 finding，就會落進
容差 15 的範圍被算成「命中了 `STUDIO_URL` 那條」。

也就是說容差同時放寬兩個方向：expected 行號不精確時仍算命中（本來的
用意），以及 reviewer 報了鄰近的別的問題也算命中（副作用）。前者讓
miss_rate 偏低，後者也讓 miss_rate 偏低，兩者都不會被現有指標分辨。

`2026-layered-injection.md` 記過容差 5 與容差 15 的數字差很多
（miss_rate 0.85 對 0.69）。當時的解讀是容差 5 太嚴、錨點漂移被誤判成
漏抓。現在多一個角度：容差 15 也可能把「報了鄰近的別的問題」算成命中。
兩個容差都不是乾淨的判準，中間那段差距混了兩種相反的誤判。

## 下一步（2026-09-02 第三次更新）

一、`#743` 那條（距離 17 行、超出容差）可以直接從基準集標記為無效，或
把行號修到 fix commit 真正改的位置。這是唯一一條能純程式判定的。

二、驗證「容差把報錯東西算成命中」這個副作用有多常見：對命中的條目，
逐條檢查 reviewer 報的內容跟 expected 的 note 是不是同一件事。這需要
語意判斷（跟上一節對 C 類做的一樣），不是程式能做的，但可以先從容差
邊緣的條目（expected line 不在 diff 內、靠鄰近改動行命中的那幾條）開始，
樣本小。

三、上一節列的「先修基準集再談漏抓率」要調整：行號層面的問題只有 1 條，
不值得為它停下整條線。真正該處理的是語意層面的無效條目，而那個沒有
程式判準，只能逐條讀。以 10 條詳查裡有 4 條有語意問題的比例來看，這件
事的規模可能不小，但也不能拿 10 條難例的比例去推 54 條。

## synthesize 丟掉了什麼：兩個模型交叉驗證（2026-09-02）

前面幾節反覆出現同一個問題：單一模型（包括本文作者）的語意判斷被推翻
了四次。這一輪改成兩個模型拿**完全相同的輸入與判準**獨立判斷，再比對
一致性，一致率本身當作這次量測的可信度指標。

### 方法

要回答的問題：persona 報了 finding、最終 JSON 沒有，是「被合併」還是
「被丟棄」。這兩件事意義相反：

- **D 被合併**：最終 JSON 有另一條講同一件事。6 個 persona 平行跑，重複
  是常態，合併正是 synthesize 該做的。
- **L 被丟棄**：最終 JSON 沒有任何一條涵蓋這件事。

流程分三段：

1. 程式產出標準化輸入（每個 PR 一份 JSON，含 persona findings 與最終
   comments，各自編號）。
2. Claude Opus 與 codex（`gpt-5.6-luna`）拿同一份輸入與同一份判準檔，
   獨立逐條判斷，輸出格式固定為 `<P編號>|<D或L>|<對應F編號>|<理由>`。
3. 程式比對兩邊，一致的採用，分歧的人工裁決。

放大之前先用一個 PR 校準：6 條判斷兩邊 100% 一致，連對應的 F 編號都
相同，而理由措辭不同（確認是獨立判斷不是巧合）。校準通過才跑其餘 12 個。

### 一致率

13 個 PR、116 條共同判斷，**一致 115 條（99%），分歧 1 條**。判準沒有
明顯的模糊地帶，下面的數字可以當數字看。

### 先修一個抽取雜訊

第一版把「含 severity 標記的行」全部當成 finding，其中有 13 條其實是
coverage checklist 的交叉引用（形如「見上方 [HIGH] 發現」），不是獨立
finding。改成「severity 標記要出現在行首附近」之後是 109 條。那 13 條
原本 9 條判 D、3 條判 L，符合預期。

### 結果

| severity | finding 數 | 被合併 D | 被丟棄 L | 丟棄率 |
| --- | --- | --- | --- | --- |
| CRITICAL | 9 | 7 | 2 | 22% |
| HIGH | 33 | 25 | 8 | 24% |
| MEDIUM | 67 | 34 | 33 | 49% |
| 合計 | 109 | 66 | 43 | 39% |

### 這推翻了本文前面一個觀察

用「最終 JSON 條數除以 persona finding 條數」當保留率，算出來是 HIGH
41%、MEDIUM 50%，當時的解讀是「HIGH 保留率比 MEDIUM 低，跟 Rule 7 的
意圖相反」。那個算法沒有扣掉「多條 persona finding 合併成一條最終
comment」，而重要問題本來就更容易被多個 persona 同時報到，重複率更高。

逐條做 D／L 區分之後，MEDIUM 的丟棄率（49%）是 HIGH（24%）的兩倍，跟
`run_synthesize` 的 Rule 5（丟掉 cosmetic gaps）方向一致。**synthesize
的丟棄行為大致符合它自己的設計意圖**，先前那個「異常」是算法造成的
假象。

### 還是有 10 條 CRITICAL/HIGH 完全消失

兩個模型都判定被丟棄的 CRITICAL 有 2 條、HIGH 有 8 條。其中 8 條集中在
同一個 PR（`#176`：persona 報 15 條、最終只留 3 條），另外幾條分散。

這 10 條是目前唯一有直接證據、規模明確、可以指名道姓的問題。要不要動
Rule 4／5 的措辭，判準就是這個數字，而且改完可以用同一套流程重測，完全
不需要碰基準集或 file_miss_rate。

### 這個流程本身

多模型交叉驗證這件事，成本比想像中低：13 個 PR 兩邊各跑一次，codex 側
約 20 分鐘（逐 PR 序列），Claude 側三個 agent 平行約 4 分鐘。換到的是
99% 一致率這個可信度背書，以及一個不依賴基準集、單輪就能算的指標。

跟本文前面幾節對照，差別很明顯：靠 file_miss_rate 跑了四輪回測、每輪
數小時，最後證實那個指標的浮動大於效果；這一輪用既有的 13 個 PR dump，
沒有再跑任何 review，得到的數字兩個模型互相背書。

## 下一步（2026-09-02 第四次更新）

一、那 10 條被丟棄的 CRITICAL/HIGH 逐條看，判斷 synthesize 丟得對不對。
如果多數丟得有道理（例如確實不符合 Rule 4 要求的 scope／reachable path
／impact），那 synthesize 沒問題，這條線可以收；如果多數丟錯，Rule 4／5
的措辭就是明確的修改目標。這一步同樣可以用兩個模型交叉驗證。

二、`#176` 一個 PR 就佔了 8 條，值得單獨看：是那個 PR 的 persona 產出
特別冗餘，還是 synthesize 在輸入量大時會過度收斂。這個問題用現有 dump
就能回答。

三、`test-architect` 的獨立 turn 上限維持在清單上（13 個 PR 撞頂 3 次），
跟上面兩點無關，可以並行處理。

## synthesize 丟得對不對：規模是 2 條，這條線可以收（2026-09-02）

上一節〈下一步〉第一點。對兩個模型都判定「完全被丟棄」的 10 條
CRITICAL／HIGH，判斷 synthesize 丟掉它們符不符合它自己被賦予的規則。
判準直接引用 `run_synthesize` prompt 裡的 Rule 1 到 7 原文，不另外發明
標準。一樣是兩個模型拿相同輸入獨立判斷。

### 一致率掉到 80%，這本身是結論

| 判斷任務 | 一致率 |
| --- | --- |
| 「這兩條是不是同一件事」（上一節） | 99%（116 條分歧 1 條） |
| 「符不符合 Rule 4／5 的丟棄條件」（這一節） | 80%（10 條分歧 2 條） |

同樣兩個模型、同樣的流程，判斷「是不是同一件事」幾乎不會分歧，判斷
「符不符合 Rule 4／5」則有五分之一分歧。兩條分歧的爭點都落在 Rule 5 的
`unless they create a concrete reachable bug now`：死碼算不算「當下可達
的 bug」、重複邏輯裡少一個 undefined 保護算不算。

Rule 4／5 的措辭在實務上有模糊地帶，這是可量到的。

### 裁決與結果

兩條分歧由人工裁決：

- `764-P1`（新增的 Picker 沒註冊進 `TARGETING_DIMENSIONS`、目錄下無非
  測試引用、畫面觸發不到）判 **U**。它把 scope、證據、影響都講清楚了，
  符合 Rule 4；Rule 5 的 `missing future features` 不適用，這不是「缺少
  未來功能」，是「這個 PR 要交付的功能沒接上」。
- `791-P3`（兩段 filter 邏輯重複，其中一段少 undefined 保護）判 **J**。
  主體是 Extract Function 的重構建議，原文只寫「未做同樣的檢查」，沒有
  論證那條路徑何時可達，命中 Rule 4 的丟棄條件。

最終：**丟得對 8 條、丟錯 2 條**。

### 丟錯的 2 條都在同一個 PR

`#764` 的兩條 HIGH：

1. 新增的 `DeviceTypePicker`／query 沒有註冊進維度清單，整個目錄下沒有
   非測試檔引用，畫面上觸發不到。
2. 這支 query 沒有覆寫 `throwOnError: false`，兩個 sibling 都有覆寫；
   403／404 會把使用者導向整頁錯誤，而不是留在對話框內處理。

兩條都在講「這個 PR 交付的東西有問題」。而該 PR 最終保留下來的唯一一條
comment，是一則「缺少 open→close→open 的測試」的建議。

### 這條線可以收了

以 109 條 persona finding 為分母，synthesize 丟錯的規模是 **2 條
（1.8%）**。它的丟棄行為整體符合自己的規則，MEDIUM 丟得多、CRITICAL／
HIGH 丟得少（22%／24% 對 49%），方向跟 Rule 5 一致。

先前幾節懷疑 synthesize 是主要瓶頸（〈persona 抓到了，synthesize 丟掉
了〉那一節甚至把它當成推翻前四輪的證據），現在有了規模：不是主要瓶頸。
兩條丟錯值得修，但那是 1.8% 的問題，不是天花板的成因。

回到三類分佈（A 沒提到 4 條、B 提到判 PASS 6 條、C 報了被丟掉 4 條），
C 類這條路已經走完，而且 C 類的 4 條沒有一條是「抓到 expected 被丟掉」。
剩下的問題在 A 與 B：persona 沒看到那個檔案，或看到了但判沒問題。

## 下一步（2026-09-02 第五次更新）

一、主戰場移到 B 類（提到了但判 PASS，6 條）。這是三類裡最大的一類，
而且性質最明確：persona 讀了那個檔案、做了判斷、判成沒問題。要問的是
判準為什麼沒涵蓋。這可以用同一套交叉驗證流程：把 expected 的缺陷描述
與該 persona 的 PASS 理由並排，判斷是判準沒涵蓋、還是那條 expected
本身站不住（前面已經確認基準集有語意層面的無效條目）。

二、A 類（完全沒提到，4 條）要先扣掉 persona 掛掉的情況：`#785`、
`#791` 所在的 PR 都有 `test-architect` 撞 `max turns (20)`，那不是
「注意力沒到」而是「跑不完」。扣掉之後 A 類還剩多少要重算。

三、`764-P1`／`764-P2` 這兩條 synthesize 丟錯的，可以當成改 Rule 4／5
措辭的迴歸案例：任何改動之後，這兩條要能被保留下來，而原本判 J 的 8 條
不能因此變成保留。這是一個小而明確的驗證集，不依賴基準集。

四、Rule 4／5 的模糊地帶（兩個模型 80% 一致）本身值得處理。最小的修法
是把 `concrete reachable bug now` 這個條件寫清楚：死碼算不算、少一個
防禦性檢查算不算。改完可以用同一批 10 條重測一致率，一致率上升就是
措辭變清楚的證據。

## B 類全部是無效條目：天花板可能一直在量基準集的雜質（2026-09-02）

上一節〈下一步〉第一點。B 類是「persona 提到了那個檔案、判成 PASS、
沒報 finding」的 5 條。要分辨三種原因：N（六個 persona 的判準都沒涵蓋
這個性質）、I（這條 expected 本身站不住）、M（判準涵蓋了但漏判）。

兩個模型拿相同判準與輸入獨立判斷，並要求實際查證受審 repo 的程式碼。

### 結果：兩邊 100% 一致，5 條全部是 I

| 條目 | 查證到的事實 |
| --- | --- |
| `#145` return-dialog.test.tsx | note 說 hook 的欄位是 `isReturning`，但受審當下是 `isLoading`，mock 完全正確。改名發生在該 PR 合併後 3 天 |
| `#183` external-return-flow.spec.ts | note 說 fixture 缺 `externalAdFormatName`，但那個欄位是該 PR 合併後約 6 小時才建立的。fixture 不可能缺一個當時還不存在的欄位 |
| `#746` $lineItemId.tsx | 指的第 395 行是未改動的 context 行；note 描述的 hook 呼叫在第 241 行，PR base 就存在，這個 PR 一個字都沒動 |
| `#750` $lineItemId.tsx | 同上形態。第 411 行未改動（只有 412 被加），hook 呼叫在第 252 行 |
| `#791` line-item-setting-checklist.tsx | note 描述的 `isPending` 缺陷在**另一個檔案**。`isPending` 從未出現在被指的這個檔案的任何歷史版本 |

N=0、M=0。沒有一條是「判準沒涵蓋」或「該抓而沒抓到」。

### 一個系統性的產生方式

其中三條（`#746`、`#750`、`#791`）共享同一個失敗模式：expected 的
`path:line` 是從 fix commit 的 hunk 位置反推、再映射到受審 PR 的檔案上，
結果落在無關的未改動程式碼，甚至落到另一個檔案。

另外兩條（`#145`、`#183`）是時序問題：缺陷描述的對象在受審當下還不存在，
是後續改動才讓它成立的。

前者可以用程式檢查（引用的行必須落在受審 PR 的改動 hunk 內，而且 note
的主體要真的在那一行）。後者不行，需要比對 fix commit 與受審 PR 的時間
與內容。

### 把 13 個 PR 的圖景拼起來

| 類別 | 條數 | 追查結果 |
| --- | --- | --- |
| HIT 這次命中 | 4 | 對照組 |
| C 報了被丟掉 | 4 | 沒有一條是「抓到 expected 被丟掉」；詳查時另外發現 `#410`、`#764` 的 expected 也站不住 |
| B 提到判 PASS | 5 | 全部是 expected 站不住 |
| A 完全沒提到 | 4 | 其中 2 條所在的 PR 有 persona 撞 `max turns (20)` |

這 18 條裡，已經逐條查證確認站不住的至少 7 條（B 類 5 條加上 `#410`、
`#764`），約 39%。

### 這對天花板的意義

`2026-rule-extraction-comparison.md`、`2026-layered-injection.md` 與本文
前面四輪，都在推同一個數字：file_miss_rate 卡在 0.44 到 0.48。換過規則
注入方式、換過 persona 陣容、換過 prompt 要求、調過兩層 turn 預算，都推
不動。

現在有一個先前沒考慮過的解釋：**那個數字裡有相當比例的分母，本來就不該
被抓到**。這 13 個 PR 正是「四輪都漏」的難例，而逐條查下來，它們四輪都
漏的原因，很大一部分是它們不是真的缺陷。

這個解釋要謹慎看待兩件事。第一，13 個 PR 是刻意挑的難例，39% 這個比例
不能外推到 54 條，容易命中的那些條目品質可能好得多。第二，這不代表
reviewer 沒有問題，A 類與 C 類仍然存在，只是規模比原本以為的小。

但方向很明確：在基準集的無效條目被清掉之前，file_miss_rate 這個數字沒有
辦法用來判斷任何改動的好壞，而這一系列已經在它上面花了六輪回測。

## 下一步（2026-09-02 第六次更新）

一、**把基準集的無效條目清掉，然後重算前面幾輪的數字**。所有 review
輸出都還在快取裡（六輪、每輪 38 個 PR），清完分母重算不需要跑任何新的
review。這是目前投入產出比最高的一件事：它可能讓前六輪已經花掉的成本
變得可解讀。

清理分兩步：程式能判的（引用的行不在受審 PR 的改動 hunk 內）先標出來，
前面〈基準集的行號檢查〉已經找到 10 條；程式判不了的（時序問題、note
主體在別的檔案）需要逐條查，可以用這一節的兩模型交叉驗證流程，成本是
每條約一分鐘。

二、A 類要重算：先扣掉 persona 撞 `max turns` 的情況（那不是注意力問題
是跑不完），再看剩下幾條，以及那幾條的 expected 站不站得住。

三、`test-architect` 沒有 FOCUS 錨點是專案已知且刻意保留的事實
（`tests/test_run_rule_backtest.sh` 有斷言）。這一輪不影響判斷，因為 5 條
都在 I 階段就解決了；但如果之後要判 N 與 M 的分野，少了它的職責定義會讓
判斷不可靠，屆時要用 `agents/personas/test-architect.md` 的內容補上。

## 清理基準集：天花板是無效條目撐出來的（2026-09-02）

上一節〈下一步〉第一點。對 54 條 expected finding 全部做有效性查證，
再用六輪既有的 review 輸出重算分母。重算不需要跑任何新的 review。

### 查證方式與一個先踩到的坑

第一版想用純程式篩：「note 裡提到的識別字，在受審 PR head 的那個檔案裡
不存在」就標為可疑。這個判準是反的。expected finding 最常見的形態就是
「缺少某個東西」（沒標 `skipGlobalError`、route 沒有 `beforeLoad`），那個
識別字找不到正是缺陷本身。54 條裡被這個篩子標出 21 條，多數是偽陽性。

真正的訊號方向相反：note 引用某個識別字來**描述現況**（「實際 hook 的
欄位是 `isReturning`」、「`isPending` 直接回 undefined」），而那個識別字
在受審當下的檔案裡不存在。這需要語意判斷，程式做不了。

改成模型逐條查證，判準寫明這個陷阱，並要求實際用 `git show <head_sha>:
<path>` 讀受審版本、用 `git log -L` 追行的歷史。

### 結果

54 條裡**有效 20 條、無效 34 條（63%）**。無效的形態分佈：

| 形態 | 條數 | 說明 |
| --- | --- | --- |
| TIME 時序錯置 | 17 | 缺陷在受審當下還不存在，是後來的改動才讓它成立 |
| LINE 行號錯位 | 10 | 引用的行是未改動的 context，note 的主體在檔案別處或別的檔案 |
| OTHER | 2 | note 描述的缺陷實際上不存在（例如它說沒有失效查詢，實際上有） |

時序錯置是最大宗，而這種程式抓不到，要比對 fix commit 與受審 PR 的時間
與內容。幾個具體例子：某條說 mock 的欄位與 hook 介面不符，但受審當下
兩者完全一致，改名發生在合併後 3 天；某條說 e2e fixture 缺一個欄位，
而那個欄位是合併後 6 小時才建立的。

### 重算：那個天花板不存在

用 20 條有效條目重算九輪（含兩份更早筆記的三輪）：

| 輪次 | 原 file_miss_rate | 清理後 |
| --- | --- | --- |
| baseline-personas | 0.44 | 0.25 |
| with-convention-auditor | 0.48 | 0.30 |
| turns30 | 0.48 | 0.15 |
| turns30+synth16 | 0.43 | 0.15 |
| repeat（同設定重跑） | 0.48 | 0.25 |
| coverage-checklist-only | 0.47 | 0.25 |
| rules-taxonomy | 0.46 | 0.20 |
| rules-taxonomy-repeat | 0.46 | 0.20 |
| taxonomy-layered | 0.48 | 0.15 |

`2026-rule-extraction-comparison.md`、`2026-layered-injection.md` 與本文
一路推不動的「0.44 到 0.48」，是分母裡 63% 的無效條目撐出來的。那些條目
不管換什麼設定都會被算成漏抓，因為它們本來就不該被抓到，於是把所有輪次
的數字都拉到同一個區間，看起來像天花板。

清理後的數字落在 0.15 到 0.30，不再擠在一起。

### 這個結果的三個限制

第一，**交叉驗證已完成**（這一段原本寫「目前是單邊判斷」，codex 側跑完
之後更新）。49 條裡兩邊一致 44 條（90%），分歧 5 條。五條分歧逐條查證
程式碼裁決，結果都是 Claude 側正確：

- `#150` 引用第 192 行，但該檔案在受審 head 只有 191 行，而且全檔沒有
  任何 `subsidiar` 字樣。
- `#813` 引用第 19 行（函式簽章結尾）雖然不精確，但缺陷成因
  （`canSubmitWhenInvalid`、`validationLogic` 設定）落在該 PR 改動的
  [26,32] 內，距離 7 行、在容差 15 內。判有效。
- `#744`、`#752` 的兩條「草稿」相關：受審 head 的元件同時有
  `key={detailQuery.data.id}`（切明細時重掛）與卸載 cleanup 的
  `actions.reset()`，兩道保護讓「切到另一筆會看到上一筆草稿」在當下不
  成立；那是後來把 reset 搬到 route `onLeave` 才出現的。
- `#752` 的追蹤碼那條：受審 head 的 `update-line-item.ts` 完全沒有
  `applyTrackingDefaults` 相關內容，note 描述的功能當下不在這個 mutation
  裡。

五條分歧有三條集中在「草稿」那組，爭點都是「這個缺陷在受審當下成不成
立」，而要判準這件事得先看出當時有哪些保護機制。加上 B 類先前那 5 條
（雙模型 100% 一致），54 條的判定全部有交叉驗證背書。

第二，**清理後樣本只剩 20 條，浮動會更大**。同設定重跑那組是 0.15 對
0.25，差 2 條就是 10 個百分點。用這個分母比較不同設定，需要重新量浮動。

第三，**63% 這個比例是這個基準集的性質，不是通則**。它來自「拿 fix
commit 的 hunk 行號範圍跟受審 PR 的改動範圍取交集」這一種產生方式，換
一種建構方式的基準集不會有同樣的問題。

## 下一步（2026-09-02 第七次更新）

一、~~等 codex 側查證完成，比對一致率~~。已完成：49 條一致 44（90%），
5 條分歧逐條裁決後全部是 Claude 側正確。清理結果定案。

二、`candidates.json` 要實際落地清理（標記或移除那 34 條），
並把「引用的行必須落在受審 PR 的改動 hunk 內」寫成 `build-benchmark.sh`
的產生時檢查，擋掉 LINE 那一類。TIME 那一類擋不掉，只能在產生時比對
fix commit 與受審 PR 的時間差，或接受它並在解讀時扣掉。

三、清理後的分母只有 20 條，要擴大基準集才能繼續用它比較設定。擴大時
沿用新的產生時檢查，避免再長出同樣的無效條目。

## 落地：排除機制與時序警告（2026-09-02）

上一節〈下一步〉第二點。清理結果定案之後，把它變成可重複執行的機制。

### 排除清單為什麼不寫進 candidates.json

`candidates_effective_sha` 涵蓋 `confirmed==true` 項目的
`expected_findings`（見 `run-backtest.sh` 對這個欄位的說明）。在條目上加
`invalid` 標記、或直接移除那 34 條，都會讓這個指紋變動，既有九輪的
summary 就對不上，那些輪次全部失去可比性。

改成獨立清單 `$BENCH_DIR/expected-exclusions.json`，由 `run-backtest.sh`
在取 `expected_findings` 之後依 `(repo, pr, path, line)` 過濾。清單本身
放 cache 目錄不進版控，因為它含內部 repo 的 PR 編號與檔案路徑；repo 裡
只有讀取機制。測試裡有一條專門釘「排除機制不改動
candidates_effective_sha」。

預設關閉，要設 `MRA_BACKTEST_APPLY_EXCLUSIONS=1` 才生效。理由是套用之後
的分母跟先前的輪次不是同一個，不該在使用者沒察覺的情況下換掉。
`summary.json` 記 `exclusions_applied` 與 `excluded_count`，任何一份
summary 都看得出自己用的是哪個版本的分母。

### 九輪重算的完整對照

用 `--recompute` 重算（不跑任何 review，秒級完成）：

| 輪次 | miss 原 | miss 清理後 | file 原 | file 清理後 |
| --- | --- | --- | --- | --- |
| baseline-personas | 0.69 | 0.40 | 0.44 | 0.25 |
| with-convention-auditor | 0.67 | 0.45 | 0.48 | 0.30 |
| turns30 | 0.66 | 0.35 | 0.48 | 0.15 |
| turns30+synth16 | 0.65 | 0.35 | 0.43 | 0.15 |
| turns30+synth16 重跑（同設定） | 0.74 | 0.45 | 0.48 | 0.25 |
| coverage-checklist-only | 0.72 | 0.40 | 0.47 | 0.25 |
| rules-taxonomy | 0.69 | 0.40 | — | 0.20 |
| rules-taxonomy 重跑（同設定） | 0.70 | 0.40 | 0.46 | 0.20 |
| taxonomy-layered | 0.69 | 0.35 | 0.48 | 0.15 |

原始 summary 都保留（`summary-tol15.json`、`summary-tol5.json`），清理版
另存為 `summary-cleaned-tol15.json`，兩邊都查得到。

**但這張表不能拿來比較設定**。看同設定重跑那兩組：`turns30+synth16` 對
它自己的重跑，清理後是 0.35 對 0.45（miss）、0.15 對 0.25（file）；
`rules-taxonomy` 對它自己的重跑則是 0.40 對 0.40、0.20 對 0.20。前者差 2
條就是 10 個百分點，因為分母只剩 20 條。清理讓數字更誠實，沒有讓它變得
更能分辨設定差異，反而因為分母變小、單條的權重變重。

### 時序警告

行號那一類（12 條）`review-benchmark.sh --add` 早就有 `LINE_OUTSIDE_DIFF`
警告，而且它的註解裡就寫著「實測 54 條裡有 10 條是這樣」，跟這次算出來
的數字一致。所以這次只補時序那一類。

時間差量得出鑑別度：無效條目的最早 fix commit 中位落在 PR 合併後 6.2 天，
有效條目是 0.9 天。用 3 天當門檻，68% 的無效條目會被點名、25% 的有效條目
會被誤報。跟 `LINE_OUTSIDE_DIFF` 同樣只警告不擋：缺陷確實可能潛伏很久才
被修，那種條目是有效的。

## 下一步（2026-09-02 第八次更新）

一、擴大基準集。清理後只剩 20 條，單條權重 5 個百分點，任何設定比較都會
被浮動蓋過。擴大時新的兩道警告（`LINE_OUTSIDE_DIFF`、`FIX_LONG_AFTER_MERGE`）
會在標註當下就提醒，但它們只警告不擋，最終還是要人看過。

二、清理後的分母重新量一次浮動。先前量的「同設定重跑翻面 8-11 條」是在
54 條分母上量的，20 條分母的浮動要重量才知道。

三、`#764` 那兩條 synthesize 丟錯的（新功能沒接上 registry、query 沒覆寫
`throwOnError`）仍在清單上，是改 Rule 4／5 措辭時的迴歸案例。

## 產生方式的根因：行號交集沒有因果，blame 歸因有（2026-09-02）

上一節〈下一步〉第一點。擴大基準集之前先回頭看：63% 無效條目是怎麼從
產生器長出來的，不然擴大只是等比例多出無效條目。

### 現行產生方式的兩個缺陷

`build-benchmark.sh` 的判定是「fix commit 的 hunk 行號區間 × 受審 PR 的
改動區間取交集」（`backtest_overlap`）。這有兩個問題：

第一，兩邊的行號不在同一個座標系。`pr_range` 是 PR head 那個版本的行號，
`fix_range` 是 fix commit 新檔側的行號，中間任何一次改動都會讓兩者錯開。
交集算出來的數字看起來精確，實際上比的是兩個不同版本的檔案。

第二，交集只證明「兩者改到同一區域」，沒證明「fix 修的是 PR 寫的東西」。
最具體的例子：fix `4518e2af` 一個 commit 改了 `$lineItemId.tsx`，用交集跟
5 個 PR（`#743`、`#746`、`#750`、`#780`、`#866`）都對上，5 條 expected
全部在無效清單裡。同一個 fix 不可能同時是 5 個 PR 各自引入的缺陷。

### 改用 blame 歸因

對 fix commit 每個 hunk 的舊檔側被改行，在 `fix^1` 上 `git blame -w`，看
指到的 commit 屬不屬於受審 PR（squash 合併就是 merge commit 本身，merge
合併就是 `mc^1..mc` 那段的所有 commit）。純新增的 hunk 沒有舊行可 blame，
改 blame 插入點上下兩行當錨點。歸因比例 = 指到 PR 的行數 ÷ hunk 被改行數。

這跟缺陷溯源的 SZZ 方法是同一個想法：問「這行是誰寫的」，而不是「這行
在不在某個數字區間裡」。座標系問題也跟著消失，blame 本來就跨版本。

### 對 54 條的回測

用人工查證定案的 V／X 當答案，看各種篩法留下多少 V、擋掉多少 X：

| 篩法 | V 留（/20） | X 擋（/34） | 精確率 | TIME | LINE | OTHER |
| --- | --- | --- | --- | --- | --- | --- |
| 現行（交集） | 20 | 0 | 0.37 | 0/19 | 0/12 | 0/3 |
| blame ≥ 0.5 | 17 | 20 | 0.55 | 8/19 | 11/12 | 1/3 |
| blame ≥ 0.5 且 fix 距合併 ≤ 5 天 | 15 | 28 | 0.71 | 14/19 | 12/12 | 2/3 |
| blame ≥ 0.5 且 ≤ 3 天 | 12 | 29 | 0.71 | 15/19 | 12/12 | 2/3 |

「blame ≥ 0.5」指 expected 所在檔案 ±15 行內任一 fix hunk 的歸因比例
達 0.5。精確率是 V ÷（V + 漏掉的 X）。

LINE 那一類 blame 幾乎全擋（11-12/12），這是預期中的：fix 改的是 PR 沒寫
過的 context 行，blame 指到別的 commit。TIME 那一類只擋一半（8/19），加上
5 天門檻才到 14/19。

blame 誤擋的 3 條 V：`#4900` `.drone.yml`（fix 在 PR 新增區塊的後面再加一
段，錨點行不是 PR 寫的）、`#813`（裁決時靠容差判有效的那條）、`#201`
`adjustment-types.tsx:52`。5 天門檻再誤擋 2 條：`#176`（fix 在 11 天後）、
`#761`（5.9 天）。

blame + 5 天仍漏掉的 6 條 X，全部是同一種形態：fix 確實改到 PR 寫的行，
但原因是合併後別處的改動（`#145` hook 改名、`#150`、`#153`、`#200`、
`#4829:118` 由 `#4832` 引入、`#201` 那條 OTHER）。blame 看不出「這行為什麼
要改」，這一類只能留給標註時的查證。

### 行號可以自動推得

blame 指到 PR 的那幾行，拿行內容在 PR head 的檔案裡對回去，就得到 PR head
座標的行號。17 條 blame 有歸因的 V 全部落在人工標的行 ±9 內，中位數 1 行。
產生器可以直接給出行號，不用人看 diff 猜，LINE 那一類在源頭就不會長出來。

### 母體有多大

寫了一個全本機的掃描器（不打 GitHub API，PR 從 base 分支 first-parent
歷史辨識：squash 是標題結尾 `(#N)`，merge 是 `Merge pull request #N`），
對三個 repo 掃一年，fix 視窗 14 天，三個 repo 合計約 2 分鐘：

| repo | 一年 PR 數 | fix commit | 歸因 ≥ 0.5 且 ≤ 5 天的 PR | 其中不在既有候選集 |
| --- | --- | --- | --- | --- |
| repo A（前端 monorepo） | 302 | 161 | 75 | 58 |
| repo B | 109 | 422 | 33 | 23 |
| repo C | 263 | 101 | 17 | 8 |
| 合計 | 674 | 684 | 125 | 89 |

新的 89 個 PR 涵蓋 233 個檔案、692 個 hunk。既有候選集只掃了每個 repo
最近 100 個 PR，repo A 那 100 個只涵蓋約三週，2026 年 7 月的 47 個
池內 PR 有 41 個沒被掃到。

掃描器對照既有 38 個已確認 PR：27 個有歸因 hunk，11 個沒有；那 11 個裡有
9 個的 expected 全部是 X。人工退回的 31 個候選有 17 個仍有歸因 hunk，所以
blame 不能取代人工確認，只是把要看的東西減少。

掃描器用自己的 fix commit 清單（本機 `--no-merges` 全部 commit，含 merge
合併的 PR 裡的分支 commit）對同一組 54 條重算，5 天門檻下是 V 留 15、
X 擋 25、精確率 0.62，比上表低 0.09，差在它多收了幾個分支內的小 commit。
兩種算法的方向一致。

### 估計的產出

以既有比例推：掃描保留的候選 61% 通過人工確認（22/36）、確認後的 expected
62% 有效、每個 PR 約 1.4 條。89 個新 PR 大約得 45-50 條有效條目，加既有
20 條約 65-70 條。單條權重從 5 個百分點降到 1.5 個百分點。

## 下一步（2026-09-02 第九次更新）

一、把 blame 歸因寫進產生器。設計：新增 `lib/backtest-blame.sh`（PR commit
集合、hunk 歸因、行號回推），`build-benchmark.sh` 加 `--attribution blame`
走本機 clone（`MRA_BACKTEST_WORKSPACE`，回測跑 review 本來就需要），候選
記 `blame_ratio`、`gap_days`、PR head 座標的行號；`review-benchmark.sh
--add` 加 `NOT_BLAMED_TO_PR` 警告。現行交集路徑保留，預設不變。

二、用新產生器掃三個 repo 一年，89 個新 PR 交給模型交叉驗證標註（Claude 與
codex 各自判「缺陷在 PR head 成不成立」並寫 note，只收兩邊一致的）。這一步
用 API 額度，不用 review 額度。

三、新 PR 跑 review 回測。約 89 個 PR，每個額度視窗 20-25 個，要 4 個視窗。
可以先跑 repo A 的 58 個。

四、原第二、三點（重量浮動、`#764` 迴歸案例）保留，等分母擴大後再做。
