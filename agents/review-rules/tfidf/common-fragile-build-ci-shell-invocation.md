---
id: common-fragile-build-ci-shell-invocation
layer: common
frameworks: ["node:child_process@*", "github-actions@*"]
severity_default: MEDIUM

---
## 觸發訊號
diff 修改的是建置/CI/測試基礎設施檔案（Gulpfile.*、Jakefile.*、Herebyfile.mjs、scripts/**/*.{js,mjs,ts}、.github/workflows/*.yml、Dockerfile、CONTRIBUTING*.md 裡的指令範例），且新增或改動了對外部程序的呼叫：`child_process.exec/execSync/spawn/spawnSync`、CI step 的 `run:` 呼叫 npm/git/docker，尤其符合以下任一模式：
- 用 stdout/stderr 的字串內容（例如 `!!stdout`、`stdout.indexOf(...)`）而不是 process 的 exit code / callback `err` 來判斷指令成功與否
- `npm ci` 與 `npm install` 互換，但沒有說明是否要改變「鎖定 lockfile 精確安裝」這個語意
- 自動化 script 裡對 `git add` 的檔案清單增減（例如漏加 `package-lock.json`、`--force` 加進被 gitignore 的產物）
- 用字串拼接組出 shell 指令並搭配 `shell: true` 或 `/bin/sh -c`，而變數來源不是常數
- CI matrix / 版本清單變更（Node 版本、平台組合）但沒有更新對應被 skip 的條件式或註解

## 判準
建置與 CI script 是「日常看不到、只有壞掉時才會被注意到」的程式碼，資深 reviewer 對這類 diff 特別敏感是因為：
- exit code 才是 process 是否成功的權威訊號；用 stdout 內容猜測（有沒有輸出、有沒有某個字串）在 npm/git 版本更新後很容易失準，而且失敗時往往是「安靜地當成功繼續跑」，不會有測試能抓到
- `npm ci` 對 CI 可重現性至關重要（嚴格依照 lockfile、不會重寫它）；換成 `npm install` 會讓 CI 的相依版本隨 registry 狀態漂移，通常是無意間退化
- 自動化 version bump / release script 若沒有把 lockfile 一起 commit，會讓 release branch 處於「package.json 版本改了但 lockfile 沒跟上」的不一致狀態，這是這個專案過去實際發生過的事故模式
- 用字串拼接 + `shell: true` 執行外部指令，只要有一個變數的來源不是寫死常數，就是指令注入風險，而且通常沒有測試會覆蓋到惡意輸入路徑

## 嚴重度
CRITICAL：字串拼接組出的 shell 指令搭配 `shell: true`／`exec()`，且被拼接的變數來自不受信任或非常數來源（例如外部輸入、依賴套件內容），構成指令注入風險；或 release/publish pipeline 的改動可能讓未經完整測試矩陣驗證的版本被發佈出去
HIGH：外部程序成功/失敗的判斷從 exit code 改成靠 stdout 內容猜測，會導致 CI 在指令實際失敗時仍安靜地視為成功繼續往下跑
MEDIUM：`npm ci`/`npm install` 互換未說明理由、自動化 commit script 的 `git add` 清單漏掉相關產物（如 lockfile）、CI matrix 變更後遺留過期註解或未同步的 skip 條件

## 反例（不該報）
- 純格式/縮排調整（例如 yaml 的縮排改變只是「格式本來就長這樣」），沒有改變任何指令或邏輯
- 只是移動/整理既有 comment、reorder import 或調整 log 訊息文字，行為完全不變
- 開放性提問或請其他人確認的討論串（例如「更熟悉這段的人可以看一下嗎」「我們是不是應該用 X」），這是 reviewer 自己還不確定、尚未收斂成明確缺陷的討論，不代表已認定的問題，不該被當成待報告的 finding
- 在測試/沙盒用途的 Dockerfile 或一次性腳本裡使用較寬鬆的錯誤處理，且該腳本失敗時有外層機制（CI 整體綠燈判斷、baseline diff）會攔截，不构成安靜失敗風險

## 出處
- https://github.com/microsoft/TypeScript/pull/63097#discussion_r2766292925
- https://github.com/microsoft/TypeScript/pull/59635#discussion_r1758233195
- https://github.com/microsoft/TypeScript/pull/59013#discussion_r1653085537
- https://github.com/microsoft/TypeScript/pull/54820#discussion_r1291743230
- https://github.com/microsoft/TypeScript/pull/54499#discussion_r1214707129
- https://github.com/microsoft/TypeScript/pull/53248#discussion_r1137737828
- https://github.com/microsoft/TypeScript/pull/53248#discussion_r1135887746
- https://github.com/microsoft/TypeScript/pull/52945#discussion_r1116409342
- https://github.com/microsoft/TypeScript/pull/52373#discussion_r1084365246
- https://github.com/microsoft/TypeScript/pull/51965#discussion_r1052717495
- https://github.com/microsoft/TypeScript/pull/51461#discussion_r1017322324
- https://github.com/microsoft/TypeScript/pull/48865#discussion_r866214506
- https://github.com/microsoft/TypeScript/pull/45069#discussion_r680233791
- https://github.com/microsoft/TypeScript/pull/44324#discussion_r647459518
- https://github.com/microsoft/TypeScript/pull/43931#discussion_r625437031
- https://github.com/microsoft/TypeScript/pull/42701#discussion_r575568165
- https://github.com/microsoft/TypeScript/pull/42431#discussion_r562260182
- https://github.com/microsoft/TypeScript/pull/39898#discussion_r527833159
- https://github.com/microsoft/TypeScript/pull/40576#discussion_r490401299
- https://github.com/microsoft/TypeScript/pull/36190#discussion_r367099722
- https://github.com/microsoft/TypeScript/pull/33791#discussion_r331241576
- https://github.com/microsoft/TypeScript/pull/33584#discussion_r329167222
- https://github.com/microsoft/TypeScript/pull/33586#discussion_r328409230
- https://github.com/microsoft/TypeScript/pull/31893#discussion_r302312783
- https://github.com/microsoft/TypeScript/pull/31948#discussion_r295911183
- https://github.com/microsoft/TypeScript/pull/29933#discussion_r257349447
- https://github.com/microsoft/TypeScript/pull/23972#discussion_r187157752
- https://github.com/microsoft/TypeScript/pull/22420#discussion_r183179290
- https://github.com/microsoft/TypeScript/pull/20763#discussion_r157849361
- https://github.com/microsoft/TypeScript/pull/20451#discussion_r154767209
- https://github.com/microsoft/TypeScript/pull/18956#discussion_r143875416
- https://github.com/microsoft/TypeScript/pull/16342#discussion_r120778243
- https://github.com/microsoft/TypeScript/pull/12163#discussion_r87519703
- https://github.com/microsoft/TypeScript/pull/12014#discussion_r86293358
- https://github.com/microsoft/TypeScript/pull/10673#discussion_r77278941
- https://github.com/microsoft/TypeScript/pull/9439#discussion_r69999112
- https://github.com/microsoft/TypeScript/pull/9068#discussion_r68281155
- https://github.com/microsoft/TypeScript/pull/9068#discussion_r67583319
- https://github.com/microsoft/TypeScript/pull/9068#discussion_r66644938
- https://github.com/microsoft/TypeScript/pull/8925#discussion_r65752654
- https://github.com/microsoft/TypeScript/pull/7675#discussion_r57388961
- https://github.com/microsoft/TypeScript/pull/38#discussion_r15079620
