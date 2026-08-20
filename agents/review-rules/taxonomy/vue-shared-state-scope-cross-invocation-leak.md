---
id: vue-shared-state-scope-cross-invocation-leak
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: CRITICAL
---
## 觸發訊號

當 diff 出現以下任一種情況時，要離開這段程式碼本身，去確認「這份狀態實際上被誰、在什麼時機共用」：

1. 在函式或模組的最外層新增了一個可變的 `var`/`let` 暫存變數，且這段程式碼的用途是組成字串、注入到另一個執行環境（例如 SSR template renderer 產生要塞進 HTML 的 `<script>` 內容），卻沒有用 IIFE 或閉包把它包起來 —— 要去確認這個識別字是否會外洩成該執行環境（瀏覽器頁面／全域物件）的全域變數，會不會被同頁面其他 script 或下一次呼叫覆寫、汙染。
2. 修改了一份原本由多個呼叫端共用的模組層級狀態（例如 hydration cursor、compiler 的 id 計數器、渲染 context）中，卻只針對「這一個」呼叫端加上例外安全處理、還原邏輯或旁路（例如 try/catch、local 變數暫存後又還原）—— 要去找出其他同樣讀寫這份共用狀態的呼叫端（如同一份 cursor 被 `createIf`、slots、dynamic fragments 等多處消費），確認它們是否也需要一致的處理，否則會出現「有些路徑還原了、有些沒還原」的狀態不一致。
3. 把一個原本只在單一模組／單一渲染流程內部使用的輔助函式或其參數，改成要 export 給外部套件（例如另一個 runtime package）呼叫 —— 要去確認這個 export 會不會連帶被打包進最終的全域 build（例如全域 `Vue` 物件），變成非預期地對外公開、可被任意呼叫端共用。

## 判準

共用了不該共用的狀態最危險的地方在於：問題不會在寫下這行程式碼的當下爆炸，而是在「另一個呼叫端」或「另一次呼叫／請求」發生時才顯現，而且往往是難以重現的間歇性 bug。SSR 場景尤其致命——同一個 process 服務多個並發請求，任何意外外洩到模組層級或全域 scope 的可變狀態，都可能讓 A 請求的資料混進 B 請求的回應。即使不是 SSR，共用的 cursor／context 狀態如果只有部分消費端做了正確的還原或例外處理，會讓程式在特定呼叫順序下讀到別的呼叫端留下的髒狀態，而寫程式碼的當下完全看不出來，因為每個消費端各自看都是對的。

## 嚴重度

CRITICAL：外洩或修改的是 SSR / 伺服器端 runtime 中會被多個並發請求共用的狀態（例如 process 層級的變數、模組層級的 render context），可能造成跨請求資料污染。
HIGH：修改了多個呼叫端共用的內部狀態（如 hydration cursor、compiler context），但只有這次修改的呼叫端有正確處理，其他既有消費端未同步確認，可能在特定組合情境下狀態不一致。
MEDIUM：外洩發生在單次執行、影響範圍受限的瀏覽器端 code path（例如注入後即自我刪除的 script），實務衝擊小但仍是需要修正的壞味道。

## 反例（不該報）

- 刻意設計成全域可被使用者擴充的公開型別／註冊機制（例如 `GlobalComponents`、`GlobalDirectives` 這類讓使用者透過 `declare module` 擴充的介面），這是刻意公開的 API 表面，不是意外洩漏，不該報。
- 模組層級宣告但值不可變、也不會在不同呼叫間被讀寫的常數（例如編譯期用的 regex、設定表），不構成共用狀態問題。
- 函式參數或區域變數只在單次呼叫內產生並使用、呼叫結束後即不再被任何人持有，即使變數命名看起來像是「全域」相關（如處理 `global` CSS 選擇器、`window` 上的唯讀屬性檢查），只要沒有跨呼叫或跨請求殘留，不算此類問題。

## 出處

- https://github.com/vuejs/vue/pull/6763#discussion_r143730726
- https://github.com/vuejs/core/pull/14786#discussion_r3198778105
- https://github.com/vuejs/core/pull/930#discussion_r404826529
