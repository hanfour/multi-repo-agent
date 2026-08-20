---
id: common-vet-third-party-code-trust-and-license
layer: common
frameworks: ["*"]
severity_default: CRITICAL

---
## 觸發訊號
diff 中新增或修改 CI workflow，使用非官方、非知名廠商維護的第三方 GitHub Action（不是 `actions/*`、`docker/*`、`aws-actions/*` 等），且該 Action 被賦予寫入權限（`contents: write`、可直接 commit/push、可存取具寫入權限的 `secrets.GITHUB_TOKEN`）；或者 diff 中新增的程式碼、測試、文件包含從其他開源專案複製貼上的實質邏輯或資料，卻沒有附上來源專案名稱、連結與授權條款文字。

## 判準
兩種情況本質相同：引入不受自己掌控的第三方資產，卻沒有建立對應的信任邊界。CI Action 若能以 repo 的 `GITHUB_TOKEN` 執行任意程式碼並 push commit，等於把 repo 的寫入權限交給一個我們不審核、版本不受控的第三方維護者，一旦該 Action 被供應鏈攻擊劫持，就能直接污染主 branch，且日誌通常不會留下明顯痕跡。複製他人程式碼卻不附授權文字，則是違反授權條款（如 MIT 要求「附隨授權聲明」）的法律義務，事後補救成本高。共通判準：任何跨越信任邊界引入的外部資產（可執行的 Action、抄來的程式碼），都必須標註來源、附上授權文字，並把被賦予的權限限制到最小必要範圍。

## 嚴重度
CRITICAL：CI/CD workflow 授予非官方第三方 Action 具寫入 repo 內容的權限（contents write、可 commit/push、可用有寫入權限的 `GITHUB_TOKEN`）
HIGH：複製貼上其他開源專案的實質程式碼邏輯（非僅測試資料）卻未附授權文字與來源連結，而該專案授權條款（如 MIT/Apache）明確要求隨附授權聲明
MEDIUM：已附來源連結但授權條款文字不完整，或第三方 Action 權限已限制為唯讀，但仍以浮動 tag 而非 commit SHA pin 版本

## 反例（不該報）
使用官方或知名維護者的 Action（`actions/checkout`、`actions/setup-node` 等）且僅需唯讀權限（checkout 程式碼、跑測試、產生 artifact）不該報；複製的只是眾所皆知的公開演算法或極短慣例片段（如標準 regex pattern），不涉及來源專案主張著作權時，不需要附授權文字；測試資料本身雖附來源連結，但屬於單純 test fixture／範例資料而非受著作權保護的程式邏輯，可從寬不報。

## 出處
- https://github.com/rails/rails/pull/46868#discussion_r1063539880
- https://github.com/rails/rails/pull/46326#discussion_r1003257492
- https://github.com/rails/rails/pull/45940#discussion_r964129285
- https://github.com/rails/rails/pull/45005#discussion_r864045711
- https://github.com/rails/rails/pull/27366#discussion_r92537623
- https://github.com/rails/rails/pull/27044#discussion_r87892561
- https://github.com/rails/rails/pull/16917#discussion_r60084858
- https://github.com/rails/rails/pull/13591#discussion_r8653387
