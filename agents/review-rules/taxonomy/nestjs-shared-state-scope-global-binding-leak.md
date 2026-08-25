---
id: nestjs-shared-state-scope-global-binding-leak
layer: nestjs
frameworks: ["@nestjs/core@^8||^9||^10", "@nestjs/common@^8||^9||^10", "jest@^27||^28||^29", "vitest@^0||^1||^2"]
severity_default: HIGH
---
## 觸發訊號

diff 出現以下任一種「把原本該侷限在某一層的東西，改成會被其他層/其他呼叫者共用」的變更時，要去確認共用範圍是否真的安全：

- 對 `globalThis`、模組頂層變數、或跨測試檔案共用的 `let`/`const`（例如 `globalThis.fetch = ...`、`globalThis.DEBUG = ...`、`globalThis.crypto = ...`）直接賦值或 mock，而沒有在同一個 hook 層級（`afterEach`/`afterAll`）做對應的 restore。
- 新增或修改 `@Global()` 模組、`APP_FILTER`/`APP_INTERCEPTOR`/`APP_GUARD`、或任何「全域註冊點」的邏輯，且該邏輯會讀取或寫入原本只設計給單一 module/controller/method 使用的 metadata、token 或 provider。
- 修改 lazy-loaded / dynamic module 的 scan、compile、bind 時機（例如 `bindGlobalsToImports`、`scanForModules`），使得全域狀態的綁定時機相對其他（尤其是 eagerly-loaded 或另一個 lazy-loaded）模組的載入順序改變。
- 讓原本代表「這一層」的欄位（例如 method-level 的 `version`、`path`、metadata）被 fallback/覆寫成也可以代表「上一層」（controller-level、global-level）的值，卻沒有同時檢查所有既有讀取這個欄位的地方是否還假設它只有單一語意。
- 測試檔案裡新增 `beforeAll`/`afterAll` 或 `vi.spyOn`/`jest.spyOn` 綁在 `process`、`globalThis` 或跨 `describe` 共用的變數上，尤其是在既有的 test suite 檔案裡「插入」新的一組 spy/mock，而不是每個 suite 各自建立與清理。

## 判準

Nest 的 DI 容器與這些測試 runner 都用「單一共用容器/單一全域物件」實作作用域（`@Global()`、`InternalCoreModule`、`globalThis`），這代表任何一段程式碼寫入這個容器/物件時，其實是在對「所有其他消費者尚未執行到的程式碼」下賭注：假設沒有人會在它之前或之後也去讀寫同一個位置。resenior reviewer 之所以特別警覺，是因為這類問題在單一 PR 的 diff 裡幾乎看不出來——出問題的不是這次改的程式碼本身，而是「另一個原本以為狀態是自己的呼叫者」，往往是完全不同的模組、完全不同的測試檔案，甚至是下一次執行時的載入順序。這類 bug 常常沒有測試會直接失敗，而是變成間歇性、順序相關（order-dependent）的異常，debug 成本極高。

## 嚴重度

CRITICAL：production 路徑上的全域/共用狀態被錯誤地讀寫，導致跨模組行為靜默錯誤（例如全域 filter 攔截順序改變導致原本該被特定 filter 處理的例外被吞掉、或 method/controller/global 三層 version 語意混淆造成路由版本判斷錯誤），且沒有任何測試涵蓋跨模組互動。

HIGH：只影響測試環境，但因為缺少對應的 restore/teardown（`mockRestore`、`afterEach` 清空 `globalThis.xxx`），造成測試套件間互相污染、順序相關的假失敗或假通過，且影響範圍橫跨多個測試檔案。

MEDIUM：共用範圍確實被放大，但實際消費者目前只有一個、或已有明顯 workaround／文件提醒，短期不會造成錯誤結果，只是語意上容易誤用。

## 反例（不該報）

- 變數宣告在函式或建構子內部，作用域完全侷限在該次呼叫，沒有外洩給任何其他模組、測試檔或後續呼叫——這只是普通的區域變數，不是共用狀態。
- 測試裡已經用 `beforeEach`/`afterEach` 正確配對建立與還原 mock/spy，且還原邏輯確實涵蓋了這次新增的 spy——即使 mock 對象是 `globalThis` 或 `process`，只要生命週期已經對齊到單一 test/suite，就不成立。
- 刻意設計成全域單例且文件/介面已明確宣告其為全域（例如 `isGlobal: true` 這種明確的 opt-in 全域註冊選項本身），只是在討論這個選項該怎麼用、要不要加開關，而不是意外把原本局部的狀態擴大成全域。

## 出處

- https://github.com/nestjs/nest/pull/10835#discussion_r1095580682
- https://github.com/nestjs/nest/pull/9999#discussion_r927182000
- https://github.com/nestjs/nest/pull/5129#discussion_r458462589
- https://github.com/nestjs/nest/pull/10005#discussion_r943468906
- https://github.com/nestjs/nest/pull/10005#discussion_r932242794
- https://github.com/nestjs/nest/pull/1957#discussion_r304640800
- https://github.com/nestjs/nest/pull/1517#discussion_r281623971
- https://github.com/prisma/prisma/pull/29808#discussion_r3683519544
- https://github.com/prisma/prisma/pull/29207#discussion_r2828618793
- https://github.com/prisma/prisma/pull/21745#discussion_r1380182422
- https://github.com/prisma/prisma/pull/26421#discussion_r1967550806
- https://github.com/prisma/prisma/pull/24681#discussion_r1660946230
