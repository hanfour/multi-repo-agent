---
id: common-unjustified-eslint-disable
layer: common
frameworks: ["@typescript-eslint/eslint-plugin@*", "eslint@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 新增了 `eslint-disable`、`eslint-disable-next-line` 或 `eslint-disable-line` 註解（不論是針對 `@typescript-eslint/no-var-requires`、`no-empty-function`、`no-this-alias`、`no-unsafe-argument`、`no-unused-vars`、`require-await`、`no-redundant-type-constituents`、`no-namespace` 或其他規則），尤其是：
- 檔案層級（block comment，非 `-next-line`）的大範圍 disable，一次關掉整個檔案的規則檢查。
- disable 註解旁沒有任何說明「為什麼這裡真的無法用正規寫法通過檢查」。
- 同一個規則已經在其他檔案被 disable 過（例如多處 `require()` optional peer dependency 都各自加 `no-var-requires` disable），卻沒有收斂成共用的 helper/utility。

## 判準
Lint 規則存在是為了攔一整類真實的 bug（unsafe `any` 穿透、`this` 別名誤用、漏掉 `await`、結構型別誤判等）。沒有理由就 disable，等於把這個保護信號在這個位置永久關掉，而且會被其他工程師複製貼上到別的地方，變成漏洞規則被繞過的先例。有些 disable 是合理的（例如用 `require()` 動態載入 optional peer dependency，因為 static import 會強迫所有使用者都要裝該套件），但這種合理性必須寫在註解裡讓下一個讀者能重建脈絡，而不是靠 PR 討論串裡的隱性共識。如果同一種 disable 在多個檔案重複出現，代表可能缺一個共用工具函式，而不是 N 個各自獨立、各自合理的例外。

## 嚴重度
CRITICAL：disable 掉的規則本來會攔到這次 diff 實際引入的正確性/安全性缺陷（例如 disable `no-unsafe-argument` 卻真的把未經檢查的外部資料當參數傳入、disable floating-promises 卻真的漏了一個有副作用的 await）——這時 disable 不是繞過誤判，而是在掩蓋一個真 bug。
HIGH：新增的是檔案層級 `/* eslint-disable ... */`（而非 `-next-line`），或者 disable 完全沒有任何說明為什麼此處必須違規——這會成為其他 contributor 直接複製貼上、不再重新推導理由的先例。
MEDIUM：範圍限縮在單行的 `eslint-disable-next-line`，情境本身合理（例如動態 `require()` optional peer dependency、`require()` package.json 讀版本號）但沒寫理由；或者同一種 disable 已在程式庫其他地方出現過，應該收斂成共用工具而不是持續複製。

## 反例（不該報）
- `eslint-disable-next-line` 旁邊有清楚的程式碼註解說明結構性理由（例如「cache-manager 是 optional peer dependency，不能 static import，所以這裡的動態 require 需要 no-var-requires 例外」）——這是預期中的合理用法，不要報。
- disable 出現在測試/fixture/vendored/generated 檔案中，或本來就被排除在 lint 範圍外（例如 legacy 的 vendored `byline.ts`、`eslint.config.cjs` 自己在定義 ignore 清單）——不是在關掉對正式程式碼的保護，不要報。
- peerDependency 版本範圍調整（如 `cache-manager: "<=4"` 改成 `"<=5"`）是相依套件相容性問題，不是 eslint-disable 濫用，不要混進這條規則裡誤判。

## 出處
- https://github.com/nestjs/nest/pull/11131#discussion_r1111276662
- https://github.com/nestjs/nest/pull/11131#discussion_r1110115386
- https://github.com/nestjs/nest/pull/10370#discussion_r1069102041
- https://github.com/nestjs/nest/pull/10370#discussion_r1002626968
- https://github.com/nestjs/nest/pull/10346#discussion_r986242324
- https://github.com/nestjs/nest/pull/10346#discussion_r986225906
- https://github.com/nestjs/nest/pull/10346#discussion_r986222560
- https://github.com/nestjs/nest/pull/9836#discussion_r906873249
- https://github.com/nestjs/nest/pull/6889#discussion_r612742693
- https://github.com/nestjs/nest/pull/2688#discussion_r309479286
- https://github.com/nestjs/nest/pull/2688#discussion_r309470291
- https://github.com/prisma/prisma/pull/29864#discussion_r3702915157
- https://github.com/prisma/prisma/pull/29322#discussion_r2905856586
- https://github.com/prisma/prisma/pull/28375#discussion_r2490244960
- https://github.com/prisma/prisma/pull/28174#discussion_r2388159008
- https://github.com/prisma/prisma/pull/26678#discussion_r2007657985
- https://github.com/prisma/prisma/pull/26652#discussion_r1998814371
- https://github.com/prisma/prisma/pull/26612#discussion_r1998320884
- https://github.com/prisma/prisma/pull/26612#discussion_r1998039275
- https://github.com/prisma/prisma/pull/24273#discussion_r1612166477
- https://github.com/prisma/prisma/pull/24127#discussion_r1596693652
- https://github.com/prisma/prisma/pull/22068#discussion_r1402487462
- https://github.com/prisma/prisma/pull/20165#discussion_r1374735965
- https://github.com/prisma/prisma/pull/19457#discussion_r1207063929
- https://github.com/prisma/prisma/pull/19457#discussion_r1206036292
- https://github.com/prisma/prisma/pull/17210#discussion_r1067166099
- https://github.com/prisma/prisma/pull/13980#discussion_r921467467
- https://github.com/prisma/prisma/pull/13303#discussion_r871227938
- https://github.com/prisma/prisma/pull/13303#discussion_r871210363
- https://github.com/prisma/prisma/pull/12560#discussion_r855006855
- https://github.com/prisma/prisma/pull/12560#discussion_r854352155
- https://github.com/prisma/prisma/pull/7111#discussion_r642858751
- https://github.com/prisma/prisma/pull/4820#discussion_r550143445
- https://github.com/prisma/prisma/pull/4820#discussion_r550137926
- https://github.com/prisma/prisma/pull/4316#discussion_r531725684
- https://github.com/prisma/prisma/pull/4316#discussion_r531712533
- https://github.com/prisma/prisma/pull/4047#discussion_r512548000
- https://github.com/prisma/prisma/pull/3567#discussion_r485743572
- https://github.com/prisma/prisma/pull/3093#discussion_r467005581
