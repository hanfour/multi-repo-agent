---
id: common-thread-resolution-context-through-nested-calls
layer: common
frameworks: ["typescript@*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或修改一個「resolution / lookup helper」函式，其簽名帶有像 `host`、`options` / `compilerOptions`、`cache`、`redirectedReference`、`ignoreCase` 這類「上下文物件」，並且：
- 內部呼叫另一個同類 helper、遞迴呼叫自己、或建立/讀取一個新的 cache entry，卻只轉傳了部分上下文參數（例如漏了 `redirectedReference`、漏了 `ignoreCase`／大小寫敏感度、或漏了要用來判斷「該不該建立 cache」的 host 能力如 `readFile`）；
- 用字串路徑比較（`comparePaths`、`startsWith`、`endsWith`、`substring`/`lastIndexOf` 抽取副檔名）卻沒有沿用呼叫端已經算好的大小寫規則或「已去除副檔名的 baseName」，而是重新對完整路徑做一次容易算錯的字串運算；
- 針對 `CompilerOptions` 上的個別欄位（尤其是 `@internal` 或新加的旗標）新增分支邏輯，但沒有同步更新用來判斷「這個 options 變了要不要讓 cache/buildinfo 失效」的比較函式（如 `compilerOptionsAffectSemanticDiagnostics`、`changedCompileOptionValueOf`、`convertToProgramBuildInfoCompilerOptions` 這類集中維護的欄位清單）。

## 判準
這些 helper 承載的 host/options/cache/redirectedReference 是「解析結果是否正確、是否可重用」的隱含前提。下游呼叫少傳一個欄位，通常不會立刻報錯或讓測試失敗，而是在特定條件下（大小寫不敏感檔案系統、有 project reference 的 build、cache 為唯讀、內部旗標被使用）產生「安靜地算出錯誤但看起來合理」的結果——這正是 resident reviewer 會盯著這類簽名改動反覆確認「context 有沒有原封不動往下傳」的原因，而不是因為它會馬上壞掉。

## 嚴重度
CRITICAL：遺漏會讓 incremental/build info 快取產生**不會自動失效**的錯誤結果（使用者需手動清快取才能修正），或讓已快取的解析結果在真實輸入改變後仍被視為有效。

HIGH：遺漏 `redirectedReference`、`ignoreCase`、或用來判斷資源可否寫入的 host 能力（如 `readFile` 是否存在），導致在跨平台大小寫檔案系統或有 project reference 的情境下解析出錯誤的模組/型別，且該差異不容易被既有單元測試覆蓋到。

MEDIUM：遺漏的 context 只影響效能（例如本該用唯讀快取查詢卻誤用了會建立節點的版本）、或只在極罕見 edge case（symlink、`peerDependencies` 版本推導、pnpm 專屬路徑）才會出現落差，多數使用者不受影響。

## 反例（不該報）
- helper 呼叫下游函式時，該下游函式定義本來就只需要這個參數子集，沒有漏傳任何它宣告需要的東西。
- PR 討論/註解中作者已明確說明這是刻意的 scope 決策（例如「這是 `@internal` 選項，公開 API 根本無法觸發，所以故意不處理它對 cache 失效的影響」），屬於已知取捨而非疏漏。
- 純粹的型別/命名重構（例如把陣列改成 bitflag enum、把巢狀 namespace 拆成 export function），語意與傳遞的上下文完全沒變。
- 新增的分支只是把既有邏輯抽成獨立函式並原封不動地把所有原參數轉傳下去，沒有減少或改變任何參數。

## 出處
- https://github.com/microsoft/TypeScript/pull/62641#discussion_r2445773200
- https://github.com/microsoft/TypeScript/pull/60019#discussion_r1768970756
- https://github.com/microsoft/TypeScript/pull/59645#discussion_r1718881367
- https://github.com/microsoft/TypeScript/pull/58839#discussion_r1638984383
- https://github.com/microsoft/TypeScript/pull/58312#discussion_r1580163446
- https://github.com/microsoft/TypeScript/pull/58312#discussion_r1579904180
- https://github.com/microsoft/TypeScript/pull/58176#discussion_r1571073328
- https://github.com/microsoft/TypeScript/pull/58176#discussion_r1567779694
- https://github.com/microsoft/TypeScript/pull/58176#discussion_r1563335300
- https://github.com/microsoft/TypeScript/pull/57934#discussion_r1561760994
- https://github.com/microsoft/TypeScript/pull/57896#discussion_r1550203022
- https://github.com/microsoft/TypeScript/pull/57973#discussion_r1542109521
- https://github.com/microsoft/TypeScript/pull/57673#discussion_r1532935057
- https://github.com/microsoft/TypeScript/pull/57718#discussion_r1519490955
- https://github.com/microsoft/TypeScript/pull/57029#discussion_r1499889095
- https://github.com/microsoft/TypeScript/pull/57421#discussion_r1491683545
- https://github.com/microsoft/TypeScript/pull/57029#discussion_r1449611748
- https://github.com/microsoft/TypeScript/pull/55015#discussion_r1402377010
- https://github.com/microsoft/TypeScript/pull/56064#discussion_r1365948132
- https://github.com/microsoft/TypeScript/pull/55725#discussion_r1330516327
- https://github.com/microsoft/TypeScript/pull/55015#discussion_r1376883064
- https://github.com/microsoft/TypeScript/pull/55015#discussion_r1376855262
- https://github.com/microsoft/TypeScript/pull/54831#discussion_r1256136488
- https://github.com/microsoft/TypeScript/pull/54819#discussion_r1246878791
- https://github.com/microsoft/TypeScript/pull/54819#discussion_r1245891667
- https://github.com/microsoft/TypeScript/pull/54278#discussion_r1196447873
- https://github.com/microsoft/TypeScript/pull/52908#discussion_r1128254724
- https://github.com/microsoft/TypeScript/pull/52940#discussion_r1116161550
- https://github.com/microsoft/TypeScript/pull/52298#discussion_r1083104936
- https://github.com/microsoft/TypeScript/pull/52336#discussion_r1082990605
- https://github.com/microsoft/TypeScript/pull/52298#discussion_r1081950263
- https://github.com/microsoft/TypeScript/pull/50955#discussion_r1051264036
- https://github.com/microsoft/TypeScript/pull/51669#discussion_r1043947752
- https://github.com/microsoft/TypeScript/pull/51669#discussion_r1041236773
- https://github.com/microsoft/TypeScript/pull/51546#discussion_r1039956040
- https://github.com/microsoft/TypeScript/pull/50996#discussion_r1021960588
- https://github.com/microsoft/TypeScript/pull/51471#discussion_r1019681164
- https://github.com/microsoft/TypeScript/pull/50293#discussion_r947077081
- https://github.com/microsoft/TypeScript/pull/50151#discussion_r937227407
- https://github.com/microsoft/TypeScript/pull/50163#discussion_r936966860
- https://github.com/microsoft/TypeScript/pull/49598#discussion_r901861783
- https://github.com/microsoft/TypeScript/pull/48784#discussion_r891811293
- https://github.com/microsoft/TypeScript/pull/49327#discussion_r886123275
- https://github.com/microsoft/TypeScript/pull/48865#discussion_r879755372
- https://github.com/microsoft/TypeScript/pull/48980#discussion_r874267359
- https://github.com/microsoft/TypeScript/pull/48995#discussion_r867064320
- https://github.com/microsoft/TypeScript/pull/48784#discussion_r854606681
- https://github.com/microsoft/TypeScript/pull/48386#discussion_r849712956
- https://github.com/microsoft/TypeScript/pull/47377#discussion_r821049083
- https://github.com/microsoft/TypeScript/pull/47427#discussion_r787147752
- https://github.com/microsoft/TypeScript/pull/47092#discussion_r782443337
- https://github.com/microsoft/TypeScript/pull/47092#discussion_r770051158
- https://github.com/microsoft/TypeScript/pull/46486#discussion_r734891128
- https://github.com/microsoft/TypeScript/pull/46486#discussion_r734826166
- https://github.com/microsoft/TypeScript/pull/46159#discussion_r720377320
- https://github.com/microsoft/TypeScript/pull/44602#discussion_r655671707
- https://github.com/microsoft/TypeScript/pull/44176#discussion_r645899897
- https://github.com/microsoft/TypeScript/pull/44078#discussion_r635645457
- https://github.com/microsoft/TypeScript/pull/44090#discussion_r632815860
- https://github.com/microsoft/TypeScript/pull/43892#discussion_r624164053
- https://github.com/microsoft/TypeScript/pull/43695#discussion_r615165210
- https://github.com/microsoft/TypeScript/pull/43666#discussion_r613542715
- https://github.com/microsoft/TypeScript/pull/43199#discussion_r600699043
- https://github.com/microsoft/TypeScript/pull/41330#discussion_r515417143
- https://github.com/microsoft/TypeScript/pull/39669#discussion_r488313827
- https://github.com/microsoft/TypeScript/pull/40101#discussion_r480427957
- https://github.com/microsoft/TypeScript/pull/39679#discussion_r459004130
- https://github.com/microsoft/TypeScript/pull/35956#discussion_r393296916
- https://github.com/microsoft/TypeScript/pull/35332#discussion_r350448711
- https://github.com/microsoft/TypeScript/pull/32372#discussion_r328203820
- https://github.com/microsoft/TypeScript/pull/33293#discussion_r322485871
- https://github.com/microsoft/TypeScript/pull/33216#discussion_r320477140
- https://github.com/microsoft/TypeScript/pull/32612#discussion_r308945676
- https://github.com/microsoft/TypeScript/pull/29314#discussion_r248099103
- https://github.com/microsoft/TypeScript/pull/29161#discussion_r247618655
- https://github.com/microsoft/TypeScript/pull/27980#discussion_r230938328
- https://github.com/microsoft/TypeScript/pull/27980#discussion_r226708270
- https://github.com/microsoft/TypeScript/pull/26310#discussion_r209352704
- https://github.com/microsoft/TypeScript/pull/26200#discussion_r207703299
- https://github.com/microsoft/TypeScript/pull/25368#discussion_r199599757
- https://github.com/microsoft/TypeScript/pull/25049#discussion_r196249219
- https://github.com/microsoft/TypeScript/pull/24328#discussion_r190042418
- https://github.com/microsoft/TypeScript/pull/24211#discussion_r189386193
- https://github.com/microsoft/TypeScript/pull/24211#discussion_r189078576
- https://github.com/microsoft/TypeScript/pull/22420#discussion_r179630037
- https://github.com/microsoft/TypeScript/pull/22658#discussion_r175598071
- https://github.com/microsoft/TypeScript/pull/21930#discussion_r174667996
- https://github.com/microsoft/TypeScript/pull/22254#discussion_r173588290
- https://github.com/microsoft/TypeScript/pull/20464#discussion_r155339067
- https://github.com/microsoft/TypeScript/pull/17269#discussion_r141196846
- https://github.com/microsoft/TypeScript/pull/17669#discussion_r133104011
- https://github.com/microsoft/TypeScript/pull/17669#discussion_r133073697
- https://github.com/microsoft/TypeScript/pull/17302#discussion_r128644827
- https://github.com/microsoft/TypeScript/pull/17257#discussion_r128126972
- https://github.com/microsoft/TypeScript/pull/12231#discussion_r100868929
- https://github.com/microsoft/TypeScript/pull/12231#discussion_r100428834
- https://github.com/microsoft/TypeScript/pull/13678#discussion_r98095536
- https://github.com/microsoft/TypeScript/pull/12153#discussion_r91819909
- https://github.com/microsoft/TypeScript/pull/12231#discussion_r89257298
- https://github.com/microsoft/TypeScript/pull/9353#discussion_r76346087
- https://github.com/microsoft/TypeScript/pull/9430#discussion_r69034480
- https://github.com/microsoft/TypeScript/pull/9646#discussion_r75387615
- https://github.com/microsoft/TypeScript/pull/9353#discussion_r71959597
- https://github.com/microsoft/TypeScript/pull/5471#discussion_r43542937
- https://github.com/microsoft/TypeScript/pull/4738#discussion_r39225763
- https://github.com/microsoft/TypeScript/pull/987#discussion_r20675416
