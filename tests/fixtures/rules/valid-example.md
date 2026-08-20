---
id: valid-example
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現 `@Injectable({ scope: Scope.REQUEST })`，或 request-scoped provider
被注入進 singleton service。

## 判準
request-scoped provider 被 singleton 注入時，Nest 會把整條依賴鏈提升成
request scope，每個請求重建一次。原本預期只建一次的物件（連線池、快取）
會跟著重建。

## 嚴重度
CRITICAL：被提升的鏈上有連線池或外部資源 handle
HIGH：被提升的鏈上有具狀態的 service
MEDIUM：只影響無狀態的 helper

## 反例（不該報）
provider 本來就宣告成 request scope 且鏈上全部都是 request scope，
那是刻意的設計，不要報。

## 出處
- https://github.com/nestjs/nest/pull/1001#discussion_r100001
- https://github.com/nestjs/nest/pull/1002#discussion_r100002
- https://github.com/nestjs/nest/pull/1003#discussion_r100003
