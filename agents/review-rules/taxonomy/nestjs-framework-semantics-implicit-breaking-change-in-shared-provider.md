---
id: nestjs-framework-semantics-implicit-breaking-change-in-shared-provider
layer: nestjs
frameworks: ["@nestjs/common@^8 || ^9 || ^10 || ^11", "@nestjs/core@^8 || ^9 || ^10 || ^11"]
severity_default: HIGH
---
## 觸發訊號
diff 修改的 class 是被廣泛套用的共用元件 —— 全域註冊的 `NestInterceptor` / `CanActivate` / `PipeTransform` / `ExceptionFilter`（透過 `APP_INTERCEPTOR` / `APP_GUARD` / `APP_PIPE` / `APP_FILTER` provider token，或 `app.useGlobalInterceptors()` / `useGlobalGuards()` / `useGlobalPipes()` / `useGlobalFilters()` 掛載）、跨多個呼叫點共用的 engine/adapter 生命週期管理器（如連線 engine 的 start/stop）、或是被多處呼叫的序列化/轉換 wrapper —— 且這次改動屬於下列任一種：
- 新增或改變了轉發給底層第三方函式（class-transformer、class-validator、driver adapter、序列化器等）的參數/選項，而先前這些參數是被省略或用不同值呼叫的
- 改變了一個先前隱含的預設值或 fallback 行為（例如某欄位過去因型別不符而保持 `undefined`，現在改成有值）
- 依賴了平台/執行環境特定的行為（Node/Deno/Bun 的 module 解析、Windows 對子行程終止時機的處理、套件的 semver 版本語意）而未針對差異分支處理

## 判準
這類元件的呼叫方看不到、也不會主動去讀這次 diff —— 全域 provider 對整個應用的每個 route 都生效，共用的 engine/adapter 被所有呼叫端隱含依賴。改動看起來只是「補一個參數」或「讓行為更完整」，但因為呼叫方原本就是依賴著舊的（可能不完整、甚至有點錯的）行為在運作，這種改動實質上是對所有既有使用者的隱性 breaking change。nestjs/nest 官方維護者對 `ClassSerializerInterceptor` 的提問就是這個形狀的典型案例：過去 `options` 只傳給 `classToPlain`，現在同時傳給 `plainToClass`，維護者第一個反應不是這行程式碼對不對，而是「這會不會讓既有專案的行為跟以前不一樣」。這種風險無法從被改的那幾行程式碼本身看出來，只有把它放回「這是全域 / 共用元件」的框架語意脈絡才看得出來，所以純粹逐行比對 diff 抓不到，需要額外去確認呼叫方是否會因此改變行為。

## 嚴重度
CRITICAL：改動的是已發布套件（library/framework 本身）的全域 interceptor/guard/pipe/filter 或共用 engine 生命週期邏輯，下游有未知數量的既有使用者可能依賴舊行為，且 PR 未附版本號、CHANGELOG 或 migration 說明。
HIGH：專案內部透過 `APP_*` token 註冊的全域 provider，或跨多個 module 共用的 adapter/serializer，行為被改動，且沒有涵蓋所有既有呼叫端行為不受影響的測試。
MEDIUM：影響範圍侷限在單一 controller 用 `@UseInterceptors()` / `@UseGuards()` 局部套用的元件，但變更後的行為未在對應 handler 的測試中被驗證。

## 反例（不該報）
- 該 class 雖實作 `NestInterceptor`/`CanActivate` 等介面，但只在測試檔或範例程式中被 `new` 出來單獨呼叫，未透過 `APP_*` token 或 `useGlobal*()` 掛載為全域 provider，影響範圍就是單一測試。
- 新增的是預設值等同於改動前行為的 opt-in 參數（例如新的 constructor 參數預設為 `false`／與舊行為一致），既有呼叫端不用改任何程式碼就會得到跟以前一樣的結果。
- 這次改動的目標函式本來就是內部工具，只有這次 PR 新加的呼叫點在用，沒有其他既有呼叫方會被波及。
- PR 本身就是這個套件的 major version release，或此行為變更已經明確寫進 CHANGELOG / migration guide，變更本身就是預期中的 breaking change。

## 出處
- https://github.com/nestjs/nest/pull/12764#discussion_r1397167863
- https://github.com/prisma/prisma/pull/29997#discussion_r3767170268
- https://github.com/prisma/prisma/pull/29936#discussion_r3759025181
- https://github.com/prisma/prisma/pull/29832#discussion_r3704955918
- https://github.com/prisma/prisma/pull/29826#discussion_r3665874582
- https://github.com/prisma/prisma/pull/29469#discussion_r3644140195
- https://github.com/prisma/prisma/pull/29349#discussion_r3644130777
- https://github.com/prisma/prisma/pull/28892#discussion_r3622988763
- https://github.com/prisma/prisma/pull/29251#discussion_r2853764969
- https://github.com/prisma/prisma/pull/26633#discussion_r1998102879
- https://github.com/prisma/prisma/pull/26470#discussion_r1981240458
- https://github.com/prisma/prisma/pull/25968#discussion_r1901620358
- https://github.com/prisma/prisma/pull/24878#discussion_r1745331571
- https://github.com/prisma/prisma/pull/23019#discussion_r1514867851
- https://github.com/prisma/prisma/pull/23090#discussion_r1492442212
- https://github.com/prisma/prisma/pull/19457#discussion_r1206023787
- https://github.com/prisma/prisma/pull/16748#discussion_r1094391927
- https://github.com/prisma/prisma/pull/14424#discussion_r928735743
- https://github.com/prisma/prisma/pull/14221#discussion_r919769627
- https://github.com/prisma/prisma/pull/13737#discussion_r900271142
- https://github.com/prisma/prisma/pull/13743#discussion_r894805719
- https://github.com/prisma/prisma/pull/12678#discussion_r843959701
- https://github.com/prisma/prisma/pull/3436#discussion_r477306363
- https://github.com/prisma/prisma/pull/3093#discussion_r467031959
- https://github.com/prisma/prisma/pull/431#discussion_r328159026
