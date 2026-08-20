---
id: common-process-signal-shutdown-handling
layer: common
frameworks: ["node@>=14"]
severity_default: HIGH

---
## 觸發訊號
diff 新增或修改了 process 層級的 shutdown/signal 處理邏輯，具體包括：
- `process.on('SIGINT'|'SIGTERM'|'SIGUSR2'|...)` / `process.once(signal, ...)` 註冊監聽器
- 在 signal handler 或 shutdown hook 內呼叫 `process.exit(code)` 或 `process.kill(pid, signal)`
- 一個可重複呼叫的 API（如 `enableShutdownHooks(signals)`）把傳入的 signals 陣列直接 `.forEach` 註冊監聽器，沒有先去重（dedup）
- 修改 lifecycle hook 呼叫順序（例如 `onModuleDestroy` / `beforeApplicationShutdown` / `onApplicationShutdown` / 停止 server 接受請求）的先後關係
- 把原本的 exit code 語意換掉（例如把 `process.kill(pid, signal)` 改成硬編碼的 `process.exit(0)`，或把 `process.exit(130)` 改成別的值）

## 判準
同一個 Node.js process 裡，不同套件/框架/使用者程式碼可能各自對同一個 signal 註冊了監聽器。如果某段程式碼在收到 signal 後不檢查其他監聽器是否存在就直接 `process.exit()`，會搶先把整個 process 殺掉，導致其他監聽器（例如 HTTP server 的 graceful close、DB connection pool 的關閉）根本沒機會執行，造成連線未正常關閉、寫入被截斷等難以重現的資源洩漏。另外，process supervisor（systemd、k8s、pm2）依賴 POSIX 慣例的 exit code（128 + signal number）判斷進程是正常退出還是被訊號殺死；把這個語意換成固定值（如永遠 exit(0)）會讓上層誤判為正常退出，掩蓋真正的崩潰。而 signals 陣列不去重就註冊監聽器，會在 API 被重複呼叫時（例如測試裡多次建立 app context）疊加出多個相同 signal 的 handler，讓 shutdown hook 被重複執行多次。

## 嚴重度
CRITICAL：exit code 語意被靜默改變（例如 SIGTERM 觸發後永遠回傳 0），或 lifecycle hook 順序被改動導致 server 在停止接受請求「之前」就先釋放了資源（後續 request 打到已銷毀的 provider）。
HIGH：signal handler 內無條件呼叫 `process.exit()` / `process.kill()`，沒有檢查 `process.listenerCount(signal)` 是否還有其他監聽器，會讓同進程內其他套件的 cleanup 邏輯被跳過。
MEDIUM：signals 陣列在註冊監聽器前未去重（`Array.from(new Set(...))` 或等效邏輯缺失），導致重複呼叫 enable API 時同一 signal 疊加多個 handler，shutdown hook 被多次觸發（不掉資料，但行為非預期）。

## 反例（不該報）
- 整個 process 的最上層 bootstrap／CLI 入口（明確不是可重複呼叫、可被其他套件共用的 library API），收到 signal 後直接 exit 是預期行為，例如簡單 CLI 工具收到 SIGINT 就該立刻退出。
- 純粹幫某個 signal handler 補上型別標註或註解、沒有改變任何呼叫時機或 exit code 邏輯的 diff。
- 單元測試裡對 `process.on`/`process.exit` 的 mock/stub，不是真的在生產路徑上安裝 signal handler。
- 已經在函式最前面 `if (process.listenerCount(signal) > 0) return;` 或等效檢查後才呼叫 `process.exit`，屬於已修正的正確寫法。

## 出處
- https://github.com/nestjs/nest/pull/16060#discussion_r2616415767
- https://github.com/nestjs/nest/pull/14142#discussion_r1931739667
- https://github.com/nestjs/nest/pull/14142#discussion_r1926991972
- https://github.com/nestjs/nest/pull/14142#discussion_r1922742356
- https://github.com/nestjs/nest/pull/14433#discussion_r1922316540
- https://github.com/nestjs/nest/pull/14185#discussion_r1856794168
- https://github.com/nestjs/nest/pull/12898#discussion_r1422377460
- https://github.com/nestjs/nest/pull/12898#discussion_r1421568679
- https://github.com/nestjs/nest/pull/11879#discussion_r1239384461
- https://github.com/nestjs/nest/pull/10379#discussion_r1001936778
- https://github.com/nestjs/nest/pull/9832#discussion_r907359455
- https://github.com/nestjs/nest/pull/9718#discussion_r900065046
- https://github.com/nestjs/nest/pull/9699#discussion_r886619642
- https://github.com/nestjs/nest/pull/9699#discussion_r886104932
- https://github.com/nestjs/nest/pull/9316#discussion_r824573702
- https://github.com/nestjs/nest/pull/9316#discussion_r823572924
- https://github.com/nestjs/nest/pull/8738#discussion_r763766212
- https://github.com/nestjs/nest/pull/8738#discussion_r762442396
- https://github.com/nestjs/nest/pull/8208#discussion_r727986428
- https://github.com/nestjs/nest/pull/8278#discussion_r725656086
- https://github.com/nestjs/nest/pull/8203#discussion_r722463352
- https://github.com/nestjs/nest/pull/8203#discussion_r721637351
- https://github.com/nestjs/nest/pull/4768#discussion_r423626770
- https://github.com/nestjs/nest/pull/2567#discussion_r305260297
- https://github.com/nestjs/nest/pull/2567#discussion_r305143460
- https://github.com/nestjs/nest/pull/2567#discussion_r303120042
- https://github.com/nestjs/nest/pull/2428#discussion_r296614269
- https://github.com/nestjs/nest/pull/1600#discussion_r262023440
- https://github.com/nestjs/nest/pull/1600#discussion_r261828909
- https://github.com/nestjs/nest/pull/1600#discussion_r261828273
- https://github.com/nestjs/nest/pull/1600#discussion_r261822628
- https://github.com/nestjs/nest/pull/1600#discussion_r261821515
- https://github.com/nestjs/nest/pull/1216#discussion_r230554701
- https://github.com/nestjs/typeorm/pull/2461#discussion_r2551701907
- https://github.com/prisma/prisma/pull/28345#discussion_r2455696125
- https://github.com/prisma/prisma/pull/28253#discussion_r2416405980
- https://github.com/prisma/prisma/pull/27260#discussion_r2112475169
- https://github.com/prisma/prisma/pull/23008#discussion_r1482015458
- https://github.com/prisma/prisma/pull/22179#discussion_r1411949487
- https://github.com/prisma/prisma/pull/20071#discussion_r1254529741
- https://github.com/prisma/prisma/pull/19437#discussion_r1205153354
- https://github.com/prisma/prisma/pull/19385#discussion_r1204085595
- https://github.com/prisma/prisma/pull/18899#discussion_r1180080665
- https://github.com/prisma/prisma/pull/18899#discussion_r1179453731
- https://github.com/prisma/prisma/pull/18899#discussion_r1179000386
- https://github.com/prisma/prisma/pull/14174#discussion_r922182728
- https://github.com/prisma/prisma/pull/14174#discussion_r922141505
- https://github.com/prisma/prisma/pull/14174#discussion_r922022329
- https://github.com/prisma/prisma/pull/14264#discussion_r919044588
- https://github.com/prisma/prisma/pull/13980#discussion_r918726841
