---
id: common-incomplete-dead-code-cleanup
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM
---
## 觸發訊號
- diff 刪除了一組同類型的特殊情況分支（例如針對某個型別的相容性/強制轉型 `if` 分支）,但同一函式裡明顯同構、對應到姊妹型別（如 `List<X>` 對 `List<Y>`）的其他分支沒有一併刪除或說明為何保留。
- diff 新增的 helper/utility 檔案裡有宣告但整個函式體內完全沒被引用的參數、import 或區域變數（尤其是 `_`、`repeat`、`times` 這類命名不直觀、容易被語言伺服器/眼睛掃過去忽略的識別字）。
- diff 把泛型參數名稱從 `L`（或其他與 import 的 namespace/型別同名）改成別的名字，且沒有其他行為變更 —— 代表原本的命名讓 lint 規則（如 `no-unused-vars`）誤判 namespace import 未使用，或讓讀者混淆「這是 namespace 還是泛型參數」。

## 判準
這類問題的共通根因是「重構/清理沒做完」：
- 移除某型別支援時只改了看到的那一行，沒有系統性搜尋所有同構分支，導致相關型別之間行為不對稱（一個型別還在被特殊處理，另一個已經被拿掉），之後只會在很晚才被發現且難以定位。
- 未使用的參數/變數不只是美觀問題 —— 它們暗示這段程式碼在重構過程中留下了半成品，且會誤導後續維護者以為這個參數有作用，浪費除錯時間。
- 泛型參數與 import 的 namespace 同名時，TypeScript 實際解析規則和部分 lint 規則的假設不一致，會產生誤報（讓真正的 unused import 被掩蓋，或讓開發者為了消除誤報做出不必要的改動），也讓讀者難以一眼判斷某個 `L` 到底指的是 namespace 還是型別參數。

## 嚴重度
CRITICAL：不對稱的分支刪除發生在使用者輸入驗證 / 型別強制轉換等會影響執行期正確性的邏輯上，且沒有測試涵蓋到被遺漏的姊妹分支，可能導致資料被錯誤接受或拒絕後才被發現。
HIGH：新增的 runtime/共用 helper 檔案裡有明顯未使用的參數或 import 被合併進主幹；或泛型參數命名與 import namespace 衝突，已經造成 lint 規則誤判而讓真正的問題被遮蔽。
MEDIUM：僅存在於內部工具、測試輔助檔案中的死分支或未使用綁定，沒有執行期影響，但會增加閱讀與後續 review 成本。

## 反例（不該報）
- 保留姊妹分支是因為對應型別實際上仍有不同的相容性需求（例如可從 DMMF/spec 或既有測試確認兩者行為本來就不同），並非疏漏 —— 這時候不對稱是刻意設計，不該報。
- 參數雖然目前函式體內未直接使用，但是介面/型別簽章要求必須存在（例如實作某個共用介面、保留給未來多載或保持呼叫端相容），這是刻意的佔位而非死碼。
- 把泛型參數改名只是風格偏好、原本命名並未觸發任何 lint 誤報或造成混淆，這種情況下改名本身沒有修正任何實際問題，不需要當成「發現了一個 bug」來報。

## 出處
- https://github.com/prisma/prisma/pull/29924#discussion_r3736938430
- https://github.com/prisma/prisma/pull/18584#discussion_r1157459154
- https://github.com/prisma/prisma/pull/15286#discussion_r969353421
- https://github.com/prisma/prisma/pull/9561#discussion_r729754980
