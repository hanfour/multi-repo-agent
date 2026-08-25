---
id: common-public-type-api-breaking-change
layer: common
frameworks: ["typescript@>=4.5"]
severity_default: HIGH
---
## 觸發訊號
diff 修改的是套件公開對外的型別/介面/裝飾器簽章（例如已 export 的 class/interface 新增或調整 generic 參數、`.d.ts` 產出、decorator 的參數型別、extension/plugin 系統的 TypeMap/Payload/UserArgs 型別），且符合下列任一種：
- 對已存在的 exported interface/class 新增必填的 generic type parameter，或改變既有 generic 的推導方式（如 `PrismaClientClass`、`TypeMapCb`、`ExtendsHook` 這類生成器輸出的型別）
- 使用會拉高最低支援 TypeScript 版本的語法（const type parameters、`infer ... extends` 等），但沒有同步更新最低版本聲明/CHANGELOG
- 原本是同步值的 decorator/factory 參數（如 `@Client(metadata)`）被放寬成也接受 `Promise<T>`，且該值之後會在非同步 callback 裡才拿去賦值/掛載到 instance 上
- 把內部型別（`DMMF.ModelAction`、內部 `Payload`/`TypeMap`、`UserArgs` 等）透過 barrel export 或 `export type` 直接洩漏到公開 API 面

## 判準
公開型別簽章是這類函式庫（Prisma Client、NestJS decorator 等）的使用者合約；改動它不是「內部重構」，是對下游所有消費者的 breaking change，且 TypeScript 的型別錯誤通常在下游專案 build 時才爆炸，而不是在這個 PR 的 CI 裡。resident reviewer 在乎兩件事：(1) 消費者釘住較舊 TS 版本會直接編譯失敗，且他們往往不知道要去查 changelog；(2) decorator 在 class 定義階段就執行、屬於同步語意的假設一旦被打破（改成接受 Promise 卻沒有等待），後續對 instance 欄位的賦值會跟 class 建構過程產生 race condition，正式環境才會不定期出錯，難以重現。

## 嚴重度
CRITICAL：decorator/factory 從同步改成接受 async 值，且後續程式碼沒有 await 就直接對已建立的 instance 做賦值/掛載（例如 `@Client()` 接受 `Promise<ClientOptions>` 後在 `.then()` 裡才呼叫 `assignClientToInstance`）——這是會在生產環境隨機出現的 race condition。
HIGH：已 export 的公開 interface/class 新增必填 generic 參數、或改變既有型別推導路徑，使既有消費者程式碼型別檢查失敗；或用到需要拉高最低 TS 版本的語法卻未在文件/CHANGELOG 註明。
MEDIUM：內部專用型別（DMMF 內部列舉、內部 Payload/TypeMap 結構）被順手 export 出去，尚未確定是否要成為公開 API 的一部分，但目前還沒有實際消費者依賴它。

## 反例（不該報）
- 新增的 generic 參數帶有安全的預設值，且不影響既有呼叫點的型別推導結果
- 純內部測試檔、未發佈到套件產物（package output）裡的型別
- 型別重構但透過 snapshot 測試證明產出的 `.d.ts`／codegen 結果 100% 不變（behavior-preserving）
- 只是把測試斷言的聯合型別放寬（如 `expect.toBeOneOf([0,1])` 改成 `[0,1,2]`），不涉及對外公開 API 型別

## 出處
- https://github.com/nestjs/nest/pull/14142#discussion_r1849929635
- https://github.com/nestjs/nest/pull/10633#discussion_r1040060848
- https://github.com/nestjs/nest/pull/2083#discussion_r279154007
- https://github.com/prisma/prisma/pull/29867#discussion_r3713358000
- https://github.com/prisma/prisma/pull/29192#discussion_r2816221062
- https://github.com/prisma/prisma/pull/26450#discussion_r1991940907
- https://github.com/prisma/prisma/pull/26470#discussion_r1981241280
- https://github.com/prisma/prisma/pull/26470#discussion_r1981164557
- https://github.com/prisma/prisma/pull/26453#discussion_r1973669214
- https://github.com/prisma/prisma/pull/24133#discussion_r1826580459
- https://github.com/prisma/prisma/pull/24513#discussion_r1647482522
- https://github.com/prisma/prisma/pull/22286#discussion_r1425217650
- https://github.com/prisma/prisma/pull/22102#discussion_r1403818206
- https://github.com/prisma/prisma/pull/21989#discussion_r1396093981
- https://github.com/prisma/prisma/pull/21200#discussion_r1337546765
- https://github.com/prisma/prisma/pull/21138#discussion_r1330811448
- https://github.com/prisma/prisma/pull/20161#discussion_r1274484459
- https://github.com/prisma/prisma/pull/20180#discussion_r1274131129
- https://github.com/prisma/prisma/pull/20161#discussion_r1274118661
- https://github.com/prisma/prisma/pull/20161#discussion_r1273900986
- https://github.com/prisma/prisma/pull/20180#discussion_r1273346636
- https://github.com/prisma/prisma/pull/20161#discussion_r1271017224
- https://github.com/prisma/prisma/pull/20180#discussion_r1270107941
- https://github.com/prisma/prisma/pull/20180#discussion_r1270060343
- https://github.com/prisma/prisma/pull/20197#discussion_r1261639122
- https://github.com/prisma/prisma/pull/20161#discussion_r1260311097
- https://github.com/prisma/prisma/pull/20161#discussion_r1259075005
- https://github.com/prisma/prisma/pull/19942#discussion_r1242098709
- https://github.com/prisma/prisma/pull/19749#discussion_r1239593697
- https://github.com/prisma/prisma/pull/19749#discussion_r1238726807
- https://github.com/prisma/prisma/pull/19896#discussion_r1237858642
- https://github.com/prisma/prisma/pull/19885#discussion_r1236991080
- https://github.com/prisma/prisma/pull/19749#discussion_r1235077109
- https://github.com/prisma/prisma/pull/19837#discussion_r1234075350
- https://github.com/prisma/prisma/pull/19837#discussion_r1233869088
- https://github.com/prisma/prisma/pull/19517#discussion_r1212777359
- https://github.com/prisma/prisma/pull/18828#discussion_r1172275164
- https://github.com/prisma/prisma/pull/18828#discussion_r1171589466
- https://github.com/prisma/prisma/pull/17356#discussion_r1090688075
- https://github.com/prisma/prisma/pull/17429#discussion_r1081659023
- https://github.com/prisma/prisma/pull/16936#discussion_r1070209762
- https://github.com/prisma/prisma/pull/15801#discussion_r1005691785
- https://github.com/prisma/prisma/pull/15801#discussion_r1005299675
- https://github.com/prisma/prisma/pull/15787#discussion_r997252629
- https://github.com/prisma/prisma/pull/15677#discussion_r991669752
- https://github.com/prisma/prisma/pull/15677#discussion_r991370903
- https://github.com/prisma/prisma/pull/15677#discussion_r991285183
- https://github.com/prisma/prisma/pull/14559#discussion_r934498819
- https://github.com/prisma/prisma/pull/14498#discussion_r932491663
- https://github.com/prisma/prisma/pull/13920#discussion_r903497042
- https://github.com/prisma/prisma/pull/13920#discussion_r902253479
- https://github.com/prisma/prisma/pull/13584#discussion_r887800063
- https://github.com/prisma/prisma/pull/13584#discussion_r887781133
- https://github.com/prisma/prisma/pull/13584#discussion_r886885590
- https://github.com/prisma/prisma/pull/11695#discussion_r811368994
- https://github.com/prisma/prisma/pull/11560#discussion_r797594629
- https://github.com/prisma/prisma/pull/11560#discussion_r797490319
- https://github.com/prisma/prisma/pull/11560#discussion_r797486851
- https://github.com/prisma/prisma/pull/11560#discussion_r797462182
- https://github.com/prisma/prisma/pull/11560#discussion_r797448886
- https://github.com/prisma/prisma/pull/10764#discussion_r789570450
- https://github.com/prisma/prisma/pull/10764#discussion_r789547194
- https://github.com/prisma/prisma/pull/10764#discussion_r786004424
- https://github.com/prisma/prisma/pull/10764#discussion_r772661660
- https://github.com/prisma/prisma/pull/4388#discussion_r540138938
- https://github.com/prisma/prisma/pull/2937#discussion_r450083480
