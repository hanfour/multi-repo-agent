# 分層注入回測

`2026-rule-extraction-comparison.md` 的下一步列了兩件沒被回答的事，這一輪回答
第一件：讓 rails 層的規則真的進到 Rails PR 的 prompt，三個指標會不會動。

結論是不會。即使只看「真的拿到對的層」那 34 條 expected finding，兩輪的命中
集合差異是 3 對 3，沒有方向。

## 執行條件

與階段二基準線 C、以及前一輪 `rules-taxonomy` 完全一致：personas 模式、
persona 輪數 20、claude sonnet、worktree 隔離、三點 range、token 預算 5000。
規則集同樣是 `agents/review-rules/taxonomy`（37 個規則檔）。唯一的差別是
persona 目錄從一份共用的 common 層，換成每層各一份、逐 PR 依 repo 挑。

38 個 confirmed PR、54 條 expected finding，兩輪都是 38/38 跑完，零失敗。

| label | 注入方式 | 每個 PR 讀到的規則 |
| --- | --- | --- |
| rules-taxonomy | 單一 common 層 | common 8 條 |
| taxonomy-layered | 依 repo 分層 | 該層 8 條（含 common），react 層 7 條 |

## 指標

| 指標 | rules-taxonomy | taxonomy-layered |
| --- | --- | --- |
| tolerance | 15 | 15 |
| expected_total | 54 | 54 |
| missed | 37 | 37 |
| miss_rate | 0.69 | 0.69 |
| comments_total | 194 | 211 |
| unmatched | 177 | 194 |
| unmatched_rate | 0.91 | 0.92 |
| severity_agree | 8 | 8 |
| severity_rate | 0.47 | 0.47 |

漏抓數與嚴重度吻合數完全相同。唯一動的是產出量：多了 17 則 comment，而那
17 則全部落在未對應。

## 逐條配對

彙總相同不代表命中的是同一批。37 對 37 可以是「完全一樣」，也可以是「各有
進帳與流失、剛好抵銷」，兩者對「分層有沒有用」的結論相反。逐條配對的結果是
後者。

| | 容差 5 | 容差 15 |
| --- | --- | --- |
| 兩邊都命中 | 8 | 13 |
| 只有 rules-taxonomy 命中 | 4 | 4 |
| 只有 taxonomy-layered 命中 | 2 | 4 |
| 兩邊都漏 | 40 | 33 |

這與上一輪 taxonomy 對 tfidf 的形狀完全不同。那一輪是 6 對 0，單向、
McNemar p ≈ 0.016。這一輪兩個方向的數字一樣大，是最徹底的空結果。

## 37% 的 expected finding 拿到的是錯的層

分層的粒度是 repo，不是檔案路徑。`acme/nest-monorepo-2.0` 在對應表裡是 nestjs
層，但它 26 條 expected 裡有 20 條落在 `apps/frontend`，那些改動拿到的是後端
層的規則。

| repo | 層 | expected | 其中 apps/frontend |
| --- | --- | --- | --- |
| acme/rails-app-1 | rails | 11 | 0 |
| acme/react-app-1 | react | 17 | 0 |
| acme/nest-monorepo-2.0 | nestjs | 26 | 20 |

所以整份基準集裡真的拿到對的層的是 34/54，佔 63%。這個限制在跑之前就知道
（寫在 `scripts/run-backtest.sh` 的註解裡），所以只看那 34 條是事先定好的
子集，不是看到結果之後才挑的。

限縮之後結果沒有改變：

| | 容差 5 | 容差 15 |
| --- | --- | --- |
| 兩邊都命中 | 8 | 13 |
| 只有 rules-taxonomy 命中 | 3 | 3 |
| 只有 taxonomy-layered 命中 | 1 | 3 |
| 兩邊都漏 | 22 | 15 |

## 多出來的 17 則 comment 集中在錯層的那個 repo

| repo | rules-taxonomy | taxonomy-layered |
| --- | --- | --- |
| acme/rails-app-1 | 41 | 41 |
| acme/react-app-1 | 54 | 58 |
| acme/nest-monorepo-2.0 | 99 | 112 |

rails-app-1 一則都沒變。多出來的量集中在 nest-monorepo-2.0，也就是拿後端規則去審前端
程式碼的那個 repo，而它們沒有換到任何一條命中。

## 這一輪不能回答的事

沒有重複執行的基準線。同一組設定連跑兩次會有多少命中差異，目前沒有數字，
所以「3 對 3」是分層真的沒有效果，還是效果小於執行間的浮動，這一輪分不出來。
要分出來，得用同一份 persona 目錄跑第二次，量出命中差異的下限。

在那之前，這一輪能支持的說法只有一句：分層注入沒有帶來可觀測的改善，而且
差異不是單向的。

## 下一步

三個方向，按能回答的問題排序。

第一，重複執行基準線。這是解讀上面任何數字的前提，成本是再跑一輪 38 個 PR。

第二，把分層粒度從 repo 換成檔案路徑。37% 的 expected finding 拿到錯的層，
這件事沒修之前，monorepo 那 22 個 PR 對分層的檢定力接近零。需要的是讓同一次
review 依檔案載入不同 persona，而 persona 目錄一次只能指向一個地方
（`lib/personas.sh` 的 `_personas_dir()`），這是 review 流程本身的結構。

第三，`2026-rule-extraction-comparison.md` 列的另一件事仍然沒動：85% 的漏抓
是「reviewer 在那個檔案裡一句話都沒說」。這一輪的 file_miss_rate 是 0.48，
26/54 條 expected 落在 reviewer 完全沒提到的檔案裡。分層改變的是既有注意力
的落點，不是它的範圍，跟上一輪的判讀一致。
