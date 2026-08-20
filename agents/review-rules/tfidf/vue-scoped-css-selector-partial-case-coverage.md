---
id: vue-scoped-css-selector-partial-case-coverage
layer: vue
frameworks: ["vue@3.x", "@vue/compiler-sfc@3.x"]
severity_default: MEDIUM
---
## 觸發訊號
diff 修改的是 scoped CSS 選擇器改寫邏輯（例如 `packages/compiler-sfc/src/style/pluginScoped.ts` 或其他基於 `postcss-selector-parser` 走訪 selector node 的程式碼），且符合下列任一模式：
- 只針對某一種 combinator（如 `>`）加上特殊處理，但沒有同時處理文法上地位相同的其他 combinator（如 `+`、`~`）
- 在逐一走訪 comma-separated selector list（`selector.each` / 逐個 rule 內的 selector）的過程中才計算/設定像 `shouldInject`、`deep`、`__deep` 這類旗標，而不是先掃過整個 rule 的所有 selector 再決定旗標值
- 新增一種 selector node 類型的處理分支（universal `*`、pseudo `:deep()`/`::v-deep`、combinator）卻沒有同步更新同一函式裡對應的還原/取消分支
- 為警告或錯誤訊息手刻字串內插 filename/line/column，而不是複用既有的訊息格式化路徑

## 判準
CSS 選擇器文法本身有多種結構等價的變形（不同 combinator、逗號分隔的多重 selector），只修好被回報的那個 repro case、放著其他結構相同的變形不管，會在下一個 issue 用稍微不同的 selector 重新踩到同一類 bug。更隱蔽的一種是旗標算的「時機」不對：像 `:deep()` 是否出現要影響同一個 rule 裡*其他*（甚至更早出現的）selector 該不該被 scoped，如果旗標是在逐個 selector 處理的過程中才算出來，等處理到後面的 selector 才發現前面該用的旗標值不對，就已經來不及了——必須先對整個 rule 做一次 pre-scan。這類問題在 review 時常被资深 reviewer 一眼看穿，因為程式碼「看起來」修好了眼前的測試案例，但明顯少了對稱的分支。

## 嚴重度
CRITICAL：（此類別在此 cluster 中未見對應到資料損毀或安全性等級的案例，不適用）
HIGH：旗標/狀態計算時機錯誤，導致同一 rule 內混用 `:deep()` 與一般 selector 時，正式輸出的 CSS scoping 悄悄錯誤（樣式外洩或誤將本該作用的樣式排除），且沒有測試涵蓋到這種多 selector 混合的情境
MEDIUM：只處理了一種 combinator/selector 變形、CSS 規範中結構相同的其他變形未處理，但需要非常規的 selector 輸入才會觸發，實務影響範圍有限

## 反例（不該報）
- 作者明確說明並得到 reviewer 認可，某個 combinator case 確實與其他 combinator 語意不同、不需要一併處理
- 純粹更新 test snapshot 以反映已經審查過的 source-preservation 修正，本身不是新邏輯
- diff 顯示的正是「把逐一計算改成先 pre-scan 整個 rule 再計算」的修正本身——這是修 bug 的 patch，不是 bug

## 出處
- https://github.com/vuejs/vue/pull/11160#discussion_r476283066
- https://github.com/vuejs/core/pull/15280#discussion_r3764329116
- https://github.com/vuejs/core/pull/15233#discussion_r3745894180
- https://github.com/vuejs/core/pull/13952#discussion_r2403655779
- https://github.com/vuejs/core/pull/13952#discussion_r2393575441
- https://github.com/vuejs/core/pull/13952#discussion_r2392036451
- https://github.com/vuejs/core/pull/13286#discussion_r2225775791
- https://github.com/vuejs/core/pull/13286#discussion_r2225746147
- https://github.com/vuejs/core/pull/13389#discussion_r2110605633
- https://github.com/vuejs/core/pull/12024#discussion_r1774566329
- https://github.com/vuejs/core/pull/12024#discussion_r1774313020
- https://github.com/vuejs/core/pull/12024#discussion_r1774285046
- https://github.com/vuejs/core/pull/11992#discussion_r1770567940
- https://github.com/vuejs/core/pull/11992#discussion_r1769696644
- https://github.com/vuejs/core/pull/11992#discussion_r1769579806
- https://github.com/vuejs/core/pull/11992#discussion_r1769577981
- https://github.com/vuejs/core/pull/11854#discussion_r1749425290
- https://github.com/vuejs/core/pull/8596#discussion_r1649818454
- https://github.com/vuejs/core/pull/8596#discussion_r1649817718
- https://github.com/vuejs/core/pull/10637#discussion_r1555253194
- https://github.com/vuejs/core/pull/10551#discussion_r1546112358
- https://github.com/vuejs/core/pull/9952#discussion_r1440240837
- https://github.com/vuejs/core/pull/8859#discussion_r1367728463
- https://github.com/vuejs/core/pull/9265#discussion_r1332924711
- https://github.com/vuejs/core/pull/8748#discussion_r1292245185
- https://github.com/vuejs/core/pull/8748#discussion_r1287984886
- https://github.com/vuejs/core/pull/7997#discussion_r1154433104
- https://github.com/vuejs/core/pull/3600#discussion_r613960300
- https://github.com/vuejs/core/pull/3600#discussion_r613947540
- https://github.com/vuejs/core/pull/3399#discussion_r593787484
- https://github.com/vuejs/core/pull/3399#discussion_r593770200
- https://github.com/vuejs/core/pull/3066#discussion_r568295111
- https://github.com/vuejs/core/pull/2632#discussion_r532917545
- https://github.com/vuejs/core/pull/1278#discussion_r455487593
- https://github.com/vuejs/core/pull/1278#discussion_r446135778
- https://github.com/vuejs/core/pull/536#discussion_r356671439
- https://github.com/vuejs/core/pull/536#discussion_r356626125
- https://github.com/vuejs/core/pull/282#discussion_r334737155
- https://github.com/vuejs/core/pull/89#discussion_r332053811
- https://github.com/vuejs/core/pull/89#discussion_r331748510
- https://github.com/vuejs/core/pull/65#discussion_r326208927
- https://github.com/vuejs/core/pull/65#discussion_r325861695
