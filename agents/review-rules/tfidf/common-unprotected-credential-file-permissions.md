---
id: common-unprotected-credential-file-permissions
layer: common
frameworks: ["node@>=14"]
severity_default: HIGH

---
## 觸發訊號
diff 新增或修改「把憑證 / token / session 資料寫進本機檔案」的程式碼，典型形狀是 `mkdir(dirname(authFilePath), { recursive: true })` 接著 `writeFile(authFilePath, JSON.stringify(credentials/tokens))`，且沒有在 `writeFile`/`mkdir` 帶 `mode` 選項、也沒有後續 `chmod` 把檔案限制到 `0600`、目錄限制到 `0700`。同一段「建立目錄 + 寫入憑證檔」邏輯在多個方法（例如 `writeCredentialsToDisk` 與 `deleteCredentials`）各自複製一份，也算觸發訊號之一。

## 判準
用 `writeFile` 建立新檔案時，實際權限取決於 process umask（常見結果是 `644`），代表同機其他使用者或程序可以直接讀走裡面的 OAuth token / API key / session secret；在共享機器、CI runner、容器共用 volume 等環境下這是可直接利用的資訊洩漏，而不是理論風險。已存在的檔案被 overwrite 時，`writeFile` 的 `mode` 選項也不會生效，必須額外 `chmod` 才能保證舊檔案的權限一致收斂。此外，若「建立目錄＋寫入憑證檔」這段邏輯散落在多個方法各自複製，代表沒有單一把關點，只要有人在其中一處忘了補權限設定，防護就會出現不一致的死角，日後也難以一次性修正。

## 嚴重度
CRITICAL：檔案內容含長效 API key、私鑰或可直接重放取得完整帳號存取權的 refresh token，部署環境是多租戶主機或共享容器 volume。
HIGH：檔案內容含 OAuth access token / session token，寫入或 overwrite 時未設定 `0600`/`0700` 權限，且相同的寫入邏輯在多處重複維護。
MEDIUM：寫入邏輯已集中在單一函式，只是缺少明確權限設定，或部署環境已知是單使用者專屬機器（風險較低但仍應修正）。

## 反例（不該報）
- 寫入的是一般設定檔、快取檔或不含憑證/token 欄位的資料，沒有敏感內容不需要限制權限。
- 已經用 `chmod` 明確設定 `0600`/`0700`，並用 `try/catch` 正確處理「Windows 不支援 POSIX chmod」的情境，這是正確作法，不該再報。
- `existsSync`/`lstatSync` 用來判斷路徑是否已被同名檔案佔用以避免 `mkdir` 衝突，這是路徑型別檢查而非權限問題，不屬於此規則範圍。
- `loadEnvFile` 之類的參數解構或呼叫方式調整，純屬程式風格整理，未涉及憑證檔案的建立或權限設定。

## 出處
- https://github.com/nestjs/nest/pull/4607#discussion_r409357931
- https://github.com/prisma/prisma/pull/29609#discussion_r3644150429
- https://github.com/prisma/prisma/pull/29568#discussion_r3272779591
- https://github.com/prisma/prisma/pull/27197#discussion_r2092905147
- https://github.com/prisma/prisma/pull/22194#discussion_r1412381332
- https://github.com/prisma/prisma/pull/22194#discussion_r1412366840
- https://github.com/prisma/prisma/pull/19556#discussion_r1213367655
- https://github.com/prisma/prisma/pull/11524#discussion_r796403203
- https://github.com/prisma/prisma/pull/10568#discussion_r762458392
- https://github.com/prisma/prisma/pull/10181#discussion_r745985125
