---
id: common-duplicated-style-constants
layer: common
frameworks: ["css@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或修改樣式相關程式碼時出現以下任一情況：
- 把既有檔案裡的顏色 / 邊框 / 寬度等樣式常數，或整個 CSS 自訂屬性（`--color-*`、`--*-width` 等 design token）區塊複製貼到另一個檔案，而不是 import 共用來源或抽出共用模組
- 子元件自行加上 `border`、`padding` 等外觀屬性，而其父容器本身可能已經定義了相同屬性（造成疊加或重複繪製）
- 直接修改 vendored / 第三方套件的 CSS 檔案（如 `node_modules` 內或 vendor 目錄下的樣式檔），而不是往上游送 PR 或建立本地 override 層

## 判準
樣式常數一旦被複製到第二個地方，兩份定義會隨著時間各自被修改而漂移不同步，之後沒人能保證改一邊時另一邊也會被記得改；resident reviewer 在意的是未來的維護成本，不是當下畫面是否正確。邊框/外觀屬性由子元件疊加在父容器上，會在組合（composition）情境下產生重複邊框或位置錯亂，把邊框責任收斂到容器層可以讓不同父層自由決定要不要加邊框。直接改第三方檔案則會在下次升級依賴時被覆蓋掉，且修正對其他使用該套件的人完全無效，應該回饋上游或另建 override。

## 嚴重度
CRITICAL：（此規則的問題性質不會到 CRITICAL；不套用）
HIGH：整份 CSS 主題變數檔（例如亮/暗色 theme 的完整 `--color-*` 集合）被 fork 到另一個檔案，日後兩份色票必然逐步失步，影響整個產品線的視覺一致性且難以察覺
MEDIUM：單一元件複製少量顏色/邊框/寬度值、子元件疊加邊框造成雙重邊框、或直接修改第三方 CSS 檔案而未走 override/上游流程

## 反例（不該報）
- 為了主題切換或狀態變化而「覆寫」少數既有變數的值（非整份複製定義），是正常的 CSS 慣用法，不算重複
- 因無障礙需求（例如 visually-hidden pattern：`clip: rect(0,0,0,0)` 等一小段固定 boilerplate）在多處重複出現，這是業界公認的慣用寫法，不算需要抽成共用來源的「樣式常數」
- 子元件加上邊框，但父容器明確不負責邊框、且該元件本來就是獨立使用（非巢狀合成）情境，不構成重複繪製問題
- 只是在文件/範例（如 `examples/`、`fixtures/`）中出現的樣式，屬於一次性展示用途，不追求長期同步

## 出處
- https://github.com/react/react/pull/35503#discussion_r2686950797
- https://github.com/react/react/pull/31563#discussion_r1848885395
- https://github.com/react/react/pull/31548#discussion_r1843461829
- https://github.com/react/react/pull/22030#discussion_r684432354
- https://github.com/react/react/pull/19707#discussion_r482992327
- https://github.com/react/react/pull/18745#discussion_r426793077
- https://github.com/react/react/pull/18852#discussion_r422243622
- https://github.com/react/react/pull/17934#discussion_r386664171
- https://github.com/react/react/pull/13295#discussion_r206716193
- https://github.com/react/react/pull/11821#discussion_r155934143
- https://github.com/react/react/pull/10735#discussion_r139732206
- https://github.com/react/react/pull/10385#discussion_r131793471
- https://github.com/react/react/pull/10270#discussion_r129174990
- https://github.com/react/react/pull/8589#discussion_r92828111
- https://github.com/react/react/pull/8084#discussion_r84878043
- https://github.com/react/react/pull/7691#discussion_r78281856
- https://github.com/react/react/pull/5654#discussion_r47544826
- https://github.com/react/react/pull/434#discussion_r7104975
- https://github.com/react/react/pull/25#discussion_r4505566
- https://github.com/TanStack/query/pull/7503#discussion_r1623276007
- https://github.com/TanStack/query/pull/5822#discussion_r1280606167
- https://github.com/TanStack/query/pull/4721#discussion_r1059321641
