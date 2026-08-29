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
| convention-auditor comments_total | 217 | 180 |
| baseline unmatched_rate | 0.96 | 0.92 |
| convention-auditor unmatched_rate | 0.96 | 0.90 |

（tol5 的 comments_total／unmatched_rate 兩輪剛好同一個數字，是同一份
review 輸出在不同容差下重算指標，comments_total 本身不隨容差變。）

miss_rate 在容差 15 微幅改善（37→36），severity_rate 明顯上升（41%→50%），
但這兩個改善都伴隨 comments_total 下降 37 則（217→180）——不是「講得更少但
更準」的正面訊號，而是後面查出來的失敗率問題的副作用。

**file_miss_rate 從 0.44 升到 0.48，跟設計目標方向相反。**

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

## 結論

兩個假設的機制都被證實真實存在——`convention-auditor` 真的會做 sibling
比對並非空談，覆蓋清單要求真的會逼 persona 交代原本會被略過的小改動。但
這次設計低估了新增工作量對固定 turn 預算的壓力，尤其是 `convention-auditor`
的 METHOD 天生比其餘 5 個 persona 貴（多一輪搜尋）。net 上，這一輪的
file_miss_rate 沒有改善，反而變差。

以「拿去解決 file_miss_rate 天花板」這個目標衡量，這次改動目前**不能算
達標**，需要下一輪處理 turn 預算問題才能重新驗證原本的假設。

## 下一步

三個方向，按能回答的問題排序。

第一，把 `convention-auditor` 的個別失敗率壓下來。兩個子選項：
（a）簡化它的 METHOD，減少「先搜尋再比對」需要的輪次；
（b）給它單獨拉高 `MRA_REVIEW_PERSONA_MAX_TURNS`（目前是全體 persona 共用
同一個值，這個 persona 個別需要更多輪並不代表其餘 5 個也需要）。在turn
預算問題沒解決之前，重跑這一輪只會得到同樣被失敗率淹沒的雜訊。

第二，覆蓋清單要求造成的額外輪次成本要單獨量化。這一輪的整體失敗率
（21 次）裡，convention-auditor 佔 12 次，其餘 9 次分布在
test-architect／api-contract-guardian，這兩者在 baseline 那輪合計只失敗
過極少次——覆蓋清單本身也在吃預算，不是只有新 persona 的成本。要分開回答
「加 persona 貴」跟「加覆蓋清單要求貴」這兩個問題，得跑一輪只加覆蓋清單
不加新 persona 的對照組。

第三，`2026-rule-extraction-comparison.md` 與 `2026-layered-injection.md`
共同指出的天花板仍然沒有被這一輪回答：這一輪的 file_miss_rate 甚至還沒有
回到 baseline 的 0.44。turn 預算問題解決之後，才有資格重新用這一輪的兩個
機制假設去檢驗那個天花板動不動得了。
