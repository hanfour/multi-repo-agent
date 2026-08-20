---
id: nestjs-platform-adapter-leaky-abstraction
layer: nestjs
frameworks: ["@nestjs/core@*", "@nestjs/swagger@*", "@nestjs/platform-express@*", "@nestjs/platform-fastify@*"]
severity_default: HIGH
---
## 觸發訊號
diff 修改的是設計上要對 Express / Fastify 兩種 HTTP adapter 保持中立的模組（core、`@nestjs/swagger`、或任何以 `HttpAdapterHost`/`getHttpAdapter()` 抽象 HTTP 層的程式碼），且出現以下任一模式：
- 在 core 或平台無關模組裡對某個具體 platform 套件（如 `@nestjs/platform-express`、`swagger-ui-express`、`fastify-swagger`）做**靜態 import**，而不是透過 `loadPackage`（peer-dep 動態載入）或 `httpAdapter.getType()` 分流。
- 把套件名稱以**變數**傳進 `loadPackage(...)` / `require(...)`（例如 `require(swaggerUiLib)`，`swaggerUiLib` 是可被外部覆寫的變數），而不是字面字串常數。
- 新增一個只有某一種 adapter 才支援的 option（如 Fastify 專屬的 `uiHooks`、`staticCSP`、`transformStaticCSP`），卻放進共用的 `SwaggerCustomOptions` 這類跨 adapter 共用 interface，沒有拆成 `ExpressXxxOptions` / `FastifyXxxOptions` 的聯集型別。
- 為了相容舊版 API 而新增 backward-compatibility layer / legacy interface，但沒有標註 `@deprecated`，或底層行為在另一種 adapter 上根本沒有對應實作。
- 在每個 request handler 內重複建構同一份重物件（如 Swagger document），沒有透過閉包/快取（lazy-build-once）在多個 route handler 間共用。

## 判準
這類程式碼的核心承諾是「換 adapter 不用改業務程式碼」；一旦上述模式出現，這個承諾就被破壞，且問題通常要到打包（webpack）、切換 adapter、或未安裝某 peer dep 時才會炸，本地開發跑得動，CI 也可能測不出來，屬於「看起來能動但會在使用者環境爆」的典型陷阱。靜態 import 平台套件還會製造 core → platform 的循環依賴，讓套件無法在只裝了另一個 adapter 的專案裡安裝。共用 interface 裡混入 adapter-only 欄位則是 type 說謊：TypeScript 允許你在 Express 情境下傳入只有 Fastify 才吃得到的 option，編譯期不會報錯，但 runtime 靜默無效。

## 嚴重度
CRITICAL：平台無關模組（如 `nest-factory.ts`／core）對具體 platform 套件產生**循環依賴**或強制其成為硬依賴，導致只安裝單一 adapter 的專案無法啟動或無法安裝套件。
HIGH：`loadPackage`/`require` 的目標套件名稱來自可被覆寫的變數而非字面字串，會被 webpack 等打包工具的靜態分析漏掉，造成 production build 直接找不到模組；或共用 interface 混入 adapter-only 欄位，使用者在錯誤 adapter 下設定該 option 卻完全無效且無任何錯誤提示。
MEDIUM：backward-compatibility layer／legacy interface 未標註 `@deprecated`，或文件未同步更新選項差異，屬於可維護性/使用者體驗問題，尚不影響功能正確性。

## 反例（不該報）
- 透過 `httpAdapter.getType() === 'fastify'` 或 `HttpAdapterHost` 做分流，各自呼叫各自 adapter 的 API——這是正確的抽象方式，不應報。
- `loadPackage(...)` 的第一個參數是**字面字串常數**（如 `loadPackage('@nestjs/platform-express', ...)`），即使該套件是 optional peer dependency，只要字串是字面量、對 webpack 可靜態分析，就不算問題。
- 新增的 option 已經明確拆進 platform-specific 型別（如 `ExpressSwaggerCustomOptions` / `FastifySwaggerCustomOptions` 的聯集），並各自標注僅適用於哪個 adapter。
- 用閉包快取（如 `getBuiltDocument()` 只在第一次呼叫時建構、之後回傳快取值）避免重複建構——這是修正重複建構問題的正確做法，不該被誤報為「重複建構」。

## 出處
- https://github.com/nestjs/nest/pull/1329#discussion_r237997286
- https://github.com/nestjs/swagger/pull/3185#discussion_r1867721873
- https://github.com/nestjs/swagger/pull/3186#discussion_r1855361966
- https://github.com/nestjs/swagger/pull/2840#discussion_r1490566607
- https://github.com/nestjs/swagger/pull/1926#discussion_r872407628
- https://github.com/nestjs/swagger/pull/1886#discussion_r851216614
- https://github.com/nestjs/swagger/pull/1886#discussion_r851143045
- https://github.com/nestjs/swagger/pull/1886#discussion_r851132199
- https://github.com/nestjs/swagger/pull/1886#discussion_r849644233
- https://github.com/nestjs/swagger/pull/1886#discussion_r848440738
- https://github.com/nestjs/swagger/pull/1886#discussion_r848291508
- https://github.com/nestjs/swagger/pull/1529#discussion_r717439140
- https://github.com/nestjs/swagger/pull/1341#discussion_r632313992
- https://github.com/prisma/prisma/pull/28224#discussion_r2406569075
