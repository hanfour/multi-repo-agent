---
id: rails-config-option-missing-defaults-and-docs
layer: rails
frameworks: ["rails@>=5.0"]
severity_default: MEDIUM
---
## 觸發訊號
Diff 中新增或修改了一個可透過 `config.xxx.yyy = value` 設定的 Rails 應用程式設定選項（railtie/engine `initializer` 區塊中讀取 `app.config.xxx`、或在 `Rails::Application::Configuration`／各 framework 的 `Railtie` 中新增 `config_accessor`／`class_attribute`／`mattr_accessor` 供使用者覆寫），但 diff 裡看不到下列任一項：
- 沒有同時更新 `railties/.../generators/rails/app/templates/config/initializers/new_framework_defaults_X_Y.rb.tt`（讓既有升級中的 app 能看到、手動 opt-in 新預設值）
- 沒有同時更新 `guides/source/configuring.md`（新增一段 `#### config.xxx.yyy` 說明其用途、可用值、預設值）
- 新選項的預設值寫死，沒有依 `config.load_defaults` 目標版本分流（例如没有包在 `if respond_to?(:action_controller)` / `when "X.Y"` 版本判斷區塊內，導致舊版 app 一升級 gem 就直接套用新行為，而非在他們主動调用 `load_defaults` 時才套用）

## 判準
Rails 的核心承諾是「升級 gem 版本本身不該默默改變應用程式行為」；行為變更只能透過使用者主動把 `config.load_defaults` 往上調，且調整前系統要能提示他們有哪些新選項可以手動開關。resident reviewer（如 @rafaelfranca、@byroot、@jonathanhefner）反覆要求的原因是：
1. `new_framework_defaults_X_Y.rb.tt` 是给「已存在、正在升級」的應用程式看的清單——沒放進去，這些 app 永遠不會知道有新選項可用，也無法在準備好之前保留舊行為。
2. `configuring.md` 是設定選項的唯一使用者可查文件——沒寫，maintainer 和使用者都要回去讀 commit/PR 才知道這個選項存在、預設值是什麼。
3. 沒有版本判斷直接把新預設值套用在既有初始化路徑上，等於是在 patch/minor 版本裡做了 breaking change，違反了 Rails 一貫的「新預設值只在 `load_defaults` 提升時生效」原則。

## 嚴重度
CRITICAL：新選項會改變既有 request-cycle 行為（例如 redirect status code、cookie 序列化格式、CSRF token 產生方式）卻沒有經過 `load_defaults` 版本判斷就套用到所有 app，屬於未經同意的 breaking change。
HIGH：新增了使用者可設定的 `config.xxx.yyy`，但完全沒有寫進 `configuring.md`，且沒有任何 changelog/doc 可以讓使用者發現這個選項存在。
MEDIUM：只是漏了把選項加進 `new_framework_defaults_X_Y.rb.tt`，但選項本身的預設值沒有變更既有行為（純新增功能、預設關閉），只是升級路徑上少了一個可見的 opt-in 提示。

## 反例（不該報）
- 選項只在測試環境／開發環境的樣板檔（`config/environments/test.rb` 等）中示範用法，且該選項早已存在並記載於 guide，只是這次 PR 只是調整範例文字。
- 新增的是 railtie 內部私有設定（`:nodoc:`、不對外文件化、僅供框架內部使用，例如 `ActiveRecord::Base.dangerous_attribute_method?` 這類非公開 API），本來就不打算開放給使用者覆寫。
- 選項的預設值來自 `respond_to?(:xxx)` 加上版本判斷、且該版本判斷已經正確寫在 `load_defaults` 裡，PR 中只是移動程式碼位置或重構寫法，行為完全不變。
- Bug fix 只是修正一個「原本就該套用、且不影響既有行為」的邏輯錯誤（例如某個 `nil` 保護），不是新增可設定選項。

## 出處
- https://github.com/rails/rails/pull/45618#discussion_r549175603
- https://github.com/rails/rails/pull/40770#discussion_r546118832
- https://github.com/rails/rails/pull/40213#discussion_r488912038
- https://github.com/rails/rails/pull/46358#discussion_r1009295748
- https://github.com/rails/rails/pull/33962#discussion_r247616448
- https://github.com/rails/rails/pull/32125#discussion_r170903685
- https://github.com/rails/rails/pull/45393#discussion_r901993956
- https://github.com/rails/rails/pull/45393#discussion_r902434405
- https://github.com/rails/rails/pull/45301#discussion_r894078600
- https://github.com/rails/rails/pull/44448#discussion_r808405268
- https://github.com/rails/rails/pull/41134#discussion_r585748209
- https://github.com/rails/rails/pull/27271#discussion_r91101872
- https://github.com/rails/rails/pull/26816... (未在原始意見清單中提供對應 URL，略)
