---
id: common-unrelated-mechanical-changes-mixed-in-diff
layer: common
frameworks: ["*"]
severity_default: LOW
---
## 觸發訊號
diff 中出現與本次功能/修復邏輯無直接關係的機械式改動，且沒有拆成獨立 commit，包括：純格式重排（換行、縮排、參數換行方式調整但語意不變）、跨多處的機械式 find&replace（例如批次重新命名符號/測試名稱）、或新增缺乏說明的 TODO/workaround 注解（例如 `// TODO Document why this is necessary`）。

## 判準
格式重排與機械式重命名會把真正需要仔細審查的行為變更淹沒在大量無意義的 diff 雜訊裡，reviewer 難以判斷哪幾行是關鍵改動；這類變更應該獨立成一個 commit（甚至用專門的 rename/format 工具產生）以便 review 能聚焦在邏輯變更上。缺乏說明的 workaround 注解則會讓後續維護者不知道這段程式碼是否還有必要、能不能安全移除，形成技術債的隱形陷阱。

## 嚴重度
CRITICAL：（幾乎不適用，本類問題不直接造成功能錯誤）
HIGH：大範圍格式重排或機械式重命名與正確性關鍵的邏輯改動混在同一個 commit，導致該邏輯改動在 review 中被淹沒、容易被漏審。
MEDIUM：格式化變更或機械式重命名雖與功能改動混在一起，但範圍有限、容易辨識；或新增的 workaround/hack 沒有註解說明其存在原因，未來難以判斷是否可移除。

## 反例（不該報）
- 該 PR/commit 本身就是以格式化或重命名為目的的獨立變更（如 "chore: run prettier"、"refactor: rename X to Y"），這是預期用途，不該報。
- 格式變更是由自動化工具（linter/formatter pre-commit hook）產生，且已與其餘邏輯變更分成不同 commit。
- TODO 或 workaround 注解已附上清楚的原因說明或連結對應 issue/PR。

## 出處
- https://github.com/nestjs/swagger/pull/412#discussion_r356826800
- https://github.com/prisma/prisma/pull/8034#discussion_r664851161
- https://github.com/prisma/prisma/pull/4235#discussion_r522017056
