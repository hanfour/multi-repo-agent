---
id: common-lookbehind-regex-compat
layer: common
frameworks: ["javascript@*", "typescript@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 裡新增或修改的正規表達式字面量使用了 lookbehind 語法 `(?<=...)` 或 `(?<!...)`（正/負向皆算），尤其是把既有的 `(?:^|...)` 之類非捕獲群組寫法改寫成 lookbehind 的變更。

## 判準
Lookbehind assertion 是 ES2018 才引入的語法，比 lookahead（`(?=...)`/`(?!...)`）晚很多年才被各引擎支援。若專案的 build target 低於 ES2018（例如常見的 ES2016），這段正則字面量會被 esbuild/babel 等工具轉譯成 `RegExp` 建構式呼叫並依賴 polyfill；若目標執行環境（尤其舊版瀏覽器）沒有該 polyfill 或轉譯配置不完整，會直接在 runtime 丟出 SyntaxError 或行為錯誤。這類寫法之所以危險，是因為本地開發、測試環境通常用新版 Node/瀏覽器,問題只在特定舊瀏覽器上才會爆炸,很難被一般 CI 抓到。此外，改寫時若把原本沒必要的 capture group 也一併留著、或誤植成 lookbehind 而不是原本意圖的 lookahead,都是常見的順手錯誤。

## 嚴重度
CRITICAL：專案明確聲明支援不含 lookbehind 的舊瀏覽器（如 Safari < 16.4、部分 iOS WebView）,且該正則在生產環境關鍵路徑上執行,又沒有對應的 polyfill 或 build target 檢查。
HIGH：build target（tsconfig/esbuild/babel target）低於 ES2018 而正則使用了 lookbehind,即使目前是 dev-only 或非關鍵路徑,因為一旦被其他呼叫方複製到熱路徑就會出事,且此類 compat 問題通常要等到實際舊裝置上才會被發現。
MEDIUM：功能與相容性目標一致（build target ≥ ES2018 或明確只跑在現代 runtime，如 Node.js 服務端代碼）,但改寫引入了不必要的 capture group,或者把 lookahead/lookbehind 用反了造成語意錯誤（如本例最初把 lookahead 誤植為 lookbehind）。

## 反例（不該報）
- 正則只在 Node.js 服務端或建置腳本執行，不經過 browser bundler/target 轉譯，沒有舊瀏覽器相容性疑慮。
- 專案 tsconfig/babel target 已明確設定為 ES2018 以上，且 CI 或 lint 規則已驗證所有正則語法與該 target 相容。
- 使用的是 lookahead（`(?=...)`/`(?!...)`）而非 lookbehind——lookahead 相容性遠早於 lookbehind，不受本規則影響。

## 出處
- https://github.com/vuejs/core/pull/13567#discussion_r2185003346
- https://github.com/vuejs/core/pull/13567#discussion_r2184994803
- https://github.com/vuejs/core/pull/13567#discussion_r2184953826
- https://github.com/vuejs/core/pull/13567#discussion_r2184946277
- https://github.com/vuejs/core/pull/13567#discussion_r2184936073
