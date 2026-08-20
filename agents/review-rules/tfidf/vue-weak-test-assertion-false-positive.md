---
id: vue-weak-test-assertion-false-positive
layer: vue
frameworks: ["vue@2.x - 3.x"]
severity_default: MEDIUM

---
## 觸發訊號
diff 新增或修改的測試,斷言方式無法真正區分「修好之後」跟「修好之前」的行為差異。具體樣態:
- 用 `toContain`/`toMatch` 檢查輸出裡的一小段文字/子集,而不是用 `toBe`/`toEqual`/`toMatchInlineSnapshot` 比對完整、精確的輸出,導致即使核心邏輯沒修對,測試仍會巧合通過
- 斷言依賴的欄位/文字剛好會透過另一條路徑(例如 attribute fallthrough、DOM 上殘留的舊值)產生一樣的結果,使測試跟被測的那行程式碼實際上沒有因果關係(例:template 用 `:data-foo="dataFoo"`,但 `data-foo="foo"` attr 本身就會落到同一個位置,`dataFoo` 傳值邏輯錯了測試也不會發現)
- 只斷言 spy 被呼叫過 (`toHaveBeenCalled()`),沒有斷言呼叫參數/次數,排除不了「呼叫了但值是錯的」
- 新增的 regression test(通常標註 `// #xxxx` issue 編號)在把這次修正 revert 掉之後,理論上仍然會綠燈
- 針對「這是不是 false positive」的往返討論(reviewer 質疑某個 case 沒被涵蓋,作者用另一個真實 compiled/hydration 場景驗證後才確認測試有效或補上新斷言)

## 判準
資深 reviewer 看到新測試的第一個直覺是「把這次的修正 revert 掉,這個測試還會不會過?」如果答案是「還是會過」,這個測試就沒有真正 pin 住那個 bug,只是製造了「已經有覆蓋」的錯覺。這比完全沒寫測試更危險,因為之後有人不小心把同一段邏輯改壞,不會被任何東西擋下來,而 CI 綠燈會讓人誤以為安全。尤其在 Vue 這種涉及 diff/patch/hydration/fallback 這類「多條路徑會巧合產生相同 DOM 結果」的引擎程式碼裡,弱斷言特別容易誤導。

## 嚴重度
CRITICAL:測試是這次 PR 對新行為/regression 的唯一驗證手段,且斷言方式在把修正 revert 掉後仍會通過 — 等同於完全沒有測試保護,卻掛著看似完整的測試案例
HIGH:斷言只覆蓋輸出的一部分或依賴巧合路徑(如 attribute fallthrough、共用的 DOM 殘留值)產生「看似正確」的結果,遺漏了此次修正真正要保證的關鍵差異點
MEDIUM:斷言可以更嚴謹(例如把 `toMatch`/`toContain` 換成 `toBe`/`toMatchInlineSnapshot`,或替 spy 補上呼叫參數斷言),但目前寫法在絕大多數情境下仍能抓到主要的行為錯誤

## 反例(不該報)
- 刻意使用 `toContain`/`toMatch`,因為預期輸出本來就會夾雜其他元件、動態 id 或不受本次修正影響的內容,嚴格全等比對反而會讓測試對無關變動過度敏感而變脆弱
- 已經是 `toMatchInlineSnapshot`/`toStrictEqual` 這類完整輸出比對的測試,不在此規則範圍內
- e2e / 動畫 timing 相關測試因平台差異刻意採用較寬鬆的等待與比對(如 `transitionFinish`、`nextFrame` 搭配的斷言),這是已知的 trade-off,不是疏忽
- reviewer 提出的假設情境經作者用真實 compiled/hydration 案例驗證後證實不會發生(false positive 被排除),此時原本的測試不需要因此加強

## 出處
- https://github.com/vuejs/vue/pull/11857#discussion_r553264692
- https://github.com/vuejs/vue/pull/9484#discussion_r301477519
- https://github.com/vuejs/vue/pull/9653#discussion_r263774148
- https://github.com/vuejs/vue/pull/11943#discussion_r591524130
- https://github.com/vuejs/core/pull/15262#discussion_r3754809356
- https://github.com/vuejs/core/pull/14899#discussion_r3332852500
- https://github.com/vuejs/core/pull/12601#discussion_r3567818962
- https://github.com/vuejs/core/pull/15216#discussion_r3734718590
