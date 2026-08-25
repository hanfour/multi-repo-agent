---
id: common-public-api-type-surface-changes
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM

---
## 觸發訊號
diff 修改了共用/公開型別定義檔（如 `types.ts`、`protocol.ts`、`*.d.ts`、對外 API 的 factory/interface 檔）裡的 exported interface/type/class：新增或改名屬性、把 class 改成 interface（或反過來）、把 interface 改成 type/mapped type、對 exported 函式簽章新增參數、或是新增一個跟既有 interface 高度相似（多數屬性相同）的新 interface 而非從既有型別衍生。

## 判準
exported 型別是其他程式碼（有時是外部消費者）依賴的契約。資深 reviewer 在這類 diff 裡實際在檢查：
1. 新/改名的屬性名稱是否跟繼承來的屬性衝突或語意不清（例如同時有 `file` 又加 `filepath`）、或違反專案既有的命名慣例（例如用 `includeX` 正面命名而非 `disableX` 負面命名）。
2. 型別/參數形狀的變更是否會破壞既有呼叫者或已序列化的線上格式（wire format），且沒有相容層或 deprecation 路徑。
3. 新寫的 interface 是否只是既有 interface 的近似複製（大部分屬性相同），本該用 mapped type / 泛型工具衍生而不是整份複製貼上。
4. 型別的構造方式（class vs interface、interface vs type alias）是否符合實際用法（例如從未被 `new` 過的 class 應該是 interface）。

## 嚴重度
CRITICAL：修改的是 wire-protocol / 序列化型別（如 `server/protocol.ts` 的 request/response 形狀），且會破壞已有外部 client 依賴的契約，沒有任何回溯相容或 deprecation 手段。
HIGH：exported 的 factory/API 函式簽章新增了必要參數、或移除/調換既有參數順序，導致已知的內部或外部呼叫端編譯失敗。
MEDIUM：exported interface 上新增/改名的屬性命名含糊或與既有命名慣例不一致（含與繼承屬性衝突），或新 interface 複製了既有型別的大部分結構卻沒有共用/衍生。

## 反例（不該報）
- 純內部（未 export）的型別變更，沒有外部消費者。
- 改的是真正屬於區域實作細節的屬性名稱。
- 對 exported interface 新增「可選（optional）」屬性——這是加法性、不破壞相容性的變更。
- 刻意建立的近似型別，但大多數屬性其實不同（近似複製的疑慮只在「多數屬性相同」時才成立）。
- 用明確 `@deprecated` 別名保留舊名稱以維持相容性的改法。

## 出處
- https://github.com/microsoft/TypeScript/pull/60540#discussion_r1871908107
- https://github.com/microsoft/TypeScript/pull/58398#discussion_r1591218909
- https://github.com/microsoft/TypeScript/pull/57361#discussion_r1509594474
- https://github.com/microsoft/TypeScript/pull/55406#discussion_r1492619973
- https://github.com/microsoft/TypeScript/pull/57361#discussion_r1484849251
- https://github.com/microsoft/TypeScript/pull/56915#discussion_r1439050115
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1334741261
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1333648584
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1329327795
- https://github.com/microsoft/TypeScript/pull/55442#discussion_r1324925783
- https://github.com/microsoft/TypeScript/pull/54148#discussion_r1186432224
- https://github.com/microsoft/TypeScript/pull/53542#discussion_r1162035177
- https://github.com/microsoft/TypeScript/pull/51081#discussion_r989254702
- https://github.com/microsoft/TypeScript/pull/40698#discussion_r705653114
- https://github.com/microsoft/TypeScript/pull/44148#discussion_r634716318
- https://github.com/microsoft/TypeScript/pull/42640#discussion_r571230487
- https://github.com/microsoft/TypeScript/pull/42154#discussion_r554257372
- https://github.com/microsoft/TypeScript/pull/39119#discussion_r451053600
- https://github.com/microsoft/TypeScript/pull/32788#discussion_r313149049
- https://github.com/microsoft/TypeScript/pull/30829#discussion_r299288970
- https://github.com/microsoft/TypeScript/pull/23591#discussion_r185653818
- https://github.com/microsoft/TypeScript/pull/23438#discussion_r182233940
- https://github.com/microsoft/TypeScript/pull/18559#discussion_r150082832
- https://github.com/microsoft/TypeScript/pull/18559#discussion_r149836185
- https://github.com/microsoft/TypeScript/pull/5879#discussion_r46370246
- https://github.com/microsoft/TypeScript/pull/5590#discussion_r44736267
- https://github.com/microsoft/TypeScript/pull/889#discussion_r20411827
