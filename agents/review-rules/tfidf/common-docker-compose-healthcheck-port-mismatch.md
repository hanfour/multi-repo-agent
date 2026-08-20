---
id: common-docker-compose-healthcheck-port-mismatch
layer: common
frameworks: ["docker-compose@*"]
severity_default: HIGH
---
## 觸發訊號
diff 修改了 docker-compose(或其變體檔案,如 docker-compose.arm64.yml、.buildkite 下的 docker-compose.yml)中某個 service 的 `healthcheck.test` 命令,尤其是其中帶 port/host 的探測參數(例如 `mysqladmin ping -h127.0.0.1 -P<port>`、`pg_isready -p <port>`、`redis-cli -p <port>` 等),而該參數的數值與同一 service 的 `ports`/`environment` 裡實際對外監聽的 port 不一致;或該 healthcheck 區塊明顯是從別的 service 複製過來,只改了 `ports` 卻沒同步改 healthcheck 裡的埠號。

## 判準
healthcheck 是 `depends_on: condition: service_healthy` 的判斷依據。若 healthcheck 命令探測的 port/host 跟 service 實際監聽的 port 不符,健檢會恆為失敗(container 永遠被標記 unhealthy),導致依賴它的 service 卡住等待、CI 直接因健檢逾時而失敗,且錯誤訊息跟真正原因(埠打錯)完全無關,非常難排查。這類錯誤最常見的成因是複製別的 service 或別的版本的 healthcheck 區塊後只改了 `ports` 忘了同步改 healthcheck,或是同一份設定裡多處重複同一個 port 數字,改了一處忘了改另一處。

## 嚴重度
CRITICAL:healthcheck 探測的 port 與 service 實際監聽 port 不同,且有其他 service 透過 `depends_on: condition: service_healthy` 依賴它 → CI/本地開發會卡死或直接 timeout 失敗,且難以定位根因。
HIGH:healthcheck 探測的 port/host 錯誤,但目前沒有其他 service 顯式依賴它的健康狀態 → 健檢恆為失敗,只是暫時沒人被卡住,遲早會誤導後續排查。
MEDIUM:healthcheck 存在但探測邏輯跟服務實際設定不完全對應(例如探測的是預設埠而非該 service 環境變數覆寫後的埠),屬潛在風險但尚未觀察到實際失敗。

## 反例（不該報）
- 移除一個已被判定為無效/多餘的整個 healthcheck 區塊本身(而非改動 port),且該 service 沒有任何依賴者需要 `service_healthy` 狀態。
- healthcheck 的 port 與 service 的 `ports` 完全一致,review 只是建議調整 `interval`/`timeout`/`retries`/`start_period` 等時間參數 —— 這是效能/穩定性層面的建議,不屬於本規則。
- 移除跟 healthcheck 邏輯無關、確認為未使用的環境變數或整個服務定義(如刪除死掉的 env var、刪除整個未使用的 mssql/cockroachdb service),屬於死碼清理而非 port mismatch。

## 出處
- https://github.com/prisma/prisma/pull/21294#discussion_r1341934707
- https://github.com/prisma/prisma/pull/21294#discussion_r1341659939
- https://github.com/prisma/prisma/pull/19556#discussion_r1218046324
- https://github.com/prisma/prisma/pull/16560#discussion_r1036345822
- https://github.com/prisma/prisma/pull/16051#discussion_r1011801662
- https://github.com/prisma/prisma/pull/16051#discussion_r1011779392
- https://github.com/prisma/prisma/pull/10984#discussion_r781189988
- https://github.com/prisma/prisma/pull/10772#discussion_r772460783
- https://github.com/prisma/prisma/pull/10772#discussion_r772314901
- https://github.com/prisma/prisma/pull/3970#discussion_r510845755
