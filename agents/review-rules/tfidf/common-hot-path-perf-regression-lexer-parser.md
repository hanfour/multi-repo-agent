---
id: common-hot-path-perf-regression-lexer-parser
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
diff 修改的是編譯器/直譯器最熱的路徑（scanner、parser、checker 裡逐字元、逐 token、逐 AST node 都會呼叫到的函式），且出現下列任一模式：
- 移除或簡化了既有的提前返回／guard 判斷（例如 `if (location.flags & NodeFlags.Ambient) return;` 這類早退檢查），PR 描述或 commit message 沒有附上 profiling／benchmark 數據。
- 在會被大量重複呼叫的函式內（例如每個 token、每個診斷訊息、每次 `getSpanOfTokenAtPosition` 之類的呼叫）新建一個 scanner／parser 之類的重量級物件實例。
- 用一般正則表達式（例如 `/\s+$/g`）取代針對字元逐一掃描的手寫迴圈或原生 `.trim()`/`.trimEnd()`/`.trimStart()`，且該正則會在熱迴圈裡對長字串重複套用。
- 把原本用 `+=` 累加字串的寫法改成陣列 push 後 `join`，或反之，發生在會被大量呼叫的 comment/trivia 收集函式裡。

## 判準
這些函式的呼叫次數是「整個程式的每個 token／每個節點」量級，任何一次額外配置或一次 O(n²) 退化在小型測試檔案上完全看不出來，甚至粗粒度的 perf test 套件也未必能量到差異，只有在真實世界的大型專案上跑 profiling 才會現形。資深 reviewer 之所以在這類 diff 上特別敏感，是因為他們見過「功能上等價、看起來只是小重構」的改動實際上讓編譯時間明顯變慢，而且沒有測試會失敗去攔住它——所以會要求提供效能證據，而不是單純信任邏輯等價。

## 嚴重度
CRITICAL：在 checker/parser/scanner 的核心熱迴圈中引入了會隨輸入規模造成 O(n²) 或無界重複配置的操作（例如迴圈內對長字串套用簡易正則、或每次呼叫都重新建立 scanner），且沒有任何效能佐證。
HIGH：移除或改寫了既有的提前返回／guard check、或改變了熱路徑上物件建立/字串累加的策略，功能上聲稱等價，但 PR 未附上 profiling 或 benchmark 數據證明不影響整體編譯效能。
MEDIUM：改動位於熱路徑但呼叫頻率相對較低（例如僅在解析失敗時才觸發的 diagnostic-only 分支），效能影響不確定，缺乏效能佐證但風險較低。

## 反例（不該報）
- 改動發生在只執行一次或呼叫頻率極低的程式碼（例如使用者顯式呼叫的公開 API、find-all-references 這類非逐 token 熱迴圈的服務層邏輯、測試 baseline 產生、trace.json 輸出），不算熱路徑。
- PR 已經附上 profiling／benchmark 數據，證明改動對整體編譯效能沒有顯著退化（即使肉眼看起來像新增了正則或物件建立）。
- 純粹的可讀性重構，且邏輯與呼叫頻率都與原本完全等價（例如把巢狀 `if` 改成 guard clause，但沒有新增或移除任何提前返回、沒有改變物件生命週期），不在此規則範圍。
- 使用原生 `.trim()`/`.trimEnd()`/`.trimStart()`（有 polyfill fallback）取代舊有簡易正則，這是效能改善方向，不是退化，不該報。

## 出處
- https://github.com/microsoft/TypeScript/pull/59325#discussion_r1681625610
- https://github.com/microsoft/TypeScript/pull/58295#discussion_r1578478543
- https://github.com/microsoft/TypeScript/pull/57110#discussion_r1475389316
- https://github.com/microsoft/TypeScript/pull/55790#discussion_r1332000988
- https://github.com/microsoft/TypeScript/pull/52710#discussion_r1145439966
- https://github.com/microsoft/TypeScript/pull/53081#discussion_r1126940828
- https://github.com/microsoft/TypeScript/pull/52710#discussion_r1102191977
- https://github.com/microsoft/TypeScript/pull/47822#discussion_r814153410
- https://github.com/microsoft/TypeScript/pull/45818#discussion_r726511381
- https://github.com/microsoft/TypeScript/pull/44197#discussion_r637252464
- https://github.com/microsoft/TypeScript/pull/43312#discussion_r599145667
- https://github.com/microsoft/TypeScript/pull/43312#discussion_r598945979
- https://github.com/microsoft/TypeScript/pull/41877#discussion_r595367270
- https://github.com/microsoft/TypeScript/pull/41877#discussion_r539143211
- https://github.com/microsoft/TypeScript/pull/41115#discussion_r511153859
- https://github.com/microsoft/TypeScript/pull/40105#discussion_r471923375
- https://github.com/microsoft/TypeScript/pull/36106#discussion_r365430728
- https://github.com/microsoft/TypeScript/pull/32720#discussion_r310820512
- https://github.com/microsoft/TypeScript/pull/31078#discussion_r278203463
- https://github.com/microsoft/TypeScript/pull/16274#discussion_r126550586
- https://github.com/microsoft/TypeScript/pull/7213#discussion_r54135540
- https://github.com/microsoft/TypeScript/pull/3266#discussion_r31086441
- https://github.com/microsoft/TypeScript/pull/1781#discussion_r24713539
