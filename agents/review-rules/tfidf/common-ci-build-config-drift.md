---
id: common-ci-build-config-drift
layer: common
frameworks: ["circleci", "github-actions", "yarn@*", "npm@*", "pnpm@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 修改了 CI workflow（`.circleci/config.yml`、`.github/workflows/*.yml`）或建置/測試腳本（`scripts/**/*.js`、`package.json` 的 `scripts` 欄位、jest/eslint config）當中的：cache key 組成（`checksum`、`arch`、`branch` 變數）、cache 涵蓋的 paths 清單、matrix/worker 數量、node_modules 相關路徑，或是伴隨改動一起把 `yarn.lock`/`pnpm-lock.yaml`/`package-lock.json` 整份重寫提交進來。

## 判準
這類設定變更通常沒有測試覆蓋，改錯了也不會讓當下這個 PR 直接 fail，而是之後在別的分支或別的 PR 上才會浮現「cache 沒中」「build 少了新加的 package」「用到不相容版本的依賴」等難以定位、難以歸因到這次改動的問題。資深 reviewer 會特別檢查：cache key 的 hash 來源是否真的涵蓋了會讓內容改變的檔案（例如漏了 lockfile checksum、或誤用不會變動的變數當 key）；hardcode 的數字（worker 數、matrix 長度、手動列出的 node_modules 路徑）有沒有和實際 workspace 內容同步，一旦有人加新 package 卻忘了同步更新，該 package 就永遠 cache miss 或漏建置；以及 diff 裡是否夾帶了與本次改動邏輯無關、體積巨大的 lockfile 全量重寫，這通常代表用錯了套件管理工具版本，而不是真的要升級依賴。

## 嚴重度
CRITICAL：cache key 用錯或漏掉 checksum 來源（例如 key 沒有隨 lockfile 內容變化、或誤用了會跨分支共用的 key），導致不同分支/PR 之間拿到不相容的 node_modules 或 build artifact，讓 CI 用錯版本依賴跑出偽陽性/偽陰性的測試結果。
HIGH：hardcode 的 worker 數、matrix 長度、或手動列出的 cache paths（如逐一列出 packages 目錄）沒有機制或註解提醒要跟實際 workspace 同步，新增/刪除 package 後會靜默失效而不報錯。
MEDIUM：PR 意外把整份與本次改動無關的 lockfile 重寫一併提交（並非真的更新了依賴版本），造成 diff 噪音、掩蓋實際變更、且增加合併時覆蓋他人依賴變更的風險。

## 反例（不該報）
PR 本身的目的就是升級依賴版本，lockfile 的大幅變動是預期且必要的；cache key 沿用專案既有慣例並附有清楚註解說明其正確性；重新命名 script/alias 且已同步更新所有呼叫點與文件；只是調整本地開發用的 convenience script（如加上 `--watch`、debug flag）而不影響 CI 正確性；新增的 workflow 條件判斷（如 skip CI）有清楚說明觸發時機且經過測試驗證。

## 出處
- https://github.com/react/react/pull/36456#discussion_r3304667241
- https://github.com/react/react/pull/32727#discussion_r2010886128
- https://github.com/react/react/pull/30071#discussion_r1676110425
- https://github.com/react/react/pull/29551#discussion_r1613588368
- https://github.com/react/react/pull/28773#discussion_r1575323264
- https://github.com/react/react/pull/28115#discussion_r1472083794
- https://github.com/react/react/pull/27029#discussion_r1248260166
- https://github.com/react/react/pull/25809#discussion_r1039928256
- https://github.com/react/react/pull/25285#discussion_r978040075
- https://github.com/react/react/pull/25259#discussion_r970195457
- https://github.com/react/react/pull/24533#discussion_r870253603
- https://github.com/react/react/pull/24342#discussion_r848506785
- https://github.com/react/react/pull/24172#discussion_r837515213
- https://github.com/react/react/pull/24088#discussion_r829978711
- https://github.com/react/react/pull/22517#discussion_r728137006
- https://github.com/react/react/pull/22364#discussion_r712236038
- https://github.com/react/react/pull/19566#discussion_r662362243
- https://github.com/react/react/pull/21721#discussion_r656592319
- https://github.com/react/react/pull/21700#discussion_r654599629
- https://github.com/react/react/pull/21616#discussion_r644976409
- https://github.com/react/react/pull/20720#discussion_r569443656
- https://github.com/react/react/pull/20573#discussion_r560068528
- https://github.com/react/react/pull/20581#discussion_r557408451
- https://github.com/react/react/pull/20062#discussion_r508916949
- https://github.com/react/react/pull/18545#discussion_r507989913
- https://github.com/react/react/pull/19691#discussion_r483047014
- https://github.com/react/react/pull/19184#discussion_r445601626
- https://github.com/react/react/pull/18845#discussion_r420931075
- https://github.com/react/react/pull/18531#discussion_r409223886
- https://github.com/react/react/pull/18569#discussion_r406878946
- https://github.com/react/react/pull/18569#discussion_r406870778
- https://github.com/react/react/pull/18569#discussion_r406852635
- https://github.com/react/react/pull/18070#discussion_r381548756
- https://github.com/react/react/pull/18070#discussion_r381400632
- https://github.com/react/react/pull/17653#discussion_r359599135
- https://github.com/react/react/pull/17071#discussion_r334559240
- https://github.com/react/react/pull/16338#discussion_r312595299
- https://github.com/react/react/pull/15139#discussion_r266466878
- https://github.com/react/react/pull/15022#discussion_r266039421
- https://github.com/react/react/pull/14358#discussion_r238035037
- https://github.com/react/react/pull/14280#discussion_r236011384
- https://github.com/react/react/pull/14234#discussion_r233616021
- https://github.com/react/react/pull/13751#discussion_r222373433
- https://github.com/react/react/pull/11898#discussion_r159323375
- https://github.com/react/react/pull/11794#discussion_r156084314
- https://github.com/react/react/pull/11750#discussion_r154665859
- https://github.com/react/react/pull/11487#discussion_r150209081
- https://github.com/react/react/pull/11273#discussion_r145555503
- https://github.com/react/react/pull/11223#discussion_r144947036
- https://github.com/react/react/pull/10945#discussion_r141758982
- https://github.com/react/react/pull/10792#discussion_r140921961
- https://github.com/react/react/pull/10758#discussion_r140011108
- https://github.com/react/react/pull/10592#discussion_r136636360
- https://github.com/react/react/pull/9465#discussion_r115062697
- https://github.com/react/react/pull/8745#discussion_r95800403
- https://github.com/react/react/pull/8741#discussion_r95465151
- https://github.com/react/react/pull/8648#discussion_r94506177
- https://github.com/react/react/pull/8228#discussion_r86896180
- https://github.com/react/react/pull/7747#discussion_r79950204
- https://github.com/react/react/pull/7625#discussion_r77086768
- https://github.com/react/react/pull/6882#discussion_r65261141
- https://github.com/react/react/pull/6682#discussion_r61829636
- https://github.com/react/react/pull/5089#discussion_r42128392
- https://github.com/react/react/pull/4658#discussion_r40174703
- https://github.com/react/react/pull/4458#discussion_r35282050
- https://github.com/react/react/pull/3030#discussion_r24047109
- https://github.com/react/react/pull/617#discussion_r7964979
- https://github.com/TanStack/query/pull/10283#discussion_r2950224123
- https://github.com/TanStack/query/pull/9970#discussion_r2649599678
- https://github.com/TanStack/query/pull/9502#discussion_r2232819034
- https://github.com/TanStack/query/pull/8972#discussion_r2033428204
- https://github.com/TanStack/query/pull/6836#discussion_r1488516947
- https://github.com/TanStack/query/pull/6684#discussion_r1451684119
- https://github.com/TanStack/query/pull/5813#discussion_r1280494889
- https://github.com/TanStack/query/pull/5597#discussion_r1264353396
- https://github.com/TanStack/query/pull/5134#discussion_r1137912101
- https://github.com/TanStack/query/pull/4977#discussion_r1103862288
- https://github.com/TanStack/query/pull/4768#discussion_r1063993347
- https://github.com/TanStack/query/pull/4703#discussion_r1056870067
- https://github.com/TanStack/query/pull/4364#discussion_r1010274267
- https://github.com/TanStack/query/pull/4364#discussion_r1010226875
- https://github.com/TanStack/query/pull/4364#discussion_r1004127942
- https://github.com/TanStack/query/pull/4364#discussion_r1002789357
- https://github.com/TanStack/query/pull/4364#discussion_r1002756356
- https://github.com/TanStack/query/pull/4074#discussion_r953098305
- https://github.com/TanStack/query/pull/3924#discussion_r930864341
- https://github.com/TanStack/query/pull/2688#discussion_r851793513
- https://github.com/TanStack/query/pull/3246#discussion_r795189011
- https://github.com/TanStack/query/pull/2876#discussion_r744161626
- https://github.com/TanStack/query/pull/2837#discussion_r737590877
