---
id: common-es5-downlevel-emit-correctness
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH

---
## 觸發訊號
diff 改動 TypeScript 編譯器裡「會被逐字塞進使用者輸出 JS」的東西：
- `src/compiler/factory/emitHelpers.ts` 裡的 `UnscopedEmitHelper.text`（如 `__extends`、`__createBinding`、`__rest`、`__assign`、`__propKey`、`__rewriteRelativeImportExtension` 等 `var __xyz = (this && this.__xyz) || function (...) {...}` 樣板字串）
- transformer（`es2015.ts`、`destructuring.ts`、`declarations.ts` 等）裡針對 ES5/ES3 target 的 downlevel 邏輯（class/binding pattern/for-in/keyword 判斷）
- 對應的 `tests/baselines/reference/*.js`、`*.errors.txt` baseline 變更，尤其是牽涉到 line-ending 正規化（`\r`/`\r\n`）、`.d.ts` emit 是否該重複某段邏輯、或 baseline 是否還在測到原本要測的東西

## 判準
這些 helper 字串和 downlevel 邏輯會被原封不動塞進任意使用者專案的輸出 JS，編譯器團隊自己不會大規模跑到這些路徑，所以任何邏輯偏差（`indexOf(p) === -1` vs `!indexOf(p)`、`typeof x === "symbol"`、getter/value descriptor 判斷、contextual keyword 沒被排除、astral/unicode identifier 在 ES5 下解析失敗）都會安靜地在使用者端炸掉，而不是在 CI 裡被抓到。同樣地，baseline 測試如果因為正規化（`\r\n?` → `\n`）而蓋掉了真正要驗證的行為，等於這條測試名存實亡，之後任何回歸都不會被攔下。

## 嚴重度
CRITICAL：helper 或 downlevel 邏輯在常見情境下就產生錯誤的執行期行為（例如破壞 live binding、破壞 getter re-export 語意、產生非法語法導致 `SyntaxError`）。
HIGH：只在邊界情境失效（contextual keyword、astral identifier、symbol key、罕見的 for-in 解構），或 baseline 因正規化而遺失了原本要驗證的覆蓋率。
MEDIUM：純粹的 style/長度優化（如把 `!e.indexOf(p)` 換成 `e.indexOf(p) === -1` 純粹是可讀性），不影響行為。

## 反例（不該報）
- 單純因為上游 helper 文字或 transformer 邏輯已審查通過而機械性重新產生的 baseline 快照（no-op regeneration）。
- 新增的 helper 字串是被新的、尚未預設開啟的 compiler flag 保護，且沒有既有程式碼路徑會觸發。
- 純粹的依賴版本號調整（如 `package-lock.json` 裡 semver range 誤寫，本質是打包工具問題，不是 downlevel 邏輯問題）——除非它同時影響 helper 產出的執行期行為。

## 出處
- https://github.com/microsoft/TypeScript/pull/62987#discussion_r2692485734
- https://github.com/microsoft/TypeScript/pull/59767#discussion_r1927395179
- https://github.com/microsoft/TypeScript/pull/55887#discussion_r1340538168
- https://github.com/microsoft/TypeScript/pull/54801#discussion_r1244328894
- https://github.com/microsoft/TypeScript/pull/54218#discussion_r1191690487
- https://github.com/microsoft/TypeScript/pull/52544#discussion_r1093567141
- https://github.com/microsoft/TypeScript/pull/50820#discussion_r1014430409
- https://github.com/microsoft/TypeScript/pull/50918#discussion_r984060652
- https://github.com/microsoft/TypeScript/pull/50915#discussion_r979051265
- https://github.com/microsoft/TypeScript/pull/49705#discussion_r960100755
- https://github.com/microsoft/TypeScript/pull/46997#discussion_r766947545
- https://github.com/microsoft/TypeScript/pull/46472#discussion_r734097328
- https://github.com/microsoft/TypeScript/pull/42029#discussion_r550692000
- https://github.com/microsoft/TypeScript/pull/36727#discussion_r377388695
- https://github.com/microsoft/TypeScript/pull/32944#discussion_r314919358
- https://github.com/microsoft/TypeScript/pull/31480#discussion_r286252817
- https://github.com/microsoft/TypeScript/pull/25580#discussion_r201846921
- https://github.com/microsoft/TypeScript/pull/21974#discussion_r171123011
- https://github.com/microsoft/TypeScript/pull/12488#discussion_r90942434
- https://github.com/microsoft/TypeScript/pull/12248#discussion_r87931020
- https://github.com/microsoft/TypeScript/pull/2901#discussion_r29300025
- https://github.com/microsoft/TypeScript/pull/2588#discussion_r27627752
- https://github.com/microsoft/TypeScript/pull/2355#discussion_r26442543
- https://github.com/microsoft/TypeScript/pull/2308#discussion_r26316520
- https://github.com/microsoft/TypeScript/pull/2283#discussion_r26098394
- https://github.com/microsoft/TypeScript/pull/1129#discussion_r20238442
- https://github.com/microsoft/TypeScript/pull/577#discussion_r17089560
- https://github.com/microsoft/TypeScript/pull/158#discussion_r15140206
