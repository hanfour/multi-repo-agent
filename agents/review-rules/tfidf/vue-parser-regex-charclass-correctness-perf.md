---
id: vue-parser-regex-charclass-correctness-perf
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: MEDIUM
---
## 觸發訊號
diff 在編譯期 parser/工具函式（如 `src/compiler/parser/index.js`、`src/core/util/lang.js` 這類每次 template/expression 解析都會跑到的熱路徑）新增或修改用來比對空白字元、識別字元（unicode letters）、修飾詞（modifier）等的正則表達式，且：
- 直接用 `\s`、`\w` 等 JS 內建字元類別，卻其實是在比對 HTML/DOM 規格定義的字元集合（例如「space characters」）
- 手刻 unicode range（如 `\u10000-\uEFFFF`）或修改既有 range，卻沒有註明依據哪份規格
- 引入巢狀量詞的 pattern（例如 `(\.[^.\]]+)+$`）取代原本較簡單的寫法
- PR description / commit / comment 裡完全沒有 benchmark 數據或規格連結佐證這個改動

## 判準
這些正則都在編譯期熱路徑上，每次 parse 都會執行，兩件事都會出錯而且不容易在功能測試中發現：
1. **語意正確性**：JS 的 `\s` 涵蓋的字元集合跟 HTML spec 定義的「space characters」不是同一組（例如某些 unicode 空白 JS 認、HTML 不認，反之亦然），直接借用會讓 parser 跟瀏覽器原生行為不一致，只在特定邊界字元的 template 才會炸，回歸測試很難覆蓋到。
2. **效能**：這類正則是逐字元掃過整個 template/expression 字串，換一種字元類別寫法（尤其是加大 unicode range 或改成巢狀量詞）效能差異可以是數倍，而且各瀏覽器引擎（V8 vs JSC/Safari）對同一 pattern 的優化程度不同，光看邏輯正確无法判斷效能是否退化，必須實測。巢狀量詞這類寫法還有觸發 catastrophic backtracking 的風險。

## 嚴重度
CRITICAL：正則改動會在使用者可控的 template/expression 輸入上造成 catastrophic backtracking（ReDoS 風險），或造成解析結果錯誤導致 XSS 之類安全問題。
HIGH：正則語意跟其宣稱依循的規格（HTML spec 的 space characters、custom element name 規則等）不一致，會讓合法輸入被 parser 判斷錯誤（比如某些非破壞性空白被吃掉或漏判 modifier 邊界）。
MEDIUM：純粹是熱路徑正則改動缺乏 benchmark 佐證，或 unicode range 修改沒說明取捨依據，可能有效能退化但目前沒有已知的錯誤解析案例。

## 反例（不該報）
- 正則只在非熱路徑、低頻執行的程式碼裡使用（例如建置腳本、CLI 參數解析、一次性的 dev-only 工具），效能跟規格一致性不是核心考量。
- 改動的正則本來就沒有宣稱要對齊某個外部規格（純內部命名慣例、非 DOM/HTML 相關的字串處理），用 `\s`/`\w` 是合理選擇。
- PR 裡已經附上 benchmark 連結或明確引用規格章節作為依據（如本組意見裡開發者最終採納的作法），這種情況是規則被正確遵守，不該報。

## 出處
- https://github.com/vuejs/vue/pull/11065#discussion_r373861780
- https://github.com/vuejs/vue/pull/9585#discussion_r260803902
- https://github.com/vuejs/vue/pull/8666#discussion_r240129849
