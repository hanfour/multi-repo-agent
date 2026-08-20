---
id: common-self-mocking-unit-under-test
layer: common
frameworks: ["jest@*", "sinon@*", "mocha@*"]
severity_default: HIGH
---
## 觸發訊號
單元測試裡對「正在測試的那個方法/類別本身」下 mock/stub/spy，然後斷言呼叫發生或回傳值符合預期。典型寫法：
- `jest.spyOn(catsService, 'findAll').mockImplementation(() => result)` 之後又測 `catsService.findAll()` 的行為/回傳值。
- `service.remove('anyid')` 前用 `jest.spyOn(service, 'remove')`，斷言只驗證「呼叫了 `service.remove`」，卻沒有 mock/驗證底層 repository（`repository.delete`/`repository.remove`）真正被呼叫、參數是否正確。
- 測試名稱宣稱在驗證某個 service/controller 方法的邏輯，但該方法本身或其唯一的外部依賴完全沒被 stub，斷言只是回頭確認呼叫本身發生過。

## 判準
Mock 掉受測方法本身，測試就退化成「呼叫了一個被我自己 mock 掉的函式，然後斷言它回傳了我自己設定的值」——這永遠會綠燈，跟實作邏輯正不正確完全無關。正確做法是 mock 該方法的*依賴*（repository、HTTP client、外部 SDK 等邊界），讓受測方法的真實邏輯跑過一遍，再斷言依賴被以正確參數呼叫、以及方法的回傳值/副作用符合預期。這類測試會在 CI 上長期發綠燈，卻在生產環境的邏輯改壞時完全抓不到，是典型的假安全感（false confidence）來源，也是資深 reviewer 最容易一眼看穿、但最容易被忽略的測試反模式。

## 嚴重度
CRITICAL：受測的是含業務邏輯/資料處理分支的方法（非純轉發），self-mock 導致該邏輯完全沒有任何測試覆蓋，且該測試是該方法唯一的測試案例。
HIGH：受測方法只是薄轉發（呼叫底層 repository/client 並回傳），self-mock 讓測試無法驗證轉發參數或回傳值是否正確透傳。
MEDIUM：測試同時混用 self-mock 與其他真正驗證依賴呼叫的斷言，self-mock 只弱化了部分覆蓋而非整個測試失效。

## 反例（不該報）
- Mock 的是受測單元的**依賴**（repository、外部 service、HTTP adapter），而不是受測方法本身——這是正常且必要的隔離做法。
- 測試明確聲明目的是驗證「controller 是否正確委派給 service」（delegation/wiring test），此時 mock service 方法並斷言被呼叫本身就是測試目的，不是缺陷。
- 對受測方法做 `jest.spyOn` 但沒有 `mockImplementation`/`mockResolvedValue`，只是用來觀察呼叫次數/參數，底層真實邏輯仍會執行。
- Sandbox/sample 專案（如文件範例、`sample/` 目錄下的教學程式）中的測試，其目的是示範測試寫法而非驗證生產邏輯正確性。

## 出處
- https://github.com/nestjs/nest/pull/10623#discussion_r1036671058
- https://github.com/nestjs/nest/pull/8032#discussion_r702448282
