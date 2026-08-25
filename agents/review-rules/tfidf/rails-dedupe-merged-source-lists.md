---
id: rails-dedupe-merged-source-lists
layer: rails
frameworks: ["rails@*"]
severity_default: LOW
---
## 觸發訊號
diff 中新增或修改「合併多個來源清單」的邏輯：把多組 sources/dependencies/tags/paths 陣列組合成最終結果（例如 wildcard 清單 + explicit 清單合併、多個 helper 收集的 `sources`、`map { }.flatten` 這種先映射再展平的寫法），且合併後沒有呼叫 `.uniq` 去重；或是可以直接用 `flat_map` 取代 `map { ... }.flatten` 卻沒有這樣寫。

## 判準
合併多來源清單時若不去重，重複項目會悄悄流入最終輸出——重複的 HTML tag、重複的 HTTP header（如 Early Hints 的 `Link`）、重複的相依追蹤項目——造成多餘的副作用或效能浪費，而且這類 bug 很難從單元測試裡看出來，因為輸入通常剛好不重複。`map { }.flatten` 相對 `flat_map` 則是可讀性與意圖表達的問題：讀者要多想一層「為什麼要 flatten」，且容易在後續修改時忘記同步處理巢狀層級。

## 嚴重度
CRITICAL：去重缺失會造成有實際成本的重複外部呼叫（例如重複觸發第三方 API、重複計費、重複寫入）。
HIGH：去重缺失會造成使用者可觀察到的功能錯誤（重複的 DOM 節點、重複的 response header、快取/相依追蹤因重複項目而誤判）。
MEDIUM：純粹是 `map { }.flatten` 可以簡化成 `flat_map`，但目前功能正確、無重複風險。

## 反例（不該報）
- 來源清單在更早的步驟已經保證唯一（例如已經過 `Set`、資料庫 `DISTINCT`、或上游明確 dedupe）。
- `map` 之後沒有巢狀陣列可以 flatten（換句話說根本不是 map+flatten 模式，只是普通 `map`）。
- 合併的清單語意上允許重複且重複是預期行為（例如刻意疊加權重、統計次數）。

## 出處
- https://github.com/rails/rails/pull/56991#discussion_r2940418880
- https://github.com/rails/rails/pull/51712#discussion_r1791085052
- https://github.com/rails/rails/pull/51936#discussion_r1631041216
- https://github.com/rails/rails/pull/51628#discussion_r1591023778
- https://github.com/rails/rails/pull/51341#discussion_r1532461739
- https://github.com/rails/rails/pull/48193#discussion_r1191937406
- https://github.com/rails/rails/pull/30744#discussion_r141714052
- https://github.com/rails/rails/pull/30084#discussion_r133272303
- https://github.com/rails/rails/pull/26226#discussion_r76838255
- https://github.com/rails/rails/pull/20904#discussion_r35363151
