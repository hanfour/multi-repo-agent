---
id: common-css-shorthand-precision-loss
layer: common
frameworks: ["css@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 把原本分開列出的多個 CSS longhand 屬性（如 `font-size` + `font-weight` + `font-family`、或 `margin-top/right/bottom/left`、`border-width/style/color`）合併成單一 shorthand（如 `font: ...`、`margin: ...`、`border: ...`），且合併後的 shorthand 沒有明確列出原本每一個 longhand 對應的子屬性值。同類訊號也包含：框架內部維護的 CSS 屬性名單（如判斷「數值是否需要單位」的 allowlist）只新增單一 vendor-prefixed 變體（如 `-webkit-line-clamp`），卻沒有比照名單中其他屬性一起加上對應的前綴版本，造成名單覆蓋範圍不一致。

## 判準
CSS shorthand 會把所有未明確指定的子屬性重設為初始值（initial value），不是「維持原樣」。原作者用 longhand 只寫出想要的那幾個屬性，往往是刻意的——可能刻意不覆寫某個子屬性、讓它繼承父層或維持瀏覽器預設。改成 shorthand 之後，這個「刻意省略」會被靜默抹掉，變成該屬性的隱式重置，是語意不等價的重構，容易在其他地方（不同瀏覽器寬度、父層樣式、動態改值的程式碼）出現視覺回歸。屬性名單只挑一個特例加前綴版本則是另一種精度問題：名單其餘項目都是非前綴標準屬性，單獨加一個前綴版本會讓名單語意變得不一致（「這裡支援部分前綴，但不是全部」），之後每多一個真實需求就要再補一次，而不是一次把政策定清楚。

## 嚴重度
CRITICAL：shorthand 合併覆寫掉的子屬性被其他地方（JS 動態設值、主題/暗色模式覆寫、多處元件共用的樣式）依賴為可獨立覆寫，導致大範圍元件在特定情境下樣式錯誤且不易察覺。
HIGH：shorthand 合併後某個子屬性被重設為初始值且該值在目前頁面/元件確實可見（例如原本繼承的 `font-family` 被改寫成別的字型），造成使用者可見的視覺回歸。
MEDIUM：合併僅出現在範例、文件、benchmark 或非關鍵路徑的樣式，或屬性名單的不一致新增目前沒有已知的實際 bug，但已建立會被後續 PR 複製的不良先例。

## 反例（不該報）
shorthand 明確列出了它隱含的每一個子屬性值（沒有任何值被留給預設），且程式庫中沒有其他地方會個別覆寫其中某個子屬性——此時 shorthand 與原本的 longhand 完全等價，不該報。屬性名單只新增一個確定要支援、且該次 PR 明確聲明「先只處理這個 case、其餘前綴版本留待未來按需求再加」並經 reviewer 認可範圍的新增，也不該報——刻意收斂範圍是合理的漸進式擴充，不是不一致。

## 出處
- https://github.com/vuejs/vue/pull/7702#discussion_r170222769
- https://github.com/vuejs/vue/pull/2842#discussion_r63297753
- https://github.com/vuejs/core/pull/6636#discussion_r980983567
