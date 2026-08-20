---
id: nestjs-injectable-scope
layer: nestjs
frameworks: ["@nestjs/core@>=9"]
severity_default: HIGH
---
## 觸發訊號
diff 裡出現 `@Injectable({ scope: Scope.REQUEST })`，或 request-scoped provider
被注入進 singleton service。

## 判準
request-scoped provider 被 singleton 注入時，整條依賴鏈會被提升成 request
scope。

## 嚴重度
HIGH：被提升的鏈上有具狀態的 service

## 反例（不該報）
provider 本來就宣告成 request scope 且鏈上全部都是 request scope。

## 出處
- https://github.com/nestjs/nest/pull/2001#discussion_r200001
- https://github.com/nestjs/nest/pull/2002#discussion_r200002
- https://github.com/nestjs/nest/pull/2003#discussion_r200003
