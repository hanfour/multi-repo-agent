---
id: common-monorepo-build-config-source-of-truth
layer: common
frameworks: ["rollup@*", "npm/pnpm/yarn workspaces@*"]
severity_default: HIGH
---
## 觸發訊號
Diff 修改的是 monorepo 的建置/發佈設定檔，且出現以下任一模式：
- `rollup.config.js`／`scripts/build.js` 等建置腳本裡 `require(...)` 某個子套件的 `package.json` 只為了取 `version`，而不是用 `lerna.json`（或 root 的單一版本來源）
- `package.json` 的 `unpkg`／`jsdelivr`／`main`／`module`／`types` 等發佈欄位手動填一條 dist 路徑字串，卻沒有對照實際 build 輸出的檔名/目錄結構
- 對一個 `"private": true` 且不會被發佈的 workspace 套件（如 playground、examples）新增 `devDependencies`，而該套件其實是透過 root/workspace 的相依直接可用（例如 `execa` 已裝在 root）
- 建置設定（`rollup.config.js`、`scripts/utils.js` 裡判斷是否打包的邏輯）用多個條件變數重複表達同一件事，而不是化簡成單一來源判斷

## 判準
Monorepo 裡版本號、dist 路徑、相依套件應該只有一個權威來源。任何地方各自硬編或重複宣告，遲早會在某次只改了其中一處之後失同步：CDN 欄位指向不存在的檔案會讓外部使用者直接壞掉、版本來源分歧會讓發佈時各 package 版本不一致、workspace 套件裡多裝一份已存在的相依會造成版本漂移與不必要的安裝體積。這類問題在 code review 當下往往看起來只是"多寫一行沒差"，但因為它們只在 build/release 流程裡才會顯形，很容易被合併後才發現。

## 嚴重度
CRITICAL：`unpkg`／`jsdelivr`／`main` 等發佈欄位路徑與實際 build 輸出不符，會直接讓外部使用者（CDN、npm 安裝者）拿到 404 或載入錯誤檔案。
HIGH：版本號取自非單一權威來源（例如個別子套件的 `package.json` 而非 `lerna.json`），發佈時可能造成各 package 版本不同步。
MEDIUM：在不會發佈的 private workspace 套件裡新增其實 root 已提供的 devDependency，或建置判斷邏輯有可化簡的重複條件。

## 反例（不該報）
- 該套件本來就是獨立發佈、不屬於共享 monorepo 版本管理的情境，自己維護 `version`/`devDependencies` 是合理的
- Private workspace 套件確實需要與 root 不同版本的相依（例如需要鎖定特定版本做相容性測試）而刻意新增
- 只是把既有正確路徑的欄位重新排版/搬動位置，內容沒有改變

## 出處
- https://github.com/vuejs/vue/pull/12669#discussion_r922674973
- https://github.com/vuejs/vue/pull/4731#discussion_r96550796
- https://github.com/vuejs/vue/pull/4573#discussion_r93880528
- https://github.com/vuejs/vue/pull/118#discussion_r9910805
- https://github.com/vuejs/vue/pull/118#discussion_r9910512
- https://github.com/vuejs/core/pull/14443#discussion_r2786869144
- https://github.com/vuejs/core/pull/13630#discussion_r2211974480
- https://github.com/vuejs/core/pull/11520#discussion_r1709556143
- https://github.com/vuejs/core/pull/11520#discussion_r1709552837
- https://github.com/vuejs/core/pull/5821#discussion_r1617869150
- https://github.com/vuejs/core/pull/9894#discussion_r1436269177
- https://github.com/vuejs/core/pull/9306#discussion_r1367714913
- https://github.com/vuejs/core/pull/9306#discussion_r1367367661
- https://github.com/vuejs/core/pull/8989#discussion_r1300831068
- https://github.com/vuejs/core/pull/8989#discussion_r1299717436
- https://github.com/vuejs/core/pull/8545#discussion_r1265577208
- https://github.com/vuejs/core/pull/8779#discussion_r1263340465
- https://github.com/vuejs/core/pull/8545#discussion_r1260514646
- https://github.com/vuejs/core/pull/8283#discussion_r1198455633
- https://github.com/vuejs/core/pull/7761#discussion_r1115530188
- https://github.com/vuejs/core/pull/7678#discussion_r1110469659
- https://github.com/vuejs/core/pull/7176#discussion_r1026978654
- https://github.com/vuejs/core/pull/6990#discussion_r1008828228
- https://github.com/vuejs/core/pull/4176#discussion_r674672835
- https://github.com/vuejs/core/pull/3823#discussion_r638088325
- https://github.com/vuejs/core/pull/3823#discussion_r637680574
- https://github.com/vuejs/core/pull/3185#discussion_r581164164
- https://github.com/vuejs/core/pull/254#discussion_r334518618
- https://github.com/vuejs/core/pull/254#discussion_r334314299
- https://github.com/vuejs/core/pull/241#discussion_r334239679
- https://github.com/vuejs/core/pull/85#discussion_r331741537
