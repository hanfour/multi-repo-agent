---
id: common-test-quality-unverified-invariant-assertion
layer: common
frameworks: ["*"]
severity_default: HIGH
---
## 觸發訊號
diff 新增或修改了下列任一種「斷言／窄化」寫法：`Debug.assert(...)`、`Debug.assertNever(...)`、`Debug.assertNode/assertEqual` 等內部斷言、非空斷言 `!`、型別斷言 `as X`，或是針對某個 `SyntaxKind`/enum/union 型別的 `switch` 窮舉判斷。凡是出現這類「宣告這個值只可能是某種形狀」的寫法，就要回頭確認：這個假設涵蓋的輸入來源（語法解析結果、AST 節點、使用者原始碼）是否真的窮盡了所有合法分支，尤其是同一個 PR 或最近的 PR 裡新加入的語法/情境（例如新的 JSDoc 形式、`satisfies`、import attributes、JSX fragment、可選參數等）是否也被涵蓋進去；並確認是否有對應的測試案例（fourslash test 或 baseline）覆蓋這個邊界情況，而不是只靠這條斷言本身當作正確性保證。

## 判準
斷言在執行期是直接丟例外或做不安全的型別轉型，一旦假設被打破，後果比「沒有斷言、跑出錯誤結果」更嚴重——會讓編譯器/工具直接 crash，或是在斷言被拿掉、換成型別轉型後，錯誤結果被靜默吞掉。這類程式碼的輸入來源是任意使用者原始碼，組合爆炸遠超過作者當下想到的案例，資深 reviewer 的經驗是這種「我假設這裡不會出現別的情況」幾乎必然會被某個沒人想到的語法組合打破（JSDoc 混寫、巢狀型別斷言、動態算出的 computed property 等），而且往往要等到使用者回報 bug 才被發現。因此看到斷言／窮舉判斷時，reviewer 該問的不是「這行寫得對不對」，而是「這個假設真的對所有輸入都成立嗎、有沒有測試證明」。

## 嚴重度
CRITICAL：斷言/型別窄化守護的是使用者可任意觸發的輸入路徑（parser、checker、declaration emit 等處理任意原始碼的程式碼），且該次改動明顯新增或牽動了一種新語法/新情境，卻沒有新增涵蓋該情境的測試，一旦假設不成立會直接讓工具對合法輸入 crash。
HIGH：斷言的假設在常見情境下成立，但存在可辨識、尚未驗證的邊界（例如新增 union/enum 成員後沒同步檢查所有 `assertNever` 分支、或斷言只在部分呼叫路徑成立），需要作者明確驗證或補測試才能放心。
MEDIUM：斷言影響範圍侷限在內部不變量、有安全 fallback（例如型別斷言失敗時退回 `any` 而非 throw），或問題本質只是測試可讀性/可維護性不足（如測試斷言方式難以理解，之後难以擴充），不會造成使用者可見的 crash。

## 反例（不該報）
- 斷言/窮舉判斷已經對應到一個真正窮盡且封閉的型別（例如已為所有 enum 成員各寫一個 `case`，型別系統本身能保證不會有遺漏分支），不該報。
- PR 已經包含涵蓋該邊界情況的新測試（fourslash test、baseline 或單元測試），且測試證實假設成立，不該報。
- 純粹把既有的裸型別斷言改寫成等價的、有執行期檢查的窄化寫法（行為不變、只是寫法更安全），不該報。
- 斷言守護的是編譯器內部產生、非使用者可控的節點（例如只在特定內部 pass 之後才會出現的合成節點），且呼叫路徑已受其他不變量保護，不該報。

## 出處
- https://github.com/microsoft/TypeScript/pull/61582#discussion_r2045603619
- https://github.com/microsoft/TypeScript/pull/60576#discussion_r1870086795
- https://github.com/microsoft/TypeScript/pull/56941#discussion_r1821706217
- https://github.com/microsoft/TypeScript/pull/59933#discussion_r1777695626
- https://github.com/microsoft/TypeScript/pull/59154#discussion_r1669012325
- https://github.com/microsoft/TypeScript/pull/58786#discussion_r1630119389
- https://github.com/microsoft/TypeScript/pull/56907#discussion_r1607934093
- https://github.com/microsoft/TypeScript/pull/58539#discussion_r1600745638
- https://github.com/microsoft/TypeScript/pull/58516#discussion_r1599009909
- https://github.com/microsoft/TypeScript/pull/55406#discussion_r1572779304
- https://github.com/microsoft/TypeScript/pull/58085#discussion_r1556245030
- https://github.com/microsoft/TypeScript/pull/58001#discussion_r1544929522
- https://github.com/microsoft/TypeScript/pull/57589#discussion_r1511868962
- https://github.com/microsoft/TypeScript/pull/57589#discussion_r1509483681
- https://github.com/microsoft/TypeScript/pull/57281#discussion_r1478888570
- https://github.com/microsoft/TypeScript/pull/57281#discussion_r1478646651
- https://github.com/microsoft/TypeScript/pull/57281#discussion_r1477864965
- https://github.com/microsoft/TypeScript/pull/56034#discussion_r1446507676
- https://github.com/microsoft/TypeScript/pull/56034#discussion_r1445511852
- https://github.com/microsoft/TypeScript/pull/56580#discussion_r1409736949
- https://github.com/microsoft/TypeScript/pull/56101#discussion_r1409345164
- https://github.com/microsoft/TypeScript/pull/56101#discussion_r1408538461
- https://github.com/microsoft/TypeScript/pull/56384#discussion_r1391856259
- https://github.com/microsoft/TypeScript/pull/56384#discussion_r1391845644
- https://github.com/microsoft/TypeScript/pull/56277#discussion_r1378074158
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1334741261
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1334700207
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1333630721
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1329330025
- https://github.com/microsoft/TypeScript/pull/54242#discussion_r1322177403
- https://github.com/microsoft/TypeScript/pull/55482#discussion_r1304811853
- https://github.com/microsoft/TypeScript/pull/55393#discussion_r1296510008
- https://github.com/microsoft/TypeScript/pull/54377#discussion_r1205838104
- https://github.com/microsoft/TypeScript/pull/54224#discussion_r1192878836
- https://github.com/microsoft/TypeScript/pull/54224#discussion_r1192877160
- https://github.com/microsoft/TypeScript/pull/53284#discussion_r1160423224
- https://github.com/microsoft/TypeScript/pull/53261#discussion_r1145257436
- https://github.com/microsoft/TypeScript/pull/53002#discussion_r1143925051
- https://github.com/microsoft/TypeScript/pull/52690#discussion_r1110208463
- https://github.com/microsoft/TypeScript/pull/52667#discussion_r1101905870
