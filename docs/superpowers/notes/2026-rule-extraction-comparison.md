# 兩條規則萃取路線的回測比較

## 執行條件

四條路線跑在同一個基準集上，`candidates_sha` 都是 `7a8226ee333100a9`。

| 路線 | 說明 |
| --- | --- |
| standard+codex | 今天團隊實際在用的設定（provider codex、model gpt-5.5、reasoning effort xhigh） |
| personas | 五個 persona 平行審查後 synthesize，provider claude、model sonnet |
| rules-tfidf | 同 personas，但 4 個 persona 的 FOCUS 區塊注入 TF-IDF 分群萃出的 140 條規則 |
| rules-taxonomy | 同 personas，但注入依 finding 分類萃出的 37 條規則 |

兩條規則路線與 personas 基準線的差別只有規則，其餘條件相同：
`MRA_REVIEW_PERSONA_MAX_TURNS=20`、synthesize 8 輪、worktree 隔離、三點 range。
`test-architect` 沒有 FOCUS 錨點，兩條路線都跳過不注入，當作對照組。

### 實際進 prompt 的是 7 條與 8 條，不是 140 條與 37 條

注入量由 token 預算（5000）控制，規則依出處數由多到少排進去，額度用完就停。
兩條路線萃出的規則總數是 140 與 37，但實際進 prompt 的是：

| 路線 | 目錄裡 | 進 prompt | 進去的是什麼 |
| --- | --- | --- | --- |
| tfidf | 140 | 7 | common 層 81 條裡出處數最高的 7 條 |
| taxonomy | 37 | 8 | common 層的全部 8 條 |

注入只用 common 層，rails、react、vue、nestjs 四層的規則一條都沒進 prompt。
注入後 4 個 persona 各增加 65 行（tfidf）或 85 行（taxonomy），檔案大小 18.3
到 18.6 KB 與 20.5 到 20.8 KB。

這改變了這份比較在測什麼。它不是「140 條規則對 37 條規則」，是「兩種組織方式
各自產出的 common 層頭部，在同一個 token 預算下誰比較有用」。

tfidf 進去的 7 條是：`common-unverified-ast-node-provenance`、
`common-unexplained-snapshot-baseline-diff`、`common-hardcoded-version-drift`、
`common-async-thenable-state-machine-guard`、
`common-thread-resolution-context-through-nested-calls`、
`common-ci-build-config-drift`、`common-versioned-enum-threshold-drift`。

taxonomy 進去的 8 條是它的 common 層全部：`missing-convention-untested-logic-branch`、
`test-quality-unverified-invariant-assertion`、`cache-invalidation`、
`domain-logic-uncovered-sibling-case`、`framework-semantics-missing-mode-interaction`、
`missing-state-case`、`error-guard-condition-incomplete-category-coverage`、
`shared-state-scope`。

出處數排序對兩條路線是同一個規則，但它挑出來的東西完全不同：TF-IDF 依主題
分群，出處數最高的群就是語料量最大的 repo 的內部機制；依 finding 分類的
八個類別本來就是照缺陷形狀切的，取全部剛好是一套完整的形狀清單。

## 三個指標，不是一個

階段二只報行號容差下的漏抓率。這次加了第三個指標，因為前兩個會把兩件不同的事
混在一起。

| 指標 | 定義 |
| --- | --- |
| 漏抓 ±5 | expected finding 的行號 ±5 行內沒有任何 comment |
| 漏抓 ±15 | 同上，容差放寬到 ±15 行 |
| 同檔完全沒講 | expected finding 所在的檔案裡，一條 comment 都沒有 |

第三個指標的必要性來自一個實例。`react-app-1#201` 有一條 CRITICAL：
設定頁沒有任何權限控管，expected 標在 `settings-page.tsx:52`。基準線與帶
規則的兩輪其實都抓到了這件事，comment 分別落在 `:93` 與 `:92`，離 expected
40 行，兩個容差都算漏。

把「±15 算漏但同檔有講」單獨列出來，就能分辨兩件事：reviewer 沒看到那個地方，
還是看到了但錨點落在幾十行外。基準線 personas 全量 38 個 PR 的 37 條 ±15
漏抓裡，13 條是後者，只有 24 條是真的完全沒看到。

### 配對只看行距，不看內容

三個指標共用同一個配對函式，它為每條 expected finding 挑最近的同檔 comment，
一對一，不比對內容。這會挑錯。

`rails-app-1#4832` 的 expected 是「`render_table` 用 `Array#join` 沒給分隔字串」，標在
`:115`。基準線與 taxonomy 那輪都產出了 `:124` 的 CRITICAL，內容正是這個缺陷，
距離 9 行，在 ±15 內。

但配對只挑一條，而且挑最近的。基準線那輪同檔還有一條 `:119` 的 MEDIUM（距離 4，
講寬度值被寫死兩處），它贏了；taxonomy 那輪是 `:117` 的 MEDIUM（距離 2，講陣列
拼接的風格）贏。兩輪都記為命中 1/1，命中的都是講樣式的 MEDIUM，真正抓對的
CRITICAL 都被算成未對應。

所以命中不等於抓對，未對應也不等於沒抓到。這一輪的所有數字都帶著這個誤差，
兩條路線受到的影響方向相同，比較仍然成立，但絕對值不能當成「抓對了幾條」讀。

## TF-IDF 路線

36 個共同 PR、51 條 expected。1 條 finding 約 1.96 個百分點。

| 路線 | 漏抓 ±5 | 漏抓 ±15 | 同檔完全沒講 | 錨點漂移 | 產出 comment |
| --- | --- | --- | --- | --- | --- |
| standard+codex | 0.88 (45) | 0.82 (42) | 0.75 (38) | 4 | 29 |
| personas | 0.84 (43) | 0.67 (34) | 0.43 (22) | 12 | 205 |
| rules-tfidf | 0.88 (45) | 0.75 (38) | 0.43 (22) | 16 | 194 |

同檔完全沒講兩邊完全相同，都是 22 條。±15 差 4 條，錨點漂移也差 4 條，兩個
數字互相抵銷。產出量幾乎沒動，205 對 194。

也就是說，注入 140 條 TF-IDF 規則之後，reviewer 看的還是同一批檔案、講的還是
差不多的量，改變的只有 comment 落在檔案裡的哪一行，而那個改變讓 4 條 finding
掉出容差窗。

### 為什麼會這樣

逐 PR 看落點就看得出來。`rails-app-1#4829` 的三條 expected 都在
`app/services/docx_html_converter.rb`：`:38` 條件寫反、`:48` 圖片以未壓縮
base64 內嵌、`:118` `Array#join` 沒給分隔字串。基準線命中 `:38`，那是「這行
做了 X，X 是錯的」的形狀。帶規則的那輪在同一個檔案講了 `:106` 的儲存型 XSS
與 `:235` 的 href 驗證，也講了 `file_uploader.rb` 的解壓縮炸彈，三條都是真的
問題，但三條 expected 一條都沒碰到。

`rails-app-1#4840` 是同一個形狀。基準線命中 `report_export.rb:1154` 與
`demographic_event.rb:23`，帶規則後同一批檔案的 comment 移到 `:1203` 與
`:80`／`:140`，講的是 migration 與 schema 的一致性、N+1 查詢、`next if` 的
累加值判斷。

規則把注意力重新分配到跨檔案的關注點，離開了 diff 裡那些局部的邏輯錯誤。

### 規則來源的分布

| 層 | 條數 | 出處 repo |
| --- | --- | --- |
| common | 81 | microsoft/TypeScript 960、prisma/prisma 462、facebook/react 334，其餘 250 |
| rails | 21 | rails/rails 515 |
| vue | 20 | vuejs/core 258、vuejs/vue 81 |
| react | 15 | facebook/react 191、microsoft/TypeScript 14 |
| nestjs | 3 | nestjs/swagger 12、nestjs/nest 12、prisma/prisma 1 |

common 層的出處有 48% 來自 microsoft/TypeScript。實際注進 `security-auditor`
的第一條 common 規則，內容是 TypeScript compiler 內部的 `Node.parent`、
`bindSourceFile`、合成節點與 `getParseTreeNode`，要求審查者確認節點是原始
parse tree 節點還是轉換後節點。這條規則拿去審 Acme 的 Rails 與 Vue 程式碼
沒有可以觸發的條件，但它佔著 prompt 預算。

依主題分群會讓語料量最大的 repo 主導 common 層，浮出來的是那個專案的內部機制。

### 被丟棄的群

TF-IDF 分群產出的群不是每一個都變成規則。50 個群被丟棄，全部是同一個原因：
出處太少，一個群裡只有一到兩則 review comment 支撐。

| 原因 | 群數 |
| --- | --- |
| 出處只有 1 則 | 30 |
| 出處只有 2 則 | 20 |

依層分布：rails 15、common 12、react 10、nestjs 7、vue 6。規則檔的 schema
要求至少三則出處，這道門檻擋掉的正是「一個人講過一次的個人偏好」。

依 finding 分類的路線沒有丟棄任何類別：八類乘以五層是 40，實際產出 37 條，
少的三條是 nestjs 與 react 層在某些類別下找不到足夠的出處。

## 規則注入的部署成本

同樣的 `MRA_REVIEW_PERSONA_MAX_TURNS=20` 與 synthesize 8 輪之下：

| 路線 | 成功筆數 | 失敗 | 注入量 |
| --- | --- | --- | --- |
| personas 基準線 | 38/38 | 0 | 無 |
| rules-tfidf | 36/38 | 2 | 7 條，65 行，18.3 KB |
| rules-taxonomy | 38/38 | 0 | 8 條，85 行，20.5 KB |

注入量較大的那條路線零失敗，注入量較小的失敗兩次。所以不能說「注入規則會壓縮
synthesize 預算」，注入量與失敗率在這兩輪上是反向的。

tfidf 那兩次失敗在發生當下讀 `.err`，訊息是 synthesize 的 `Reached max turns
(8)`。但這兩筆的 `.err` 事後被回測腳本的容差重算覆寫了（那個缺陷已修，見
`--recompute`），現在留下的是 OAuth 過期的訊息，無法再從檔案驗證。

能確定的只有：兩輪跑在相同的 turn 設定下，tfidf 少完成 2 筆，taxonomy 沒有。
失敗原因缺乏可驗證的證據，這一節不下因果結論。沒有調高 synthesize 輪數，因為
基準線就是跑在 8 輪下的，調高會讓帶規則那輪跑在比基準線寬鬆的條件下。

## 依 finding 分類的路線

37 條規則，八類缺陷形狀乘以五層。八類來自階段二回測的 47 條漏抓分類：缺席、
狀態範圍、框架語意、狀態遺漏、測試品質、快取一致性、錯誤守衛、領域邏輯。

規則來源集中度與 TF-IDF 路線相近：common 層 8 條的出處全部來自
microsoft/TypeScript，其餘各層對得上自己的框架。兩條路線的語料來源相近這件事
讓比較更乾淨，差異來自組織方式而不是取材範圍。

36 個共同 PR、51 條 expected，與 TF-IDF 路線同一張表。

| 路線 | 漏抓 ±5 | 漏抓 ±15 | 同檔完全沒講 | 錨點漂移 | 產出 comment |
| --- | --- | --- | --- | --- | --- |
| standard+codex | 0.88 (45) | 0.82 (42) | 0.75 (38) | 4 | 29 |
| personas | 0.84 (43) | 0.67 (34) | 0.43 (22) | 12 | 205 |
| rules-tfidf | 0.88 (45) | 0.75 (38) | 0.43 (22) | 16 | 194 |
| rules-taxonomy | 0.76 (39) | 0.67 (34) | 0.45 (23) | 11 | 184 |

±5 少漏 4 條，約 7.8 個百分點。±15 與基準線完全相同，都是 34 條。同檔完全
沒講多 1 條，在雜訊範圍內。

改善集中在 ±5 這一格：taxonomy 沒有讓 reviewer 看到更多檔案，也沒有在 ±15
之下多抓，但 ±5 之下少漏 4 條。

## 兩條路線的機制

把每一條 expected finding 在兩輪之間的落點區間變化列出來，就能看出這 4 條
從哪裡來。

兩張表都限制在同一批 36 個共同 PR、51 條 expected。區間依「同檔最近的一條
comment 差幾行」分成 ≤5、6-15、>15、同檔完全沒有四格。這個算法與三個指標用的
配對函式不同：配對函式是一對一分配，同一條 comment 不會被兩個 expected 認領，
這裡則單純取最近距離。兩者在多數情況下一致，差異出現在同檔有多條 expected 時。

taxonomy 相對基準線，完整的 11 種轉移：

| 轉移 | 條數 |
| --- | --- |
| 無 → 無 | 19 |
| ≤5 → ≤5 | 8 |
| >15 → >15 | 6 |
| 6-15 → 6-15 | 5 |
| >15 → 無 | 4 |
| 6-15 → ≤5 | 3 |
| 6-15 → >15 | 2 |
| 無 → 6-15 | 1 |
| 無 → ≤5 | 1 |
| 無 → >15 | 1 |
| >15 → 6-15 | 1 |

±5 命中從 8 條增為 12 條。四條進帳（`6-15→≤5` 三條、`無→≤5` 一條），零條流失
（沒有任何 `≤5→` 其他區間）。

tfidf 相對基準線，完整的 13 種轉移：

| 轉移 | 條數 |
| --- | --- |
| 無 → 無 | 17 |
| >15 → >15 | 6 |
| ≤5 → ≤5 | 5 |
| 無 → >15 | 4 |
| 6-15 → 6-15 | 4 |
| 6-15 → >15 | 4 |
| >15 → 無 | 4 |
| ≤5 → >15 | 2 |
| 無 → 6-15 | 1 |
| 6-15 → 無 | 1 |
| 6-15 → ≤5 | 1 |
| ≤5 → 6-15 | 1 |
| >15 → 6-15 | 1 |

±5 命中從 8 條減為 6 條。三條原本錨在 5 行內的被推出去（`≤5→>15` 兩條、
`≤5→6-15` 一條），只換回一條。

兩條路線的同檔有講幾乎沒變（tfidf 29 對 29、taxonomy 29 對 28），產出量也接近
（194、184 對基準線 205）。

但總數相同不等於同一批檔案。逐 PR 比對 comment 涵蓋的檔案集合，36 個 PR 裡只有
6 個兩輪完全相同，其餘 30 個（tfidf）與 32 個（taxonomy）都不同。規則確實改變
了 reviewer 看哪些檔案，只是換進來與換出去的數量剛好接近。

能說的只有這句：兩條路線都沒有讓 reviewer 看到「更多」檔案，總量沒動。差別在
錨點往哪邊移動，taxonomy 往內收，tfidf 往外散。

## 未對應的 comment 是什麼

taxonomy 那輪 ±15 之下有 177 條未對應 comment。依階段二寫定的規則抽樣 70 條
（CRITICAL 全取 12、HIGH 每 2 取 1 共 33、MEDIUM 每 4 取 1 共 25），逐條分成
三類。12 條 CRITICAL 全部實查，HIGH 與 MEDIUM 另外實查 28 條。

| 類別 | 條數 | CRITICAL | HIGH | MEDIUM |
| --- | --- | --- | --- | --- |
| 無修復 commit | 58 | 6 | 29 | 23 |
| 漏判 | 9 | 6 | 1 | 2 |
| 誤報 | 3 | 0 | 3 | 0 |

誤報率 3/70。未對應率 0.94 與誤報率不是同一件事，差了兩個數量級。

### 三條誤報

每一條都實際查過才判定，不是憑讀起來可疑：

`rails-app-1#4900` 說 sonar-scanner-cli 的 tag 可能不存在會擋住 pipeline。查 Docker Hub
API，那個 tag 在本次 PR 之前就已推送且仍是 active，development 分支至今沿用
同一個 tag。

`react-app-1#150` 說某端點跳過了專案標準的 `{data}` 信封。查 mockoon
fixture，那個端點的契約本來就是裸 body，同層的另一個端點才有信封。這個 repo
兩種形狀並存，「全專案統一信封」這個前提本身是錯的。

`nest-monorepo-2.0#792` 說 columns 沒包 `useMemo` 會有效能問題。查 vite 設定、
ADR 0004 與 AGENTS.md，React Compiler 的 infer mode 全域生效，那個 component
沒有 opt-out，會被自動記憶化。整個 frontend 只有 10 個檔案用 `useMemo`。

三條的共同形狀：規則描述的問題在一般情況下成立，但這個 codebase 的實際設定
讓它不適用。這是規則注入的固有風險，靠讀 diff 看不出來。

### 九條漏判

六條是基準集該收卻沒收，而且事後真的有人修：`react-app-1#176` 的兩個
必填欄位不在 mock 回應裡（後續 commit 補上 mock 欄位）、同一個 PR 的 mockoon
缺路由（「補齊缺漏路由」那顆 commit 補上）、`#148` 的型別與執行期白名單漂移
（三顆 commit 照建議改成 `safeParse`）、`#200` 的 `perspective` 用裸
`z.string()`（隔天的 PR #201 改成 `z.enum`）、`nest-monorepo-2.0#784` 的新路由
沒有 e2e（後續 commit 加了對應的 describe）。

最後這一條的成因在基準集本身：那顆補 e2e 的 commit 本來就在 fix_commits 裡，
但建基準集時只從它收了 IDOR 那一條，漏收 e2e 缺口。

另外三條全是 CRITICAL，不是基準集的問題，是配對挑錯：

| PR | expected 位置 | 被誰配走 |
| --- | --- | --- |
| rails-app-1#4832 | 同檔 :115 | 行距更近、內容不相干的 MEDIUM |
| rails-app-1#4869 | 同檔 :78 | 同行號的測試覆蓋 HIGH |
| react-app-1#201 | 同檔 :52 | 行差 40，超出 ±15 |

這三條印證了前面那一節：命中不等於抓對。三條 CRITICAL 都被抓到了，指標記的
是漏抓。

### 對指標的意涵

未對應率不是誤報率，這與階段二的判讀一致。但抽樣同時查出兩個方向的偏差：
基準集漏收了一些後來真的被修的缺陷（低估 reviewer），配對又把抓對的算成漏抓
（同樣低估）。兩個偏差方向相同，所以四條路線的漏抓率都比真實值高，比較的
相對關係不受影響。

## 結論

依 finding 分類的組織方式勝出。在同一個 5000 token 預算下，它的 common 層
8 條全部進 prompt，TF-IDF 的 common 層 81 條裡只進得去出處數最高的 7 條，
±5 漏抓率 0.76 對 0.88。

差距不是雜訊。逐條配對 51 個 expected finding，只有 taxonomy 命中的有 6 條，
只有 tfidf 命中的有 0 條，其餘 45 條兩邊表現相同。這是完全單向的差異，
McNemar 精確檢定 p ≈ 0.016。

taxonomy 相對於無規則的基準線也有改善，±5 少漏 4 條，且四條都是進帳、零條
流失。tfidf 相對基準線是退步，±5 多漏 2 條、±15 多漏 4 條。

四個限制要一併記住。

第一，這比的不是「140 條對 37 條」。實際進 prompt 的是 7 條與 8 條，而且都
只有 common 層。rails、react、vue、nestjs 四層的規則從未被測試過。分層注入
是階段四的工作。

第二，規則沒有動到最大的缺口。同檔完全沒講在三條 persona 路線上是 22、22、23，
幾乎沒動（standard+codex 是 38，因為它只產出 29 條 comment）。階段二分類指出
85% 的漏抓是「reviewer 在那個檔案裡一句話都沒說」，這一輪的規則改變的是既有
注意力的落點，不是它的範圍。

第三，改善的絕對量小。taxonomy 的 ±5 漏抓率仍有 0.76，51 條 expected 裡漏掉
39 條。以「拿去當團隊 code review skill」的標準看，這個數字還不能用。

第四，指標本身有誤差，而且是雙向低估。抽樣 70 條未對應 comment 判讀出 9 條
漏判：6 條是基準集該收卻沒收（事後真的有人修），3 條是配對把抓對的 CRITICAL
算成漏抓。兩個偏差方向相同，四條路線的漏抓率都比真實值高。

比較的相對關係不受影響：兩條路線的誤配暴險相近（38%、33%、33%），用最悲觀
的方式折抵之後，只有 taxonomy 命中的仍有 8 條、只有 tfidf 的 4 條，方向不翻。
另外 taxonomy 的產出量是三條 persona 路線裡最少的（184 對 194 對 205）卻命中
最多，排除了「講得多比較容易矇到」這個偏誤。

第五，規則會帶進與 codebase 實際設定衝突的判準。70 條抽樣裡有 3 條誤報，
共同形狀是「規則描述的問題在一般情況下成立，但這個 repo 的設定讓它不適用」：
React Compiler 全域開啟時要求手動 `useMemo`、兩種回應形狀並存時假設只有一種、
對已存在的 image tag 提出不存在的疑慮。誤報率 3/70，不高，但靠讀 diff 看不
出來，需要規則本身帶著「先確認這個前提在這個 repo 成立」的條件。

### 下一步

組織方式已經有答案：依缺陷形狀分類，不依主題分群。接下來兩件事沒有被這一輪
回答：分層注入（讓 rails 層的規則真的進到 Rails PR 的 prompt），以及怎麼讓
規則觸及「同檔完全沒講」那 22 條。後者需要的不是更多規則，是讓 reviewer 有
機會對照 codebase 既有慣例，而不是只讀 diff。
