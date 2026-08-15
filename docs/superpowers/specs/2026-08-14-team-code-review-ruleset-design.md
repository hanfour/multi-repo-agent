# 團隊 code review 規則集 — 設計

**Date:** 2026-08-14
**Status:** Approved (brainstorming)
**Branch:** `feat/team-code-review-ruleset`

## 問題

`mra review` 已經有 5 個 persona 平行審查再 synthesize，外加 refute、adjudication、premise、verdict sentinel 幾層流程。但每個 persona 檔只有 18 到 21 行，`agents/personas/README.md` 明文限制 3KB 以內。FOCUS 是五條左右的關鍵字，METHOD 三步。有審查角度，沒有判準。

這造成兩個已記錄的問題：

- 2026-06-23 的 false-green：4 個真有問題的 Acme PR 全被判 APPROVED，獨立的 Fallow bot 在同樣的 diff 上找到實際缺陷。
- 嚴重度評錯：reviewer 指出「肯定斷言依賴固定 100ms `Task.sleep`」，評為 Minor 並註明「與套件既有慣例一致，風險低」，實測是穩定 50% 失敗。

同時 `~/.claude/rules/common/` 有 8 個檔案共 316 行的通用清單，與 persona 各寫各的，沒有共同來源。`lib/review-context.sh:64` 讀的是 `$project_dir/.claude/rules`，全域那份不會進 review context。

## 目標

建立一份規則來源，指得回真實 review 意見，並生成三個接點的內容：`mra` 的 persona 檔、Claude Code skill、`~/.claude/rules/`。

成功標準是拿舊 PR 回測漏抓率，不是主觀判讀。

## 適用範圍：Acme 實際技術棧

31 個 active repo、1553 條依賴的掃描結果：

| 層 | 近一年 PR | 版本 | 代表 repo |
| --- | --- | --- | --- |
| NestJS + Prisma | 約 720 | NestJS 11、Prisma 6 | nest-monorepo-2.0（後端）、nest-app-2、nest-app-3、masa-performance |
| Rails legacy | 約 400 | Rails 4.2 到 5.2、Ruby 2.4 到 2.5 | erp 355、api-gateway、qp |
| React | 約 270 | React 19、TanStack Query v5 | react-app-1 206、react-app-2、awesome-dsp-ui |
| Vue 2 | 約 120 | Vue 2.5 到 2.7、Vuex | vue-app-1 86、vue-app-2 31 |
| Vue 3 | 76 | Vue 3.5、Pinia | superdsp-ui |
| Rails modern | 54 | Rails 8.1、Ruby 3.4 | masa |

`nest-monorepo-2.0` 是 turbo + pnpm workspaces 的 monorepo，349 個 PR 同時涵蓋 React 19 前端與 NestJS 後端，上表計入後端層，實際會有部分屬於 React 層。

規則分成通用層加四個框架層：NestJS/Prisma、Rails legacy、React 19、Vue 2。Vue 3 與 Rails modern 各只有一個 repo，先用通用層加相近框架層涵蓋，PR 量起來再拆。`moai`（18 PR、Rails 4.2.4）只需要 security 與依賴升級規則。

`erp` 跑在 Rails 4.2.11 + Ruby 2.5.7，是全 org PR 量最高的 repo（355），有 6 位開發者持續開 PR 與人類 review 往返。舊框架缺少現代的防呆，規則的邊際價值最高，且有最多 PR 可回測。

## 架構

四層，語料在最底層：

```
① 語料庫   外部資深 reviewer 意見（主）+ 自家 PR 意見（校準）
           每筆 = { diff_hunk, body, thread, path, repo, reviewer, 是否被採納 }
           位置：~/.cache/mra-review-corpus/，不進 git
                          │  萃取
                          ▼
② canonical ruleset  一個維度一個檔
           位置：~/multi-repo-agent/agents/review-rules/
           ├─ 觸發訊號：diff 裡看到什麼就要查這條
           ├─ 判準：資深 reviewer 實際用什麼理由說它是問題
           ├─ 嚴重度：什麼情況 CRITICAL、什麼 MEDIUM
           ├─ 反例：什麼不該報
           └─ 出處：指回 ① 的具體意見 URL，至少三則
                          │  生成
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
③ persona 檔        SKILL.md         rules/common/
   agents/personas/  ~/.claude/skills/  ~/.claude/rules/
```

GitHub 的 pull request review comment 帶 `diff_hunk` 欄位，也就是被批評的那段程式碼與批評本身綁在一起。所以語料的每一筆是「這段 code + 為什麼它有問題 + 資深者怎麼看出來的」三件一組，不是抽象規則。這正是 persona 現在缺的部分。

每條規則強制帶出處 URL。作用有兩個：日後要改規則可以回去看原始意見再判斷；回測時能區分「規則沒抓到」與「規則本身寫錯」。

三個產出都是生成的，檔頭標 `<!-- generated from agents/review-rules/ — DO NOT EDIT -->`。改規則一律回頭改 canonical，避免三邊各自漂移。

## 取材

### 外部語料

各目標 repo 的可取則數：

| repo | 可取則數 | 對應層 |
| --- | --- | --- |
| rails/rails | 約 59,800 | Rails |
| microsoft/TypeScript | 約 50,700 | 通用 TS |
| facebook/react | 約 33,300 | React |
| prisma/prisma | 約 14,400 | Prisma |
| TanStack/query | 約 5,000 | React |
| vuejs/core | 約 4,000 | Vue（參考） |
| nestjs/nest | 約 2,200 | NestJS |
| vuejs/vue | 約 1,200 | Vue 2 |

合計約 17 萬則，全抓約 1,700 次 API 呼叫，在 5000/hr 額度內一次跑完。

兩個缺口要補：

- `nestjs/nest` 只有 2,200 則，但 NestJS 是 PR 量最大的一層（約 720）。要加 `nestjs/typeorm`、`nestjs/swagger`、`golevelup/nestjs` 等生態 repo。
- `vuejs/vue` 只有 1,200 則且已進維護。Vue 2 層主要靠自家 `vue-app-1`（86 PR）與 `vue-app-2`（31 PR）的語料。

### 篩選

五步，每步記錄留存率：

1. 排除 bot。login 以 `[bot]` 結尾，加上 `coderabbitai`、`copilot`、`dependabot`、`github-actions`。`vuejs/core` 近 300 則有 186 則是 CodeRabbit，不濾會讓語料變成另一個 AI reviewer 的平均水準。
2. 只留資深者。`author_association` 為 `MEMBER` / `OWNER` / `COLLABORATOR`，或該 repo 留言數前 15 名。rails/rails 實測 MEMBER 佔 39%。
3. 品質門檻。長度大於 150 字元、或 `in_reply_to_id` 不為 null、或 `reactions.total_count` 大於 0。rails/rails 近 100 則實測：討論串內 49 則、長度大於 150 有 41 則、有 reaction 11 則，長度中位數 134。
4. 剔除只有 ```suggestion 區塊而無說明文字的意見，那學不到判準。
5. 保留 `diff_hunk`。

自家語料走同一條管線，第 2 步改為「近一年有 10 則以上 review comment 的人」。

### 儲存

`~/.cache/mra-review-corpus/<owner>__<repo>/<page>.json`，每頁一個檔。重跑時跳過已存在的檔，API 失敗可續抓。不進 git，可用腳本重建。

## 規則萃取

三階段，每階段輸出可檢查：

**分群。** 分兩段，都用程式做不用 LLM，因為分群結果要能重現。

先分層：依 `path` 副檔名與路徑關鍵字對應到層。`.rb` 進 Rails 層，並依該 repo 的 Rails 版本再分 legacy 與 modern；`.tsx` 且 import 有 `@tanstack/react-query` 進 React 層；`.ts` 且路徑含 `*.module.ts` / `*.service.ts` / `*.controller.ts` 進 NestJS 層；`.vue` 依該 repo 的 Vue 版本分流；其餘進通用層。

再分主題：層內用 `diff_hunk` 與 `body` 的 token 做 TF-IDF 向量，跑階層式分群，切在 15 到 40 群之間。群數上下限是為了避免一群包山包海或碎成單則。分群結果存檔，萃取階段讀檔案不重算。

**萃取。** 每個主題群交給 agent 產出一條 canonical 規則。必填欄位：觸發訊號、判準、嚴重度分界、反例、出處 URL 至少三則。出處不足三則的群直接丟棄，並在 log 印出丟了幾條與哪些主題。樣本太少寫出來的規則是幻覺。

**合併。** 同一條規則可能從外部與自家語料各長出一次。合併時保留兩邊出處，判準以外部為主、嚴重度以自家為主。外面的資深者提供方法，自己的團隊定標準。

### NestJS 層的分群例外

階段一實測（見 `docs/superpowers/notes/2026-corpus-retention.md`）：NestJS 層外部語料 6,594 則，
對應 Acme 近一年約 720 個 PR，每個 PR 約 9 則。數量不是問題，組成才是：

| 來源 | 則數 | 佔比 |
| --- | --- | --- |
| prisma/prisma | 5,730 | 87% |
| nestjs/nest | 751 | 11% |
| nestjs/swagger | 85 | 1% |
| nestjs/typeorm | 28 | 0.4% |

`prisma/prisma` 是 ORM 與 query engine 的程式碼，review 重點是查詢產生、型別推導、資料庫相容性。
Acme 的 `nest-monorepo-2.0`、`nest-app-2` 是 NestJS 應用服務，重點是 DI 生命週期、module 切分、
API 契約。把 prisma 的意見當成整層通用的 NestJS 方法來源，會讓規則偏向它不該偏的方向。

決定：這一層在萃取階段再細分一次，不在語料階段丟棄任何來源。

- `nestjs/nest` 的 751 則是 NestJS 專屬方法的來源。量少但切題。
- `prisma/prisma` 的 5,730 則歸入資料存取主題，不作為整層通用素材。它產出的規則
  `layer` 仍是 `nestjs`，但主題群要標示為資料存取相關，讓階段四生成 persona 時能分開處理。
- 嚴重度標準照原本的分工來自自家語料：`nest-monorepo-2.0`（349 PR）、`nest-app-2`（194）、
  `nest-app-3`（60）。

三個具體影響：

- 分群時 NestJS 層要先依來源 repo 分成兩堆再做主題分群，不要混在一起跑 TF-IDF。混在一起的話
  prisma 的 5,730 則會主導所有群心，把 nestjs/nest 的 751 則稀釋掉。
- 「出處至少三則」在資料存取那堆仍要求至少一則外部出處；NestJS 專屬那堆因為外部樣本只有 751 則，
  允許三則全部來自自家語料。
- 規則檔的 `出處` 欄位要能看出來源是外部還是自家，並且外部來源要能分辨是 `nestjs/nest` 還是
  `prisma/prisma`。這是日後判斷某條規則適不適用於應用服務的依據。

### canonical 檔案格式

```markdown
---
id: nestjs-provider-scope-leak
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現 `@Injectable({ scope: Scope.REQUEST })`，或 request-scoped provider
被注入到 singleton

## 判準
（資深 reviewer 實際的理由）

## 嚴重度
CRITICAL：（什麼情況）
HIGH：（什麼情況）
MEDIUM：（什麼情況）

## 反例（不該報）
（什麼情況不要報）

## 出處
- https://github.com/nestjs/nest/pull/.../#discussion_r...
```

`severity_default` 是這條規則沒有命中「嚴重度」章節任一條件時的落點。命中的話以該章節為準。兩者並存是因為多數規則的嚴重度取決於情況，但仍需要一個在情況判斷不出來時的預設值，避免 agent 自由心證。

`frameworks` 欄位用於版本篩選。審 `erp`（Rails 4.2）時不載入 Rails 8 的規則。Rails 4.2 + Ruby 2.4 的審查重點是已知 CVE 與升級路徑，Rails 8.1 + Ruby 3.4 是新 API 用法與效能，同一個框架名稱下講的不是同一件事。

## 回測

### 基準集

| 來源 | 用途 | 可靠度 |
| --- | --- | --- |
| merge 後 14 天內有 fix commit 改到同一檔案且行號區間重疊 | 主要 ground truth，計入漏抓率 | 高 |
| 4 個 false-green PR（nest-monorepo-2.0 #145 / #152、react-app-1 #182 / #183）加 Fallow 當時的意見 | 回歸案例，不能退步的下限 | 高，樣本只有 4 個 |
| 人類 CHANGES_REQUESTED 意見 | 只用來校準嚴重度 | 中，nit 比例高 |

第一種的判定方式：取 PR 合併後 14 天內、commit message 含 `fix` / `hotfix` / `bug` 的 commit，比對它改到的檔案與行號區間是否與原 PR 的 diff 重疊。重疊的話，那個 fix commit 的內容就是「當初該抓到什麼」。全程用 git 與 GitHub API 判定不用 LLM，所以基準集本身是客觀的。`erp` 355 個 PR、`nest-monorepo-2.0` 349 個，母體足夠。

第三種不計入漏抓率。裡面 nit 太多，拿來算漏抓會把規則逼成挑剔的方向。

### 指標

- 漏抓率：基準集裡的真缺陷有幾個沒報出來。
- 誤報率：報了但基準集與人類 reviewer 都沒認可的。
- 嚴重度吻合度：報對了但評成 MEDIUM 而實際是 CRITICAL 的比例。

### 跑法

舊規則與新規則對同一批 PR 各跑一次，用 `mra review --strategy personas`，不 post 到 PR，輸出存檔比對。

基準集初版取 30 到 40 個 PR。回測會對真實 PR 呼叫 LLM，100 個 PR 兩組規則各跑一次就是 200 次完整 review，而每次 review 是 5 個 persona 平行跑。先確認指標可用再放大。

第一輪的漏抓率信賴區間會很寬，不能拿來做強結論。

## 三個接點的生成

生成腳本 `scripts/build-review-rules.sh`，三個輸出：

**persona 檔**（`agents/personas/*.md`）。依 `layer` 把規則聚合成 persona。保留現有 5 個 persona 的名稱與 `ROLE / STYLE / FOCUS / METHOD / OUTPUT FORMAT` 結構，FOCUS 與 METHOD 由規則生成。`lib/personas.sh` 的 `load_persona` 讀 `agents/personas/${name}.md`，丟檔案進去就生效，不用改 mra 程式。

**SKILL.md**（`~/.claude/skills/code-review/SKILL.md`）。給人在終端機用，內容是規則的可讀版加上呼叫方式。照 `jean`、`ito` 的慣例用單一檔案。

**rules/common/**（`~/.claude/rules/`）。用通用層規則重寫現有 316 行的清單。只放跨語言的審查方法，框架層不進來，否則每個專案都要讀不相干的規則。

### 要改的既有限制

`agents/personas/README.md` 寫「Keep each file under 3KB」。persona 會從 20 行長到 80 到 120 行，因為每條規則要帶判準與反例。這條限制要改。

取捨已確認：不為了省 token 壓縮 persona 內容。2026-06-23 的 false-green 起因之一就是 `--max-turns` 被當作 token 優化從 15 調到 8，導致 agent 在大 diff 上燒完 turns 只輸出 `Error: Reached max turns (8)`。

## 錯誤處理

**取材。** 每個 repo 每頁存成獨立檔案，重跑跳過已存在的。打到 rate limit 就停下來報還剩多少頁未抓，不靜默截斷。

**萃取。** 出處不足三則的規則丟棄，log 印出丟棄數量與主題。靜默丟棄會讓人誤以為涵蓋完整。

**生成。** 三個輸出先寫暫存再原子替換。任何一個失敗就全部不動，避免三邊版本不一致。

## 測試

照既有慣例寫 `tests/test_*.sh`：

- `test_review_rules_schema.sh`：規則檔必填欄位、出處 URL 格式、`severity_default` 值域、`frameworks` 語法。
- `test_build_review_rules.sh`：生成腳本對固定輸入的輸出快照比對。
- `test_review_rules_not_hand_edited.sh`：比對生成結果與 committed 的 persona 檔，確保沒有人手改生成檔。
- `test_corpus_filter.sh`：篩選管線五步對 fixture 語料的留存數。

## 實作階段

四個部分相依但可分開驗收，各自有可檢查的產出。實作計畫先做階段一與階段二。

| 階段 | 內容 | 完成的判斷方式 |
| --- | --- | --- |
| 一 | 取材與篩選：抓取腳本、五步篩選、續抓 | `~/.cache/mra-review-corpus/` 有 17 萬則原始語料，篩選後的留存數與各步驟留存率有紀錄 |
| 二 | 回測基準集：fix commit 比對、30 到 40 個 PR 的基準集、舊規則基準線 | 基準集檔案產出，舊 persona 跑完一輪，三個指標有數字 |
| 三 | 規則萃取：分層、分群、萃取、合併 | `agents/review-rules/` 有規則檔且通過 schema 測試 |
| 四 | 生成與驗收：三個接點的生成腳本、新規則回測、與階段二的基準線比較 | 三個指標相對階段二的基準線有改善，回歸案例的 4 個 PR 不再 false-green |

階段二排在規則萃取之前，是為了先確認指標本身可用。如果基準集造不出來或指標算不出有意義的數字，後面兩階段的方向要重新討論，不要等到規則都寫完才發現無法驗證。

## 已知限制

- 基準集初版 30 到 40 個 PR，統計效力有限。
- `nestjs/nest` 語料只有 2,200 則，NestJS 層的規則品質會低於 Rails 與 React 層，即使補了生態 repo。
- Vue 2 層幾乎沒有外部語料可用，規則主要來自自家 117 個 PR。
- 「merge 後 14 天內有 fix commit」會漏掉潛伏期更長的缺陷，也會誤收與原 PR 無關的修改。這個誤差沒有校正方式，只能在解讀漏抓率時記得它存在。
