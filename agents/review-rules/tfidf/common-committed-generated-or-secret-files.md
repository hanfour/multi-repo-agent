---
id: common-committed-generated-or-secret-files
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 中出現以下任一情況：
- 新增的檔案路徑明顯是工具產出物（含 `/generated/`、`.generated/`、`dist/`、`build/`、codegen 產物如 prisma client、schema engine bindings、`package-lock.json`／`yarn.lock` 等），且沒有對應的 `.gitignore` 排除規則。
- `.gitignore` 被修改為移除或縮窄既有規則（例如刪掉 `package-lock.json`、`*.db` 這類條目），導致原本被忽略的檔案現在可被追蹤、進而出現在後續 commit 中。
- 新增或修改的檔案內容含有可用的憑證／連線字串（例如 `.env`、`.envrc`、含 `postgres://user:pass@`、`mysql://user:pass@`、API key、token 的設定檔）。
- 同一個生成檔案在歷史上已被移除過，卻又在新 PR 中重新出現（reviewer 留言「why is this showing up again」類型）。

## 判準
生成檔案不該進 code review：它們不是人手寫的，審查它們浪費時間、又會隨每次 build 產生雜訊 diff，且容易在多人協作時因為各自本地重新生成而產生無意義衝突，正確做法是靠 build step 重新產生、不進版控。`.gitignore` 規則被縮窄或和其他 repo／子資料夾不一致，代表下一次某人 commit 時該檔案會悄悄被追蹤，是系統性風險而不是單一失誤。憑證外洩到 git 是複合性風險：git 歷史很難完全清除（需要 force-push/改寫歷史），而且掃描機器人通常在數分鐘內就會抓到公開 repo 裡的金鑰字串，代表即使事後刪除也視同已外洩，需要立即輪替金鑰。

## 嚴重度
CRITICAL：新增/變更的檔案含有真實可用的憑證、API key、連線字串（尤其是資料庫密碼、雲端服務 token）且已推送到遠端（尤其是 public repo）。
HIGH：`.gitignore` 規則被移除或縮窄，且沒有在 PR 描述/commit message 中說明原因，導致原本被忽略的類別（lockfile、生成程式碼、db fixture）變成可被追蹤；或整個 build 輸出目錄被整批 commit 進 repo。
MEDIUM：單一生成檔案意外重新出現在 diff 中，但不含機密內容、也非系統性的 `.gitignore` 變更，判斷上較可能只是單次疏漏（例如忘了 `git add` 前先確認 ignore 狀態）。

## 反例（不該報）
- 團隊明確決定要把某個生成檔案 check in（例如做為建置策略的一部分，並在檔案內留下「此檔案是由 X 生成」的說明註解），且該決定在 PR 討論中有明確共識。
- `.gitignore` 的 pattern 因為和合法的測試 fixture 檔名衝突（例如 `*.db` 誤傳到需要被追蹤的 fixture db 檔）而被縮窄，這是修正 false positive，不是憑證或生成檔外洩問題。
- 純粹修改使用者可見的說明文字/警告訊息（例如調整 CLI 印出的「別忘了把 `.env` 加進 `.gitignore`」提示文案），本身沒有新增任何被忽略類別的檔案。
- 新增一個測試需要的、非生成、也不含機密的一般設定檔或 fixture 檔案。

## 出處
- https://github.com/nestjs/nest/pull/250#discussion_r151693060
- https://github.com/prisma/prisma/pull/27801#discussion_r2291177736
- https://github.com/prisma/prisma/pull/27331#discussion_r2131959765
- https://github.com/prisma/prisma/pull/26782#discussion_r2021160880
- https://github.com/prisma/prisma/pull/22700#discussion_r1457646679
- https://github.com/prisma/prisma/pull/20507#discussion_r1282000665
- https://github.com/prisma/prisma/pull/13926#discussion_r902682443
- https://github.com/prisma/prisma/pull/13712#discussion_r895472765
- https://github.com/prisma/prisma/pull/3585#discussion_r487079085
