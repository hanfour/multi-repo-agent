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

規則注入量以 token 預算控制，不是條數上限。實際注入後 4 個 persona 各增加
65 行（tfidf）或 85 行（taxonomy），檔案大小 18.3 到 18.6 KB 與 20.5 到 20.8 KB。

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
`:115`。兩輪都產出了 `:124` 的 CRITICAL，內容正是這個缺陷。但配對挑走了更近的
`:117`（距離 2，講陣列拼接的風格）與 `:119`（距離 4，講寬度值寫死兩處），真正
抓對的 `:124`（距離 9）被算成未對應。

這個 PR 在兩輪都記為命中 1/1，命中的卻是一條講樣式的 MEDIUM。

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

## 規則注入的部署成本

同樣的 `MRA_REVIEW_PERSONA_MAX_TURNS=20` 與 synthesize 8 輪之下：

| 路線 | 成功筆數 | 失敗 |
| --- | --- | --- |
| personas 基準線 | 38/38 | 0 |
| rules-tfidf | 36/38 | 2 |

兩次失敗在發生當下讀 `.err`，訊息都是 synthesize 的 `Reached max turns (8)`。
沒有調高 synthesize 輪數，因為基準線就是跑在 8 輪下的，調高會讓帶規則那輪跑在
比基準線寬鬆的條件下，那個差異會被誤讀成規則的效果。

這兩筆的 `.err` 事後被覆寫了，現在留下的是 OAuth 過期的訊息。原因是回測腳本
尾端的容差重算會再跑一次同一個 label，過程中重跑失敗的 PR 並覆寫 `.err`，而
那時認證已經過期。所以「兩次都是 max turns」這句話的證據只剩當下的讀數，不能
再從檔案驗證。

即使如此，這一節的結論不受影響：基準線在同樣條件下是 38/38 零失敗，帶規則那輪
在同一批 PR 上少了 2 筆。規則注入的成本不只是 prompt token，還包括 synthesize
可用的輪數被壓縮。實際部署時要一併計算。

（回測腳本的容差重算會重跑失敗的 PR 並覆寫診斷檔案，這是它自己的缺陷，已記在
待辦裡。）

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

兩張表都限制在同一批 36 個共同 PR、51 條 expected，否則母體不同不能互比。

taxonomy 相對基準線：

| 轉移 | 條數 |
| --- | --- |
| 6-15 → ≤5 | 3 |
| 無 → ≤5 | 1 |
| ≤5 → ≤5 | 8 |
| ≤5 → 更遠的區間 | 0 |

±5 命中從 8 條增為 12 條，全部是進帳，沒有一條原本錨在 5 行內的被推走。
三條是原本落在 6 到 15 行的被拉進 5 行內，一條是原本同檔完全沒講的新抓到。

tfidf 相對基準線：

| 轉移 | 條數 |
| --- | --- |
| ≤5 → >15 | 2 |
| ≤5 → 6-15 | 1 |
| 6-15 → ≤5 | 1 |
| 6-15 → >15 | 4 |
| ≤5 → ≤5 | 5 |

±5 命中從 8 條減為 6 條。三條原本錨在 5 行內的被推出去，只換回一條。

兩條路線的同檔有講幾乎沒變（tfidf 29 對 29、taxonomy 29 對 28），產出量也
接近（194、184 對基準線 205）。也就是說，兩條路線都沒有改變 reviewer 看哪些
檔案、講多少話，差別只在錨點往哪邊移動：taxonomy 往內收，tfidf 往外散。

## 未對應的 comment 是什麼

taxonomy 那輪 ±15 之下有 177 條未對應 comment。依階段二寫定的規則抽樣 70 條
（CRITICAL 全取 12、HIGH 每 2 取 1 共 33、MEDIUM 每 4 取 1 共 25）判讀。

12 條 CRITICAL 全部是真缺陷，沒有一條是誤報。內容都很具體，多數帶著可驗證的
依據：`pre_campaign/sequence.rb:79` 指出 `MoatSegment.find` 對一個定義為陣列
`[45]` 的常數呼叫會拋 NoMethodError；`list.ts:42` 指出新增的必填欄位 `canEdit`
在對應端點的實際回應裡不存在；`creatives.e2e-spec.ts:1533` 引用 backend
AGENTS.md「每個靜態子路徑都要有 e2e 覆蓋」的規定指出新路由沒有 e2e。

這與階段二基準線的判讀一致：未對應率不是誤報率。基準集只收「後來被修過」的
缺陷，一條 comment 沒對應到 expected，多數時候表示那個問題當時沒人修，不是
它不存在。

## 結論

依 finding 分類萃取的 37 條規則優於依 TF-IDF 分群萃取的 140 條。±5 漏抓率
0.76 對 0.88，差 6 條 finding，約 12 個百分點，遠高於「2 條才算數」的門檻。

taxonomy 相對於無規則的基準線也有改善，±5 少漏 4 條約 7.8 個百分點，且那 4
條是純進帳。tfidf 相對基準線則是退步，±5 多漏 2 條、±15 多漏 4 條。

三個限制要一併記住。

第一，兩條路線都沒有改變 reviewer 看到哪些檔案。同檔完全沒講在四條路線上是
22、22、23，只有 standard+codex 是 38（因為它只產出 29 條 comment）。規則改變
的是既有注意力的落點，不是注意力的範圍。階段二分類指出的最大缺口是「reviewer
在那個檔案裡一句話都沒說」，佔 85%，這一輪的規則沒有動到它。

第二，改善的絕對量小。taxonomy 的 ±5 漏抓率仍有 0.76，51 條 expected 裡漏掉
39 條。以「拿去當團隊 code review skill」的標準看，這個數字還不能用。

第三，規則注入有部署成本。tfidf 那輪 36/38，兩次失敗在發生當下讀到的是
synthesize 輪數用盡；taxonomy 那輪 38/38 零失敗，注入量也小得多（37 條對 140
條、85 行對 65 行的差異來自 token 預算而非條數）。條數少反而更穩。

### 下一步

規則的組織方式已經有答案：依缺陷形狀分類，不依主題分群。剩下的問題是怎麼讓
規則觸及「同檔完全沒講」那 22 條，那需要的不是更多規則，是讓 reviewer 有機會
對照 codebase 既有慣例，而不是只讀 diff。
