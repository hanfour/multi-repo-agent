---
id: common-versioned-enum-threshold-drift
layer: common
frameworks: ["typescript@*"]
severity_default: HIGH
---
## 觸發訊號
- diff 新增或修改對「有序/會持續擴充的版本化 enum」做相等／不相等比較，例如 `moduleKind !== ModuleKind.ESNext`、`=== ModuleKind.NodeNext`、`target === ScriptTarget.ES2015`，而不是用 `>=`/`<` 做門檻比較；尤其當同一個 PR 裡有相鄰的類似判斷卻改用了 `>=`（顯示作者自己也意識到該用門檻比較）。
- diff 新增或修改一個 compiler flag／`CommandLineOption` 宣告，設定或漏設 `affectsEmit` / `affectsModuleResolution` / `affectsSemanticDiagnostics` / `affectsBuildInfo` 這類「影響增量建置快取」的 metadata，且沒有對應註解或測試證明該 flag 對 emit／resolution／增量建置的實際影響。
- diff 修改了決定 `module` / `moduleResolution` / `target` 的邏輯，或是修改產生 config（如 tsconfig 預設值）的程式碼，但輸出的字面值（例如 `"module": "esnext"`）跟該分支自己宣稱要產生的值（例如 `nodenext`）對不上。
- diff 為新增的 module/strict/target 相依程式路徑（新的 codefix、emit helper、resolution 規則）只加了單一 `@module`/`@strict`/`@target` 組合的測試，沒有對稱／相鄰組合（例如 `strictNullChecks: false`、CLI flag 覆寫 tsconfig 的情境）的測試。

## 判準
這些 enum／flag 代表一個由多人長期維護、持續成長或互相牽動的設定面。用相等比較寫死某個 enum 成員，一旦未來在「被比較的值」和「最新值」之間插入新成員（例如在 ES2021 和 ESNext 之間加入 ES2022），這段判斷就會靜靜失效——程式仍能編譯、舊測試仍會通過，問題只在使用者切到最新選項時才會現形，而且很難從 diff 本身看出來。`affects*` 這類 flag 沒有型別系統幫你檢查，設錯的後果是兩極的：多標會讓快取被不必要地打掉（效能退化），少標則會讓該打掉的快取沒打掉（增量建置吃到過期結果卻悄悄印出錯誤輸出）；資深 reviewer 判斷方式是去推導這個 flag 實際上會不會改變 emit/resolution/diagnostics 的結果，而不是照抄旁邊已有的 flag。設定產生邏輯的分支敘述和實際輸出字面值對不上，是典型「複製貼上改一半」的錯誤，一般測試只驗證產生出的 config 檔案內部自洽，抓不到「跟生成邏輯的意圖不一致」這種問題。

## 嚴重度
CRITICAL：drift／相等比較錯誤會讓實際使用者設定組合下的 emit 內容或增量建置正確性被靜靜改變（例如該重新編譯的檔案被跳過、module 格式印錯），且沒有任何測試會暴露它。
HIGH：該判斷或 metadata 會影響型別檢查／module resolution 的正確性（診斷訊息錯誤或缺漏）在一個可達的選項組合上，或是產生出的預設 config 跟文件/預期行為不一致。
MEDIUM：只影響 CLI 說明文字、分類顯示、純內部診斷，或是很少見的選項組合，且使用者有容易的替代方案。

## 反例（不該報）
- 對有序 enum 用 `===`/`!==` 比較，但那本來就是刻意做「特定分類」判斷而非「至少達到某版本」的門檻語意，例如 `moduleKind === ModuleKind.CommonJS` 專門特判 CJS，或 `=== ModuleKind.None`——這種寫法本身是對的，不需要改成 `>=`。
- 該比較是包在一個 exhaustive 的 `switch`（搭配 `default: Debug.assertNever(...)` 之類）裡面，未來加新 enum 成員時編譯器本身就會強制要求更新，沒有 drift 風險。
- `affects*` flag 刻意不設／設為 false，因為該選項本來就對 emit/resolution/diagnostics 完全沒有影響（例如純 IDE 顯示用的偏好設定）。
- 缺少的測試組合本來就是文件上寫明「互斥/不支援」的情境（例如 `moduleResolution: bundler` 搭配低於 `es2015` 的 `module`，本來就預期要噴錯）。

## 出處
- https://github.com/microsoft/TypeScript/pull/63172#discussion_r2835495001
- https://github.com/microsoft/TypeScript/pull/61696#discussion_r2379924836
- https://github.com/microsoft/TypeScript/pull/61813#discussion_r2127251222
- https://github.com/microsoft/TypeScript/pull/59963#discussion_r1775311855
- https://github.com/microsoft/TypeScript/pull/58254#discussion_r1572715437
- https://github.com/microsoft/TypeScript/pull/58201#discussion_r1568471686
- https://github.com/microsoft/TypeScript/pull/57934#discussion_r1561578741
- https://github.com/microsoft/TypeScript/pull/57668#discussion_r1515172790
- https://github.com/microsoft/TypeScript/pull/57472#discussion_r1506358458
- https://github.com/microsoft/TypeScript/pull/57267#discussion_r1504804577
- https://github.com/microsoft/TypeScript/pull/57250#discussion_r1473613935
- https://github.com/microsoft/TypeScript/pull/56570#discussion_r1417829252
- https://github.com/microsoft/TypeScript/pull/55349#discussion_r1292809474
- https://github.com/microsoft/TypeScript/pull/55291#discussion_r1286260594
- https://github.com/microsoft/TypeScript/pull/55028#discussion_r1269932020
- https://github.com/microsoft/TypeScript/pull/54788#discussion_r1259784873
- https://github.com/microsoft/TypeScript/pull/54820#discussion_r1252471508
- https://github.com/microsoft/TypeScript/pull/54817#discussion_r1245943204
- https://github.com/microsoft/TypeScript/pull/53403#discussion_r1186322985
- https://github.com/microsoft/TypeScript/pull/53590#discussion_r1153651791
- https://github.com/microsoft/TypeScript/pull/52576#discussion_r1095223880
- https://github.com/microsoft/TypeScript/pull/52437#discussion_r1088289758
- https://github.com/microsoft/TypeScript/pull/51074#discussion_r1026763506
- https://github.com/microsoft/TypeScript/pull/50789#discussion_r998808951
- https://github.com/microsoft/TypeScript/pull/49442#discussion_r892939151
- https://github.com/microsoft/TypeScript/pull/47377#discussion_r888516377
- https://github.com/microsoft/TypeScript/pull/48879#discussion_r861272300
- https://github.com/microsoft/TypeScript/pull/48264#discussion_r845477439
- https://github.com/microsoft/TypeScript/pull/48330#discussion_r839864313
- https://github.com/microsoft/TypeScript/pull/48294#discussion_r828409719
- https://github.com/microsoft/TypeScript/pull/47495#discussion_r792027328
- https://github.com/microsoft/TypeScript/pull/46486#discussion_r737929631
- https://github.com/microsoft/TypeScript/pull/44619#discussion_r703925795
- https://github.com/microsoft/TypeScript/pull/45513#discussion_r692487485
- https://github.com/microsoft/TypeScript/pull/44501#discussion_r687397965
- https://github.com/microsoft/TypeScript/pull/44501#discussion_r668299845
- https://github.com/microsoft/TypeScript/pull/44402#discussion_r647669740
- https://github.com/microsoft/TypeScript/pull/43933#discussion_r628346359
- https://github.com/microsoft/TypeScript/pull/40698#discussion_r592669504
- https://github.com/microsoft/TypeScript/pull/43084#discussion_r590892824
- https://github.com/microsoft/TypeScript/pull/43084#discussion_r590628738
- https://github.com/microsoft/TypeScript/pull/38105#discussion_r453858689
- https://github.com/microsoft/TypeScript/pull/38358#discussion_r430578289
- https://github.com/microsoft/TypeScript/pull/36997#discussion_r383596539
- https://github.com/microsoft/TypeScript/pull/36751#discussion_r378547338
- https://github.com/microsoft/TypeScript/pull/35711#discussion_r358509284
- https://github.com/microsoft/TypeScript/pull/35635#discussion_r357305404
- https://github.com/microsoft/TypeScript/pull/34683#discussion_r338314304
- https://github.com/microsoft/TypeScript/pull/33791#discussion_r334599313
- https://github.com/microsoft/TypeScript/pull/32611#discussion_r308462869
- https://github.com/microsoft/TypeScript/pull/30829#discussion_r299255951
- https://github.com/microsoft/TypeScript/pull/31483#discussion_r287007313
- https://github.com/microsoft/TypeScript/pull/29314#discussion_r246209307
- https://github.com/microsoft/TypeScript/pull/28104#discussion_r228261449
- https://github.com/microsoft/TypeScript/pull/27610#discussion_r223510611
- https://github.com/microsoft/TypeScript/pull/25633#discussion_r206678010
- https://github.com/microsoft/TypeScript/pull/24037#discussion_r187486781
- https://github.com/microsoft/TypeScript/pull/22510#discussion_r174260360
- https://github.com/microsoft/TypeScript/pull/20624#discussion_r159345482
- https://github.com/microsoft/TypeScript/pull/19675#discussion_r149193221
- https://github.com/microsoft/TypeScript/pull/19542#discussion_r148154538
- https://github.com/microsoft/TypeScript/pull/19309#discussion_r148053211
- https://github.com/microsoft/TypeScript/pull/18297#discussion_r137576966
- https://github.com/microsoft/TypeScript/pull/17469#discussion_r130174029
- https://github.com/microsoft/TypeScript/pull/16684#discussion_r124425879
- https://github.com/microsoft/TypeScript/pull/16433#discussion_r121483668
- https://github.com/microsoft/TypeScript/pull/15911#discussion_r119162631
- https://github.com/microsoft/TypeScript/pull/11889#discussion_r85378805
- https://github.com/microsoft/TypeScript/pull/11571#discussion_r83455868
- https://github.com/microsoft/TypeScript/pull/8223#discussion_r60483841
- https://github.com/microsoft/TypeScript/pull/7775#discussion_r58467552
- https://github.com/microsoft/TypeScript/pull/5590#discussion_r45139714
- https://github.com/microsoft/TypeScript/pull/4811#discussion_r39811717
- https://github.com/microsoft/TypeScript/pull/4008#discussion_r35393860
- https://github.com/microsoft/TypeScript/pull/3616#discussion_r33205935
- https://github.com/microsoft/TypeScript/pull/3509#discussion_r32392099
- https://github.com/microsoft/TypeScript/pull/2161#discussion_r25546348
- https://github.com/microsoft/TypeScript/pull/1782#discussion_r23482887
