# 回測基準線

兩組數字，同一組 38 個 PR、54 條 expected finding、同一個 `candidates_sha`
（`7a8226ee333100a9`）、零排除。

| | A：standard + codex | C：personas + claude |
| --- | --- | --- |
| 漏抓率 ±5 | 0.87 | 0.85 |
| 漏抓率 ±15 | 0.81 | **0.69** |
| 未對應率 ±5 | 0.77 | 0.96 |
| 嚴重度吻合率 ±5 | 0.43 | 0.25 |
| 產出 comment | 30 | **214** |

A 是「團隊今天實際跑的設定」（`~/.pmk/gateway.json` 的 `strategy: standard` +
`providerMode: codex`）。C 是階段三要改的那條路徑。

**兩者差三個變因**（路徑、provider、C 用了偏離預設的 persona 輪數 20），
不能解讀成「persona 比 standard 好」。C 的用途是階段三的對照組：規則改完跟 C 自己比。

## 主要結論

**團隊今天的 code review，在 38 個真實 PR 上抓到 54 條已知缺陷中的 7 到 10 條。**

（基準集在跑完之後補進一條：rails-app-1#4829 的 `extract_images` 條件反轉，我判讀時把它
當成「改寫成 guard clause」而跳過，是 baseline 的 reviewer 抓到的。分母因此從 53
變 54，四份 summary 都在新的 `candidates_sha` 下重算過。）

## 漏抓的組成

（下表為補進第 54 條之前的分布，比例不受影響。）

| 距離 | A | C |
| --- | --- | --- |
| ±5 命中 | 6 | 6 |
| 6–15 | 4 | 10 |
| >15（講的是別的東西） | 3 | 12 |
| 同檔案完全沒有 comment | 40（75%） | 24（46%） |

A 的漏抓有 85% 是「expected finding 所在的檔案，reviewer 一句話都沒說」。
瓶頸是覆蓋面，不是定位精度。

C 把這個數字從 75% 壓到 46%，但多出來的注意力大多落在 6–15 與 >15 兩格。

## unmatched_rate 不是誤報率

這一點對兩組都成立，而且是解讀這份文件最容易出錯的地方。

A 的 24 條未對應 comment 逐條讀完，C 的 202 條依事先寫定的規則抽樣 79 條
（CRITICAL 全取 17、HIGH 每 2 取 1 共 30、MEDIUM 每 4 取 1 共 32）讀完。

**兩組都沒有找到明確的誤報。**

C 的 17 條 CRITICAL 裡有 3 條其實是命中，只是超出 ±5：

| PR | C 指的位置 | expected | 距離 |
| --- | --- | --- | --- |
| react-app-1#200 | `settings-page.tsx:26` | `:20` | 6 |
| nest-monorepo-2.0#784 | `get-redirect-url.use-case.ts:41` | `:28` | 13 |
| rails-app-1#4832 | `docx_html_converter.rb:124` | `:115` | 9 |

其餘 14 條是基準集沒收的真缺陷，例如：`create` action 把 CPU/IO-bound 的 DOCX
處理包進 transaction、LI 轉 active 的 transaction 在 commit 前跑 16 次序列化
DB round-trip、測試把整個 `useMutation` mock 掉導致被測邏輯完全沒被驗到。

因此 `unmatched_rate` 對「規則有沒有變好」幾乎沒有鑑別力。它衡量的主要是
「基準集收了多少」，不是「reviewer 講對了多少」。

## C 多出的 184 條 comment 是什麼

抽樣判讀顯示：多數是真的，但**類型分布與基準集不同**。

C 大量產出的是測試品質（mock 掉被測對象、斷言比對到錯的元素、fixture 與實作
不一致）、重複程式碼、效能（N+1、迴圈內查詢）、以及缺少測試覆蓋。

基準集的 54 條裡只有 5 條屬於測試品質，其餘偏向功能缺陷。所以 C 的產出與基準集
的重疊本來就不高 —— 這不是 C 講錯，是兩者關注的東西不同。

## 分 repo 的差異

「同檔案完全沒有 comment」的比例：

| repo | A | C |
| --- | --- | --- |
| rails-app-1 | 43% | 23% |
| react-app-1 | 約 60% | 約 30% |
| nest-monorepo-2.0 | 100%（11/11） | 59%（10/17） |

兩者都在 nest-monorepo-2.0 最差。那是 turbo + pnpm 的 monorepo，PR 常橫跨
`apps/frontend` 與 `apps/backend`，expected finding 分散在不同層。

這是「所需推理」分類（見 `2026-backtest-finding-taxonomy.md`）沒有捕捉到的維度：
規則除了處理「看哪種問題」，還要處理「monorepo 的 PR 怎麼分配注意力」。

## 執行條件

| 項目 | A | C |
| --- | --- | --- |
| review 模式 | `--strategy standard --provider codex` | `--personas` |
| provider / model | codex / gpt-5.5 | claude / sonnet |
| reasoning effort | xhigh | 不適用 |
| persona 輪數 | 不適用 | **20（偏離預設 8）** |
| 隔離 | 每個 PR 一個 detached worktree，checkout 到該 PR head | 同左 |
| diff 範圍 | `base...head`（三點） | 同左 |

model 與 effort 用衍生 config 覆蓋，版控內的 `config.json` 不動。這些值由 adapter
寫進 `run-conditions.json` 再進 summary，階段四可直接 diff。

**C 的 persona 輪數偏離要記住**：預設 8 輪下，五成的 PR 跑不完（5 個 persona 有
3–4 個 `Reached max turns (8)`），基準線會沒有分母。因此 C 的數字不能宣稱是
「團隊今天切到 persona 模式會拿到的」，它量的是 persona 路徑在足夠輪數下的能力。

## 這份基準集的天花板

只有「後來被修過」的缺陷才會進基準集。沒人發現、或發現了但沒修的，永遠不會成為
expected finding。miss_rate 量的是「reviewer 有沒有抓到那些後來確實被修的問題」。

另外，54 條 finding 只對應約 34 個相異缺陷。「草稿沒依 lineItem.id 分」一個缺陷跨
8 個 PR，佔 15%。單一缺陷翻轉就能讓 miss_rate 動 15 個百分點，階段四要同時看
相異缺陷維度的數字。

## 容差為什麼記兩個

我取行號的方式是 `fix_range` 起點（修復動到的位置），reviewer 指的是問題成因所在
的行，兩者系統性差 6 到 13 行。A 的 6–15 那格四條全部是同一個缺陷；C 的 CRITICAL
裡有 3 條同樣落在這一格。

放寬容差的代價是同一檔案裡兩個不同缺陷可能被誤判成同一個。兩個都記，階段四比較時
若只有其中一個動，那本身就是訊號。

## 重跑需要的條件

- `gh auth switch --user acme-bot`，以及有效的 Claude 登入
- `~/workspace` 底下有 rails-app-1、nest-monorepo-2.0、react-app-1 的 clone
- `MRA_BACKTEST_CMD` 指向 `scripts/backtest-review-adapter.sh`
- `MRA_BACKTEST_REVIEW_MODE` 設 standard 或 personas
- personas 模式另外設 `MRA_REVIEW_PERSONA_MAX_TURNS=20`

候選集抽樣目前用 `sort=updated`，同樣的指令在不同時間會抽到不同的 PR。階段四比較
兩組規則之前要先改成依 `merged_at` 排序或固定日期區間，否則比的不是同一組 PR。

## 過程中修掉的兩個 mra 缺陷

這兩個與基準線無關，但團隊切到 persona 模式就會踩到：

- **personas 路徑漏了 `extract_json`**：synthesize 產出的完整 review 若被 markdown
  code fence 包住就整份被丟掉，而且是靜默的。實測一份 4915 bytes、指出 RCE/SSRF
  風險的 review 因此消失。
- **`run_synthesize` 的 `--max-turns 3` 寫死**：那是 debate 路徑（2 份輸入）的
  經驗值，personas 餵它 5 份，貼著上限跑會隨機失敗。已改為
  `MRA_REVIEW_SYNTH_MAX_TURNS`，預設 8。
