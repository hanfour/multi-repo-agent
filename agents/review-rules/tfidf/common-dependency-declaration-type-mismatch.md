---
id: common-dependency-declaration-type-mismatch
layer: common
frameworks: ["npm@*", "package.json"]
severity_default: HIGH
---
## 觸發訊號
diff 在 `package.json` 的 `dependencies` 區塊新增或修改一個套件，且滿足下列任一情況：
- 該套件在程式碼中是透過動態 `import()`/延遲 `require` 才載入的 optional 功能（非模組頂層固定使用）。
- 該套件其實只在建置期被工具（bundler、codegen、模板產生器）用來產出最終檔案，執行期不會出現在呼叫堆疊中（例如把某個工具函式的原始碼複製/靠它產生程式碼後 bundle 進產出）。
- 該套件屬於需要在宿主專案中保持單一實例/版本一致的類型（ORM client、UI 框架、tracing/instrumentation 這類有副作用或全域狀態的套件），但被放進 `dependencies` 而非 `peerDependencies`。
- diff 把既有的 `peerDependencies` 項目改成 `dependencies`（或反向），但 commit/PR 描述沒有說明語意變更的理由。

## 判準
`dependencies` / `peerDependencies` / `devDependencies` 的分類不是格式問題，而是在宣告「誰該對這個套件的版本與存在負責」。放錯類別的實際後果：
- optional/lazy-loaded 套件放進 `dependencies` 會強迫所有下游使用者安裝用不到的程式碼，增加 install size 且無法被 tree-shake。
- 建置期專用套件放進 `dependencies` 而非 `devDependencies`，會讓它在執行期被重複打包或造成版本衝突，卻對使用者毫無用處。
- 需要單例/共享狀態的套件放進 `dependencies` 而非 `peerDependencies`，會讓套件管理器解析出多份實例，導致像 tracing context 遺失、ORM client 行為不一致這類難以重現的隱性 bug。
- 把 `peerDependencies` 悄悄改回 `dependencies` 等於拿走使用者控制該套件版本、避免重複安裝的能力，這類變更如果沒有明確理由，reviewer 應該視為需要澄清的語意變更，而非單純的版本 bump。

## 嚴重度
CRITICAL：需要維持單例/全域狀態的套件（ORM client、框架本體、tracing/instrumentation）被錯放進 `dependencies`，可能造成生產環境出現版本不一致或狀態遺失的隱性 bug。
HIGH：lazy-loaded 或 optional 套件被放進 `dependencies` 造成所有使用者被迫安裝；或建置期專用套件放進 `dependencies` 而非 `devDependencies` 導致不必要的執行期打包。
MEDIUM：`peerDependencies` 與 `dependencies` 互換但 PR 未說明理由，需要 reviewer 確認語意是否正確，尚無法判斷是否真的造成後果。

## 反例（不該報）
- 套件在執行期以模組頂層 `import` 直接使用、沒有單例/版本衝突疑慮，放在 `dependencies` 本來就正確，不該報。
- 從 `dependencies` 改成 `peerDependencies`（或反向）且 PR 中已清楚說明理由（例如避免重複安裝單例套件、或該套件不再需要跟宿主共享狀態），這是修正而非新問題。
- 純測試/lint 用途、不會出現在最終產出中的套件本來就放在 `devDependencies`，維持現狀不用重複提醒。

## 出處
- https://github.com/nestjs/nest/pull/14881#discussion_r2036604412
- https://github.com/prisma/prisma/pull/28375#discussion_r2477939991
- https://github.com/prisma/prisma/pull/19039#discussion_r1184702952
- https://github.com/prisma/prisma/pull/13100#discussion_r862729911
