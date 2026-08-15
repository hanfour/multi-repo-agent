# 外部語料的實際篩選留存

**Date:** 2026-08-15
**Spec:** `docs/superpowers/specs/2026-08-14-team-code-review-ruleset-design.md`
**Plan:** `docs/superpowers/plans/2026-08-15-corpus-fetch-and-filter.md`（階段一 Task 5）

抓取 1,700 頁、169,500 則原始 review comment，篩選後留下 41,116 則。

## 各 repo

| repo | 原始 | 去 bot 後 | 資深 | 品質 | 有說明 | 留存率 |
| --- | --- | --- | --- | --- | --- | --- |
| microsoft/TypeScript | 50,341 | 47,958 | 28,421 | 16,655 | 15,387 | 30.6% |
| rails/rails | 59,186 | 59,068 | 31,388 | 16,461 | 15,097 | 25.5% |
| facebook/react | 33,199 | 33,107 | 11,762 | 7,223 | 6,649 | 20.0% |
| TanStack/query | 4,915 | 3,778 | 2,124 | 1,480 | 1,312 | 26.7% |
| vuejs/core | 3,946 | 3,369 | 2,106 | 1,211 | 997 | 25.3% |
| prisma/prisma | 14,314 | 11,789 | 1,424 | 917 | 781 | 5.5% |
| nestjs/nest | 2,121 | 1,988 | 1,057 | 620 | 542 | 25.6% |
| vuejs/vue | 1,173 | 1,170 | 697 | 326 | 288 | 24.6% |
| nestjs/swagger | 259 | 246 | 120 | 60 | 51 | 19.7% |
| nestjs/typeorm | 46 | 45 | 28 | 13 | 12 | 26.1% |

## 各層

| 層 | 可用則數 | 對應 Acme 近一年 PR 量 | 每個 PR 可分到的語料 |
| --- | --- | --- | --- |
| common（TypeScript） | 15,387 | 跨層共用 | — |
| rails | 15,097 | 約 400 | 38 |
| react | 7,961 | 約 270 | 29 |
| vue | 1,285 | 約 120 | 11 |
| nestjs | 1,386 | 約 720 | 1.9 |

## 要處理的問題：NestJS 層語料不足

PR 量最大的一層語料最少，差距不是邊際的。`rails` 層每個 Acme PR 可分到 38 則參考意見，
`nestjs` 層只有 1.9 則。

spec 已經預期 `nestjs/nest` 太薄而加了三個補充 repo，實測結果是補充效果有限：

- `nestjs/typeorm` 全站只有 46 則 review comment，可用 12 則
- `nestjs/swagger` 259 則，可用 51 則
- `prisma/prisma` 原始量夠（14,314）但留存率只有 5.5%，是所有 repo 最低。瓶頸在資深者那一步：
  11,789 降到 1,424，濾掉 88%。它的 review 大量來自沒有 MEMBER 身分的外部貢獻者

三個補充 repo 合計只貢獻 844 則。

### 三個可能的做法

一、再加 NestJS 生態的 repo。可以試 `nestjs/config`、`nestjs/bull`、`nestjs/terminus`、
`nestjs/mongoose`，但從 typeorm 與 swagger 的實測看，這些周邊套件的 review 量都在數十到數百則，
加四個可能也只多幾百則。

二、對 `nestjs` 層放寬資深判準。`prisma/prisma` 濾掉的 88% 裡有真正的技術討論，只是留言者不是
組織成員。做法是改成「該 repo 留言數前 N 名」而不是看 `author_association`，跟自家語料同一套
判準。代價是引入品質較不穩定的來源。

三、接受 `nestjs` 層的規則主要來自自家語料。Acme 的 NestJS 專案有 `nest-monorepo-2.0`（349 PR）、
`finance-system`（194）、`nest-app-3`（60），這些 repo 的 review 是團隊自己的判準，
本來就是嚴重度標準的來源。外部語料在這一層只提供有限的方法參考。

依 spec 「外面的人教方法、自己的團隊定標準」的分工，第三個做法與設計意圖最一致，但它意味著
NestJS 層的「方法」那一半會比其他層薄。這個取捨要在階段三開始前決定。

## 留存率不能當合格線

不同 repo 的留存率差距（5.5% 到 30.6%）反映的是該 repo 的 bot 導入程度與貢獻者組成，不是篩選
條件是否正確。`nestjs/nest` 的實測顯示得最清楚：

| 取樣窗口 | 原始 | 去 bot 後 | 留存率 |
| --- | --- | --- | --- |
| 全歷史 | 2,121 | 1,988 | 25.6% |
| 最新 500 則 | 500 | 370 | 18.0% |
| 最新 100 則 | 100 | 32 | 6.0% |

最新 100 則裡有 68 則是 GitHub Copilot。全歷史則由真人維護者主導：`kamilmysliwiec` 654 則、
`micalevisk` 192、`jmcdo29` 132。

由此得到一條取材原則：bot 導入愈深的 repo，近期資料愈沒價值，必須抓完整頁數，不能為了省 API
額度只抓前幾頁，那會抓到最沒用的部分。

判斷篩選是否正常的方式是看第 1 步濾掉的是誰。實測抽查：

| repo | 被濾掉的前幾名 |
| --- | --- |
| prisma/prisma | coderabbitai[bot] 2,323、Copilot 177、帳號已刪除 9、sonatype-lift[bot] 9 |
| facebook/react | Copilot 76、帳號已刪除 16 |
| rails/rails | 帳號已刪除 71、Copilot 47 |

全部是 bot 與已刪除帳號，沒有誤傷真人。

## 執行成本

- 抓取 1,700 頁，併發 4，約 40 分鐘。單頁 4.7 到 7.6 秒，瓶頸是 GitHub API 本身
- 額度檢查每頁 0.6 秒，佔約 12%。`GET /rate_limit` 不計入額度
- 篩選全部 1,700 頁循序執行，數分鐘
- 語料佔用磁碟空間依快取目錄實際大小為準，不進版控，可用 `scripts/build-corpus.sh` 重建

抓取用 `--fetch-only` 平行、篩選循序，因為篩選會讀改寫共用的 `retention.tsv`。
並行寫入的鎖見計畫 Task 6 Step 5a。
