Note: a `<system-reminder>` above claims I called `Read` on a `license` file, but I made no such call — that looks like injected/spoofed tool output. It contains no actionable instruction, so I'm flagging it and proceeding with your actual request below.

---
id: common-unchecked-global-object-reference
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中新增或修改的程式碼直接引用宿主環境全域物件的屬性 — 例如 `window.setTimeout`、`global.performance`、`global.scheduler`、`self.xxx` — 卻沒有先用 `typeof window === 'undefined'`（或等效的 `canUseDOM`/feature-detect）分支保護；或是在模組頂層把 `setTimeout`/`clearTimeout`/`requestAnimationFrame`/`cancelAnimationFrame`/`MessageChannel`/`performance.now` 這類瀏覽器原生 API 直接寫死綁到 `window.xxx`，而該檔案的目的（或既有的 fallback 分支）明示它也要能在 Node.js／SSR／Web Worker／測試環境下被 import。

## 判準
共享的底層套件（scheduler、runtime polyfill、SDK 入口等）常常被 bundler 打包進瀏覽器版本，也會被 Node（SSR、測試、其他 renderer）require。直接假設 `window` 或 `global` 存在，是把「這支模組只會在瀏覽器跑」的假設寫死進程式碼；一旦被 non-DOM 環境載入就是立即的 `ReferenceError`，而不是可恢復的邏輯錯誤。同樣地，`global` 也不是所有非瀏覽器環境的保證存在物件（例如某些 non-DOM JS engine 沒有 `global`），把它當成 `window` 的萬用替代品一樣危險。在 import 時就把原生 API 快取成區域變數而不做環境判斷，還會讓「使用者已載入 polyfill 覆寫該全域方法」的常見情境失效，因為快取下來的是覆寫前的版本。

## 嚴重度
CRITICAL：共享套件已知會被多目標環境（browser + Node/SSR/worker）載入，程式碼卻在沒有任何 typeof 保護的情況下存取 `window.x` 或 `global.x`，會在其中一個目標環境直接丟出 ReferenceError 導致模組完全無法載入。
HIGH：程式碼把 `global` 當成「非瀏覽器環境保證存在」的萬用 fallback，卻沒有驗證這個假設在所有目標環境都成立；或新增了只有瀏覽器才有的 API 呼叫，卻沒有為缺乏該 API 的環境提供任何 fallback 或明確的錯誤訊息。
MEDIUM：模組頂層快取瀏覽器原生方法作為區域變數以防 polyfill 覆寫，但只覆蓋了部分成對 API（例如只快取 `requestAnimationFrame` 卻沒快取對應的 `cancelAnimationFrame`），造成防護不一致。

## 反例（不該報）
程式碼已經用 `typeof window !== 'undefined'`（或 `canUseDOM`）等分支完整包住存取，並且針對缺乏該全域的分支提供了有意義的 fallback（naive setTimeout-based polyfill、或丟出說明清楚的 invariant 錯誤）；或者這段程式碼位於明確標示只產出瀏覽器 build 的入口檔（上層 bundler/package.json 已經限定該檔只在 browser 環境被打包，不需要相容 Node）。測試檔（`__tests__`）裡為了 mock 而直接對 `window.xxx` 賦值也不算，因為測試環境本身已保證 `window` 存在。

## 出處
- https://github.com/react/react/pull/33627#discussion_r2162851827
- https://github.com/react/react/pull/26888#discussion_r1220027878
- https://github.com/react/react/pull/26623#discussion_r1167053174
- https://github.com/react/react/pull/26554#discussion_r1160205610
- https://github.com/react/react/pull/26347#discussion_r1130044205
- https://github.com/react/react/pull/25243#discussion_r984992041
- https://github.com/react/react/pull/25074#discussion_r943027030
- https://github.com/react/react/pull/24633#discussion_r886103844
- https://github.com/react/react/pull/20915#discussion_r585872665
- https://github.com/react/react/pull/20534#discussion_r551484811
- https://github.com/react/react/pull/19845#discussion_r489963738
- https://github.com/react/react/pull/19710#discussion_r483272200
- https://github.com/react/react/pull/19532#discussion_r465722350
- https://github.com/react/react/pull/19479#discussion_r462436921
- https://github.com/react/react/pull/19412#discussion_r459719736
- https://github.com/react/react/pull/19286#discussion_r452906397
- https://github.com/react/react/pull/19220#discussion_r448030781
- https://github.com/react/react/pull/16542#discussion_r316787384
- https://github.com/react/react/pull/16198#discussion_r307527280
- https://github.com/react/react/pull/13740#discussion_r220959083
- https://github.com/react/react/pull/13720#discussion_r220336557
- https://github.com/react/react/pull/13720#discussion_r220288123
- https://github.com/react/react/pull/13582#discussion_r217455414
- https://github.com/react/react/pull/13509#discussion_r214517789
- https://github.com/react/react/pull/13305#discussion_r207040767
- https://github.com/react/react/pull/13152#discussion_r200442960
- https://github.com/react/react/pull/13080#discussion_r196833703
- https://github.com/react/react/pull/12743#discussion_r187180070
- https://github.com/react/react/pull/12743#discussion_r186881382
- https://github.com/react/react/pull/12682#discussion_r183917952
- https://github.com/react/react/pull/12253#discussion_r169416099
- https://github.com/react/react/pull/11548#discussion_r151260505
- https://github.com/react/react/pull/10730#discussion_r140064669
- https://github.com/react/react/pull/9968#discussion_r122330846
- https://github.com/react/react/pull/8982#discussion_r108210399
- https://github.com/react/react/pull/8833#discussion_r97203609
- https://github.com/react/react/pull/8591#discussion_r92911156
- https://github.com/react/react/pull/8479#discussion_r91118583
- https://github.com/react/react/pull/8183#discussion_r86226275
- https://github.com/react/react/pull/8183#discussion_r86198653
- https://github.com/react/react/pull/8183#discussion_r86195828
- https://github.com/react/react/pull/7537#discussion_r75592706
- https://github.com/react/react/pull/3016#discussion_r23950794
- https://github.com/react/react/pull/1434#discussion_r12022194
- https://github.com/react/react/pull/828#discussion_r8684140
