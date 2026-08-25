---
id: rails-adhoc-config-accessor-defaults
layer: rails
frameworks: ["rails@>=6.0"]
severity_default: MEDIUM
---
## 觸發訊號
diff 新增一個從 config hash 讀值、帶內嵌預設值並做型別轉換的小 accessor，形如：
`def some_option; (@config[:some_option] || DEFAULT).to_i` / `.to_f`，且符合下列任一情況：
- 這個 accessor 是加在某個具體子類別（如某個 adapter）裡，而同專案已有一個共用的抽象層（如 `DatabaseConfig` / `HashConfig`）該由它統一定義並讓子類別覆寫或拋 `NotImplementedError`；
- `DEFAULT` 這個字面值（秒數、次數、timeout）沒有附上任何理由（沒有 benchmark、沒有引用 issue、沒有「why this number」的說明）；
- 同一檔案已存在類似 accessor（例如 `connection_retries`）卻沒有沿用其命名前綴 / 型別轉換慣例；
- 這個 config 值被存成 class-level 全域變數（`@@xxx`）而非 instance-scoped。

## 判準
這類方法看起來只是幾行的 getter，但實際上是在悄悄固化一個會影響正式環境行為的數值決策（retry 次數、timeout 長度）。res 常見的資深 reviewer 顧慮：
1. 預設值一改，全部使用者的可靠度特性（重試機率、逾時容忍度）都跟著變，卻沒人交代這數字怎麼來的；
2. 如果這是抽象概念（例如「重試逾時」）卻只加在單一 adapter，其他 adapter 之後也要各自補一份，容易漏掉或定義不一致（例如同樣是「5 秒」，對不同 DB driver 意義不同，卻沒人驗證是否已 normalize）；
3. 該屬於共用 config 契約的方法被塞進具體子類別，違反了該專案既有的「抽象層定義介面、具體層實作」慣例，造成未來擴充時行為漂移；
4. 全域 class variable 形式的 config 在多租戶 / 多 app 場景下會互相汙染，且難以在測試中隔離。

## 嚴重度
CRITICAL：預設值改變了現有的可靠度/重試/逾時行為，且沒有任何 maintainer 對這個數字的討論或核可就要合併。
HIGH：這個 config accessor 應該屬於共用抽象層（例如已有 `DatabaseConfig`/`HashConfig` 之類的基底類別），卻被直接加在單一子類別/adapter 裡，未來其他實作會漏掉這個選項。
MEDIUM：純粹的命名或排序小問題——accessor 定義位置在其呼叫者之前（閱讀順序不順）、命名沒有沿用檔案裡既有的前綴慣例（如 `to_minutes` vs `in_minutes`）、或該值被存成全域 class variable 但風險有限。

## 反例（不該報）
- 新的 config accessor 只是沿用同檔案裡已經協議好的既有慣例（例如跟 `connection_retries` 用一樣的字面預設值風格），不需要額外報告；
- 純粹的方法別名（如 `alias :to_seconds :to_i`）沒有引入新的預設值或邏輯，不算這條規則要抓的問題；
- 單純的方法定義順序 nitpick，且預設值本身已有清楚理由、也放在正確的抽象層，只是閱讀順序不理想——這只是風格建議，不要升級成正確性問題。

## 出處
- https://github.com/rails/rails/pull/58049#discussion_r3540537347
- https://github.com/rails/rails/pull/53672#discussion_r1854143656
- https://github.com/rails/rails/pull/53672#discussion_r1851644629
- https://github.com/rails/rails/pull/46046#discussion_r975723821
- https://github.com/rails/rails/pull/46046#discussion_r975644062
- https://github.com/rails/rails/pull/46046#discussion_r973029575
- https://github.com/rails/rails/pull/42256#discussion_r640185865
- https://github.com/rails/rails/pull/38699#discussion_r476947094
- https://github.com/rails/rails/pull/15970#discussion_r14332060
