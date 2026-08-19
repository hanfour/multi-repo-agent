# 基準線 A 的 finding 分類

資料來源：`baseline-standard` 這一輪，38 個 PR，容差 ±5。
reviewer 產出 30 條 comment（6 條對上 expected finding、24 條未對應），
53 條 expected finding 中 47 條漏抓。

分類的用途是給階段三的規則對照：規則要補的是 reviewer 現在不會做的那種推理，
不是它已經做得好的那種。

## 一句話結論

**reviewer 擅長「這行做了 X，X 是錯的」，不擅長「這裡還應該做 Y」。**

47 條漏抓裡有 24 條（51%）屬於後者：缺席、狀態沒考慮到、狀態範圍錯。
30 條產出裡幾乎每一條都是前者，而且都附了可到達路徑。

## 漏抓的 47 條，依所需推理分類

| 類別 | 條數 | 這一類要做的推理 |
| --- | --- | --- |
| 缺席：應該有而沒有 | 10 | 對照 codebase 既有慣例，發現這裡少了一道 |
| 狀態範圍：共用了不該共用的狀態 | 8 | 追一份狀態被誰讀寫，發現沒有依 key 區隔 |
| 框架語意 | 7 | 知道函式庫／語言在這個情況下的實際行為 |
| 狀態遺漏：三態當兩態 | 6 | 列舉所有可能狀態，發現只處理了兩種 |
| 測試品質 | 5 | 判斷測試會不會因為實作壞掉而失敗 |
| 快取一致性 | 4 | 追同一份資料被幾個 query key 快取 |
| 錯誤守衛：有檢查但條件錯 | 3 | 問「這個檢查什麼時候不會執行」 |
| 領域與邏輯 | 4 | 知道這個領域的實務限制 |

### 缺席（10 條）

- 設定頁 route 沒有 `beforeLoad` 權限檢查、操作沒有 `Can` 包裹（×2，CRITICAL）
- `STUDIO_URL: z.url()` 沒有限制 scheme（CRITICAL）
- 導頁前沒有驗證 packId 是否屬於該廣告主（CRITICAL）
- 下載按鈕沒有檢查是否已選公司
- 啟用切換的 switch 在 mutation 進行中沒有停用
- sonar-scan 步驟沒有 `when.event` 限制
- 退回按鈕用資料筆數而非權限決定顯示
- 新增的 API 呼叫沒有帶 `reqSchema`
- 選項查詢沒有標記 `skipGlobalError`

共同形狀：**diff 裡沒有任何一行是錯的**。錯的是少了一行，而「少了什麼」只有對照
codebase 其他地方的作法才看得出來。reviewer 的注意力放在 diff 內的每一行，
這一類天生落在它的視野外。

六個 CRITICAL 有五個在這一類。

### 狀態範圍（8 條）

全部是同一個缺陷跨 8 個 PR：`useLineItemDetailDraft()` 沒帶 `lineItem.id`，
草稿不分明細共用同一份。

這一條沒有在任何一個 PR 被抓到。它的困難處在於那行程式碼**看起來完全正常** ——
一個 hook 呼叫沒帶參數，要追到 store 的實作、確認它沒有依 key 區隔，才知道有問題。

（這一類佔 47 條的 17%，是單一缺陷跨多 PR 造成的權重偏斜，解讀時要記得。）

### 狀態遺漏（6 條）

- `isPending` 直接回 `undefined`，把「查詢中」當成「未設定」（×2）
- `useQuery` 只取 `isError` 沒取 `error`，所有失敗被當成同一種
- 只判斷 `isSubsidiariesLoading`，沒判斷 `isSubsidiariesError`（×3）

共同形狀：資料有三種狀態（載入中／失敗／完成），程式只處理了兩種。
第三種被合併進其中一種，產生錯誤的畫面或誤導的訊息。

### 框架語意（7 條）

- `version.object_changes` 是序列化字串，直接當 Hash 取值
- `ENV['id'].to_i` 得到 0，而 Rails 的 `0.present?` 是 true
- 丟棄草稿綁在元件卸載，StrictMode 與 Fast Refresh 下會多卸載（×3）
- `form.handleSubmit()` 在單一欄位失敗時早退，form-level 驗證不執行
- 導頁時直接指定 state 物件會覆寫既有的 history state

共同形狀：要知道那個函式庫或語言在這個特定情況下的實際行為。
`0.present?` 為 true、StrictMode 會多跑一輪 mount／unmount、`handleSubmit` 會早退 ——
這些不看文件或沒踩過就不會知道。

## 產出的 30 條，形狀高度一致

幾乎每一條都是同一個模式：

> 這是本 PR 新增的 X 流程 → 使用者可以走 A → B → C 這條路徑 →
> 這一行做了 D → 導致 E

具體例子：

- `.join` 沒給分隔字串，產出 `<tablewidth="100%"style=...`
- `MoatSegment.find(常數)` 回傳陣列，對陣列呼叫 `ias_segment_code` 會 NoMethodError
- `compress_image` 失敗時 rescue 回傳原始 bytes，這裡仍固定輸出 `data:image/jpeg`
- `next if total_event` 在 Ruby 把 0 當成 truthy，下面的分支永遠跑不到
- 惡意 DOCX 可放 `javascript:` scheme，預覽者點擊後在本站 origin 執行

24 條未對應的裡面，**幾乎全部是真缺陷**，只是基準集沒收（沒有對應的修復 commit，
或是我判讀時漏判）。這表示 `unmatched_rate` 不含多少誤報成分。

## 對階段三規則的意涵

**規則要補的是「應該有而沒有」的檢查，不是「這行寫錯了」的檢查。** 後者 reviewer
已經做得不錯，前者是它的系統性盲區，而且六個 CRITICAL 有五個在那裡。

具體來說，規則的形式應該是「這種變更出現時，去確認 codebase 的既有慣例有沒有被
沿用」，而不是「注意某某寫法」。例如：

- 新增 route → 其他 route 有沒有 `beforeLoad`？
- 新增 API 呼叫 → 同檔其他呼叫有沒有帶 `reqSchema`？
- 新增 mutation → 這份資料還被哪些 query key 快取？
- 新增 env 變數 → 這個值最後會流到哪裡？
- 讀取非同步資料 → 載入中、失敗、完成三種狀態都處理了嗎？

這五條的共同點是**要求 reviewer 去看 diff 以外的東西**，那正是它現在不會主動做的事。

另外一項：規則必須要求留言帶上能對照 diff 的證據。實測有一條正確的 finding 被
反駁環節以「無法對照 diff 佐證」刪掉（`refutation dropped 1 of 1 finding(s)`）。
抓到了但論證不足，對使用者來說跟沒抓到一樣。
