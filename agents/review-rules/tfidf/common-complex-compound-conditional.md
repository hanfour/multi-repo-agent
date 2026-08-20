---
id: common-complex-compound-conditional
layer: common
frameworks: ["*"]
severity_default: MEDIUM
---
## 觸發訊號
diff 中新增或修改了一個橫跨多個函式呼叫、以 `||`／`&&` 串接的複合布林條件式（例如 `if (!(fnA(...) || fnB(...) || fnC(...)))`，或在既有條件式上再疊加一層 `&&`/`||` 分支），且整條判斷式塞在同一行、沒有拆成具名的中間變數或個別檢查。連動訊號：條件式牽涉到剛被 rename 的識別字，但相鄰的錯誤訊息／assert 文字／註解仍沿用舊名稱，兩者語意對不上。

## 判準
單行塞多個函式呼叫的複合條件，reviewer 必須在腦中同時展開好幾層布林邏輯與函式副作用才能判斷這行對不對，等於把驗證正確性的成本轉嫁給每一個後來的讀者／reviewer。這類條件式常見於逐次疊加分支（今天加一個 `allowNonTsExtensions` 特例、明天再加一個）而沒有回頭重構，久了會累積成連原作者都要用「大概還是對的，我不確定」來回應的狀態——這代表可讀性已經差到連正確性都無法自信斷言。rename 後遺留舊名稱的訊息文字是同一類問題的變形：條件邏輯或識別字變了，但描述它的文字沒跟著變，導致訊息本身變成誤導。

## 嚴重度
CRITICAL：（此規則的模式本身不直接導致資料損毀或安全漏洞，一般不會落到此級）
HIGH：複合條件式的語意在 rename／新增分支後已經與其配套的錯誤訊息、assert 訊息或註解矛盾，會誤導除錯或掩蓋真正的判斷邏輯。
MEDIUM：新增或修改的複合布林條件式塞在單行、缺乏拆解，reviewer 需要主動要求作者拆成個別檢查或分行才能確認正確性；或條件式改動未附上足以說明「為何要這樣判斷」的理由（尤其是新增特例分支時）。

## 反例（不該報）
- 條件式雖有多個子句，但每個子句都拆成獨立變數或個別 `if`／`switch case`，一眼可讀完整邏輯——不該報。
- 兩到三個子句、語意單一明確（例如單純的 null 檢查 `a || b`），沒有巢狀函式呼叫或混合 `&&`/`||` 優先權疑慮——不該報。
- Rename 後所有引用它的訊息、註解、變數名都已同步更新，找不到殘留的舊名稱——不該報。
- 純粹是作者在 review thread 中解釋設計動機（例如「這是為了之後 profiling 用」），沒有伴隨可讀性或語意不一致的程式碼問題——不該報。

## 出處
- https://github.com/microsoft/TypeScript/pull/41374#discussion_r520742674
- https://github.com/microsoft/TypeScript/pull/41374#discussion_r516378121
- https://github.com/microsoft/TypeScript/pull/41180#discussion_r509486850
- https://github.com/microsoft/TypeScript/pull/12250#discussion_r88266151
- https://github.com/microsoft/TypeScript/pull/1594#discussion_r22481128
