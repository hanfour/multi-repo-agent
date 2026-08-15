# 外部語料的實際篩選留存

**Date:** 2026-08-15
**Spec:** `docs/superpowers/specs/2026-08-14-team-code-review-ruleset-design.md`
**Plan:** `docs/superpowers/plans/2026-08-15-corpus-fetch-and-filter.md`（階段一 Task 5）

抓取 1,710 頁、169,960 則原始 review comment，篩選後留下 61,362 則。

這份數字是全分支 review 後重新測得的。第一版少抓 10 頁而且沒有發現，篩選也漏了 spec 的
「前 15 名」子句，兩者都已修正，詳見文末的「第一版的兩個錯誤」。

## 各 repo

| repo | 原始 | 去 bot 後 | 資深 | 品質 | 有說明 | 留存率 |
| --- | --- | --- | --- | --- | --- | --- |
| rails/rails | 59,786 | 59,668 | 35,730 | 18,277 | 16,842 | 28.2% |
| microsoft/TypeScript | 50,641 | 48,258 | 40,256 | 21,998 | 20,515 | 40.5% |
| facebook/react | 33,299 | 33,207 | 23,917 | 15,428 | 14,289 | 42.9% |
| prisma/prisma | 14,314 | 11,789 | 10,428 | 6,862 | 5,730 | 40.0% |
| TanStack/query | 4,915 | 3,778 | 2,570 | 1,832 | 1,630 | 33.2% |
| vuejs/core | 3,946 | 3,369 | 2,363 | 1,397 | 1,164 | 29.5% |
| nestjs/nest | 2,121 | 1,988 | 1,366 | 868 | 751 | 35.4% |
| vuejs/vue | 1,173 | 1,170 | 768 | 367 | 328 | 28.0% |
| nestjs/swagger | 259 | 246 | 176 | 100 | 85 | 32.8% |
| nestjs/typeorm | 46 | 45 | 45 | 29 | 28 | 60.9% |

## 各層

| 層 | 可用則數 | 組成 | Acme 近一年 PR 量 | 每個 PR 可分到 |
| --- | --- | --- | --- | --- |
| common（TypeScript） | 20,515 | TypeScript 20,515 | 跨層共用 | — |
| rails | 16,842 | rails 16,842 | 約 400 | 42 |
| react | 15,919 | react 14,289、query 1,630 | 約 270 | 59 |
| nestjs | 6,594 | prisma 5,730、nest 751、swagger 85、typeorm 28 | 約 720 | 9 |
| vue | 1,492 | core 1,164、vue 328 | 約 120 | 12 |

## NestJS 層的組成問題

數量夠了，組成不理想：87% 來自 `prisma/prisma`。

`prisma/prisma` 是 ORM 與 query engine 的程式碼，review 重點是查詢產生、型別推導、資料庫相容性。
Acme 的 NestJS 專案是應用服務，重點是 DI 生命週期、module 切分、API 契約。兩者都叫 NestJS 層，
但不是同一種工作。

**已決定的處理方式**（2026-08-15）：在萃取階段再細分一次，語料階段不丟棄任何來源。
`nestjs/nest` 的 751 則作為 NestJS 專屬方法來源；`prisma/prisma` 的 5,730 則歸入資料存取主題。
分群時兩堆要分開跑，混在一起的話 prisma 會主導群心。詳見 spec 的「NestJS 層的分群例外」。

## 留存率不能當合格線

不同 repo 的留存率差距（28.0% 到 60.9%）反映的是該 repo 的 bot 導入程度與貢獻者組成，不是篩選
條件是否正確。`nestjs/nest` 的實測顯示得最清楚：

| 取樣窗口 | 原始 | 去 bot 後 | 留存率 |
| --- | --- | --- | --- |
| 全歷史 | 2,121 | 1,988 | 35.4% |
| 最新 500 則 | 500 | 370 | 約 18% |
| 最新 100 則 | 100 | 32 | 約 6% |

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

## 第一版的兩個錯誤

記在這裡是因為兩者都不會自己顯現，下次做同類取材要主動檢查。

**少抓 10 頁而且回報成功。** `corpus_fetch_repo` 當時對成功與失敗都印
`DONE <repo> last=598 fetched=592 failed=6`，失敗只是一個欄位；平行抓取腳本又把輸出 pipe 給
`sed`，退出碼被丟掉。結果 `rails/rails` 少 6 頁、`microsoft/TypeScript` 少 3 頁、
`facebook/react` 少 1 頁，約 1,000 則原始意見從未抓到，而第一版的這份文件宣稱結果完整。

修法有兩部分：失敗改印 `FETCH_INCOMPLETE`，以及在快取目錄寫 `.complete` 記錄應有頁數，
篩選前驗證 `1..last` 全部在位、缺頁就拒絕產出留存列。只改訊息不夠，因為讓那 10 頁悄悄消失的
是「篩選階段無條件接受快取裡現有的頁面」。

**漏掉 spec 的「前 15 名」子句。** spec 篩選第 2 步寫「`author_association` 為
MEMBER / OWNER / COLLABORATOR，或該 repo 留言數前 15 名」，第一版只實作了前半。影響最大的是
`prisma/prisma`（781 → 5,730）與 `facebook/react`（6,649 → 14,289），因為這兩個 repo 最活躍的
reviewer 都不具官方成員身分。NestJS 層因此從 1,386 變成 6,594。

## 執行成本

- 抓取 1,710 頁，併發 4，約 40 分鐘。單頁 4.7 到 7.6 秒，瓶頸是 GitHub API 本身
- 額度檢查每頁 0.6 秒，佔約 12%。`GET /rate_limit` 不計入額度
- 缺頁重抓是暫時性失敗，重跑兩輪即補齊；已存在的頁面會跳過，不耗額度
- 篩選全部循序執行，數分鐘。`prisma/prisma` 峰值記憶體約 588 MB，`rails/rails` 推估約 2 GB
- 語料不進版控，可用 `scripts/build-corpus.sh` 重建

抓取用 `--fetch-only` 平行、篩選循序，因為篩選會讀改寫共用的 `retention.tsv`。
並行寫入的鎖見計畫 Task 6 Step 5a。
