#!/usr/bin/env bash
# canonical 規則檔的解析與驗證。兩條萃取路線的產出都要通過這裡，否則最後
# 比較的可能是格式差異而不是規則品質。
#
# 不用 YAML 解析器：frontmatter 只有四個純量欄位，用 awk 抓比拉一個相依
# 進來划算。frameworks 是陣列但只當字串傳遞，不需要解析內容。
#
# 驗證一次報所有問題，不是遇到第一個就 return：萃取階段一次產幾十個檔，
# 一次看到全部問題比修一個跑一次快得多。
#
# 依賴 lib/corpus-targets.sh 的 corpus_layers()（合法 layer 清單的唯一
# 來源，不在這裡重複寫死）。呼叫端（bin/mra.sh 透過 MRA_LIBS、或獨立腳本）
# 要負責先 source 它。

RULE_VALID_SEVERITIES="CRITICAL HIGH MEDIUM LOW"
RULE_REQUIRED_FIELDS="id layer frameworks severity_default"
RULE_REQUIRED_SECTIONS="觸發訊號 判準 嚴重度 反例 出處"
RULE_MIN_SOURCES=3

# rule_frontmatter <file> — 印出 frontmatter 的 YAML 部分（不含 --- 界線）。
# 退出碼非 0：開頭不是 ---，或是有開頭卻找不到收尾的 ---（後者原本完全不偵測——
# 缺收尾界線時會把整個檔案剩餘內容含所有章節本文都當成 frontmatter 印出、
# exit 0、不報錯，矇混過關純粹是因為章節內容剛好沒出現 key: value 形狀的
# 行；一旦踩到就是拿到錯的欄位值而不是報錯）。用 found 旗標讓 END 區塊
# 判斷有沒有真的看到收尾界線。
rule_frontmatter() {
  local f="$1"
  awk 'NR==1 && $0 != "---" { exit 1 }
       NR>1 && $0 == "---" { found=1; exit 0 }
       NR>1 { print }
       END { exit !found }' "$f"
}

# rule_field <file> <key> — 印出單一 frontmatter 欄位的值；缺欄位回空字串、
# 退出碼 1。用 sub() 砍掉 $0 裡「key: 」的前綴，而不是取 $2，這樣值本身
# 含冒號（例如未來可能出現的 URL 值）不會被截斷。
#
# 先把 rule_frontmatter 的輸出收進變數，再單獨用 <<< 餵給 awk，不要用
# `rule_frontmatter "$f" | awk ...` 這種管線寫法：這支 lib 實際執行的三個
# 環境（test.sh、tests/test_rule_schema.sh、scripts/rule-validate.sh）都開了
# set -o pipefail，管線的退出碼＝「最右邊那個曾經非 0 的指令」。frontmatter
# 缺收尾 --- 時 rule_frontmatter 會回傳 1（這是刻意的，見上面的說明），但它
# 仍然把（誤判範圍內的）內容印出來，右邊的 awk 拿這些內容照樣能找到欄位、
# 自己回傳 0——可是 pipefail 底下，awk 的 0 蓋不掉 rule_frontmatter 那個 1，
# 整條管線最後回報 1。實測過的症狀：對缺收尾 --- 的檔案呼叫
# `rule_field id`，印出的值是對的（值確實抓到了），退出碼卻是 1（宣稱找不
# 到）。連帶後果是 rule_validate 的必填欄位迴圈會把明明寫得好好的欄位，
# 全部誤報成 RULE_FIELD_MISSING，把萃取路線的 agent 導向錯的修復方向（去
# 補根本沒缺的欄位，而不是補收尾的 ---）。改成先賦值給變數（一個獨立的
# command substitution，rule_frontmatter 自己的退出碼在這裡就地被丟棄、
# 不會流進下一步)，再用 <<< 餵給 awk（純輸入重導向，不是管線，沒有
# pipefail 可以攪局的空間），awk 自己的退出碼就是 rule_field 最終回傳的
# 退出碼，不會被 rule_frontmatter 汙染。
rule_field() {
  local f="$1" key="$2"
  local frontmatter; frontmatter="$(rule_frontmatter "$f")"
  local val
  val="$(RULE_KEY="$key" awk -F': *' \
    '$1 == ENVIRON["RULE_KEY"] { sub(/^[^:]*: */, ""); print; found=1 } END { exit !found }' \
    <<< "$frontmatter")"
  local rc=$?
  printf '%s' "$val"
  return $rc
}

# rule_section <file> <章節標題> — 印出該 ## 章節的內容（不含標題行本身、
# 不含下一個 ## 章節）。
#
# 用「開頭符合」而不是「整行完全相等」比對標題：規則檔的章節標題常帶括號
# 註解（fixture 裡是「## 反例（不該報）」），呼叫端只會傳短名字
# 「反例」。整行相等會讓合格 fixture 本身被判定「反例」章節不存在。
#
# 但光是開頭符合不夠，還要錨定邊界：「## 判準」這個開頭符合也會匹配到
# 「## 判準補充」這種同前綴但其實是別的章節的標題，抓到的內容會是錯的
# 章節，而且因為抓到的內容非空，rule_validate 完全不會發現。標題後面接的
# 必須是空白、半形／全形括號、\r（CRLF 結尾的合法標題行），或行尾，才算數。
# 用 index()／substr() 逐一比對候選邊界字元而不是塞進 awk 的 [...] 字元
# 集合或動態組 regex：中日文全形
# 括號是多位元組 UTF-8 字元，塞進字元集合在非 UTF-8-aware 的 awk 上可能被
# 拆成單一位元組比對，出現無法預期的誤判；純字串比對不管 awk 認不認得
# UTF-8 都是逐位元組一致的比較，沒有這個風險。
rule_section() {
  local f="$1" title="$2"
  RULE_TITLE="## $title" awk '
    function boundary_ok(rest) {
      if (rest == "") return 1
      if (index(rest, " ") == 1) return 1
      if (index(rest, "\t") == 1) return 1
      if (index(rest, "\r") == 1) return 1
      if (index(rest, "(") == 1) return 1
      if (index(rest, ")") == 1) return 1
      if (index(rest, "（") == 1) return 1
      if (index(rest, "）") == 1) return 1
      return 0
    }
    !inside && index($0, ENVIRON["RULE_TITLE"]) == 1 {
      if (boundary_ok(substr($0, length(ENVIRON["RULE_TITLE"]) + 1))) { inside=1; next }
    }
    inside && /^## / { exit }
    inside { print }' "$f"
}

# rule_source_count <file> — 印出「出處」章節裡的 URL 數量。
#
# 用 grep -oE 印出每個相符的子字串（一個 URL 一行）再 wc -l，不是
# grep -cE（算相符的「行數」）：出處章節常見寫法是同一行塞兩個 URL
# （同一個 PR 的多則 review comment），grep -c 會把它算成 1 則，等於
# 誤殺樣本數其實足夠的規則——這道關卡的目的是擋樣本太少寫出來的幻覺規則，
# 不是照著行數算。
#
# `{ grep ... || true; }`：grep 在 0 筆匹配時退出碼是 1；pipefail 底下
# 「pipeline 的退出碼＝最右邊那個曾經非 0 的指令」，就算後面接的 wc -l
# 本身成功也蓋不掉 grep 那個 1。呼叫端（rule_validate、以及任何在
# set -e 環境下 source 這支 lib 的腳本）不該因為「數字剛好是 0」這個
# 合法結果就被打斷，所以只把 grep 這一段包起來吸收它的退出碼，不動
# rule_section 那一段——真正的錯誤（例如 rule_section 本身失敗）不應該
# 被這裡的 || true 一起吞掉。
rule_source_count() {
  rule_section "$1" 出處 | { grep -oE 'https?://[^[:space:]]+' || true; } | wc -l | tr -d ' '
}

# id_is_safe <id> — 兩條萃取管線（scripts/extract-rules-tfidf.sh、
# scripts/rule-repair.sh）都會把 agent 產出的 id（未經清洗的模型輸出）直接
# 拼進檔案路徑（如 <out>/<id>.md）。一個帶 `/` 或 `..` 的 id 會讓後面的 mv
# 寫到目的地目錄以外的路徑，且不會有任何錯誤訊號——這是路徑穿越。只放行
# 英數字、連字號、底線；這也剛好是 scripts/rule-agent.sh 的 prompt 本身要求
# agent 產出的格式（「<層>-<用連字號的簡短英文描述>」）。
#
# 兩支呼叫端共用同一份判斷，不要各寫一份會漂移的複本：這裡是規則檔相關
# 函式唯一的家（lib/rule-schema.sh 的檔頭已經這樣定位自己）。
#
# `*[!A-Za-z0-9_-]*` 這個 case pattern 是逐位元組比對整個字串，不是檔名
# glob——含換行字元的 id（例如某些模型輸出把值截斷到下一行）一樣會被
# `*` 涵蓋到，落在被拒絕的一邊，不需要額外處理 \n。
id_is_safe() {
  case "$1" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# rule_validate <file> — 合格回 0；不合格印出每個問題到 stderr 並回 1。
# 一次收集所有問題再回報，不遇到第一個就 return——萃取階段一次會產幾十個
# 規則檔，一次看到全部問題比修一個跑一次快得多。
rule_validate() {
  local f="$1" problems=0
  [ -f "$f" ] || { printf 'RULE_FILE_MISSING\t%s\n' "$f" >&2; return 1; }

  local base; base="$(basename "$f" .md)"

  # frontmatter 沒有收尾 --- 要用自己的 token 報，不能只讓後面欄位查詢
  # 悄悄拿到從章節本文裡撈出來的錯誤值。下面的檢查照樣繼續跑（一次報所有
  # 問題），但至少「frontmatter 本身沒收尾」這件事會被看見。
  if ! rule_frontmatter "$f" >/dev/null; then
    printf 'RULE_FRONTMATTER_UNTERMINATED\t%s\t找不到收尾的 ---\n' "$f" >&2
    problems=$((problems + 1))
  fi

  # 欄位「有 key 但值是空字串」（例如 `id:`）要當成缺欄位，不能因為
  # rule_field 判定「找到了」（rc=0）就放過——空值不只該在這裡被攔下來，
  # 還要連帶跳過下面 id／layer／severity_default 各自的合法性檢查（那些
  # 檢查都用 [ -n "$x" ] 守門，空值本來就不會進去），避免對同一個根因重複
  # 報出語意錯亂的第二個問題。
  local key
  for key in $RULE_REQUIRED_FIELDS; do
    local field_val; field_val="$(rule_field "$f" "$key")"
    local field_rc=$?
    if [ "$field_rc" -ne 0 ] || [ -z "$field_val" ]; then
      printf 'RULE_FIELD_MISSING\t%s\t%s\n' "$f" "$key" >&2
      problems=$((problems + 1))
    fi
  done

  local id; id="$(rule_field "$f" id)"
  if [ -n "$id" ] && [ "$id" != "$base" ]; then
    printf 'RULE_ID_MISMATCH\t%s\tid=%s 但檔名是 %s，兩者必須一致\n' "$f" "$id" "$base" >&2
    problems=$((problems + 1))
  fi

  # 清單一律先收進變數再用 here-string 餵給 grep，不寫成 `producer | grep -q`。
  # `grep -q` 配到就立刻退出，producer 還沒寫完就吃到 SIGPIPE 回 141，呼叫端
  # 開著 pipefail 時整條管線被判成失敗，`!` 再反轉成「不合法」。實測 2026-08-22
  # 那一輪回測就是這樣掛的：81 個 layer=common 的規則檔隨機中了 2 個，訊息
  # 印出來還自相矛盾（「common 不在合法清單：common nestjs rails react vue」）。
  # 只打到 common 是因為它是清單第一行，grep 最早退出、競態視窗最大。
  local layer valid_layers
  layer="$(rule_field "$f" layer)"
  valid_layers="$(corpus_layers)"
  if [ -n "$layer" ] && ! grep -qxF "$layer" <<<"$valid_layers"; then
    printf 'RULE_LAYER_INVALID\t%s\t%s 不在合法清單：%s\n' \
      "$f" "$layer" "$(corpus_layers | paste -sd ' ' -)" >&2
    problems=$((problems + 1))
  fi

  local sev valid_sevs
  sev="$(rule_field "$f" severity_default)"
  valid_sevs="$(printf '%s\n' $RULE_VALID_SEVERITIES)"
  if [ -n "$sev" ] && ! grep -qxF "$sev" <<<"$valid_sevs"; then
    printf 'RULE_SEVERITY_INVALID\t%s\t%s 不在合法清單：%s\n' \
      "$f" "$sev" "$RULE_VALID_SEVERITIES" >&2
    problems=$((problems + 1))
  fi

  local section
  for section in $RULE_REQUIRED_SECTIONS; do
    if [ -z "$(rule_section "$f" "$section" | tr -d '[:space:]')" ]; then
      printf 'RULE_SECTION_MISSING\t%s\t%s\n' "$f" "$section" >&2
      problems=$((problems + 1))
    fi
  done

  local n; n="$(rule_source_count "$f")"
  if [ "$n" -lt "$RULE_MIN_SOURCES" ]; then
    printf 'RULE_SOURCES_TOO_FEW\t%s\t出處只有 %s 則，至少要 %s 則\n' \
      "$f" "$n" "$RULE_MIN_SOURCES" >&2
    problems=$((problems + 1))
  fi

  [ "$problems" -eq 0 ]
}
