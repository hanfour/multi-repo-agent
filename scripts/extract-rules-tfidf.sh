#!/usr/bin/env bash
# A 路線：每個主題群交給 agent 產出一條 canonical 規則。
#
# 出處不足三則的群在「呼叫 agent 之前」就丟棄，不是產出後才驗：那些群註定
# 寫不出合格規則，先丟可以省掉幾十次模型呼叫。spec 的原話是「樣本太少寫出來
# 的規則是幻覺」。
#
# agent 產出一律先過 rule_validate 才落地。不合格的印出 RULE_REJECTED 與
# 完整的驗證訊息，並把原始產出留在 <out>/_rejected/<tag>-<cluster>.md 供
# 診斷——直接丟掉的話沒辦法判斷是 prompt 的問題還是模型的問題。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

CLUSTERS=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    # 每個需要值的旗標都先驗 arity。少了這道，`--clusters` 後面沒接東西會踩到
    # set -u，訊息是「$2: 未綁定的變數」，跟使用者打錯的東西完全對不上。這支
    # 腳本跑一次要幾小時、燒掉大量 API 額度，開場就給一句看不懂的話最糟。
    --clusters)
      [ $# -ge 2 ] || { echo "用法：--clusters 需要接一個檔案" >&2; exit 1; }
      CLUSTERS="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || { echo "用法：--out 需要接一個目錄" >&2; exit 1; }
      OUT="$2"; shift 2 ;;
    *) echo "用法：extract-rules-tfidf.sh --clusters <檔> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -s "$CLUSTERS" ] || { echo "CLUSTERS_MISSING：${CLUSTERS}" >&2; exit 1; }
# --out 整個沒給時 OUT 是空字串，mkdir 的訊息會是「mkdir: : No such file or
# directory」，同樣跟輸入無關。
[ -n "$OUT" ] || { echo "OUT_MISSING：需要 --out <目錄>" >&2; exit 1; }
mkdir -p "$OUT" "$OUT/_rejected" || exit 1

CLUSTERS_TAG="$(basename "$CLUSTERS" .jsonl)"

# Step 6 對五層各呼叫一次這支腳本，全部寫進同一個 --out 目錄，下面三份紀錄
# 的形狀都是照那個實際用法設計的：
#
#   - _dropped.tsv 每一列帶著來源檔案的 tag，讀的人才分得出哪一列是哪一層的。
#   - _agent_failed.tsv 跟 _dropped.tsv 分開。後者的語意是「這個群的資料本身
#     不夠格」，前者是「這個群本來夠格，但呼叫失敗了」，讀記錄的人需要分得出
#     這兩種。
#   - _rejected/<cluster>.md 這個檔名如果只用裸的 cluster id，兩層的 cluster 0
#     會互相覆蓋掉對方的診斷檔（cluster id 在每個 clusters.jsonl 裡都是從 0
#     重新編號的，不是全域唯一）。用來源檔案的 basename 當前綴消掉碰撞。
#
# 重跑語意選的是「以來源 tag 為單位，最後一次跑覆蓋前一次」：開跑前先把屬於
# 這個 tag 的舊列刪掉，別的 tag 的列原封不動，之後照常 append。
#
# 為什麼不是無條件 append（原本的作法）：同一層重跑第二次會把同一批列再寫一
# 遍，實測 6 列變 12 列，而同一個目錄裡的 _rejected/<tag>-<cid>.md 走的卻是
# 覆蓋，一個目錄裡並存兩種相反的語意。列數一旦變成「跑過幾次」的函數，「這
# 一層丟棄了幾群」就沒有唯一答案了。
#
# 為什麼不是無條件截斷（`: > file`）：那會讓五層跑完只剩最後一層的紀錄，前
# 四層的清單被悄悄蓋掉，而那正是這兩份檔案當初存在的理由。
#
# 選定之後的不變式：--out 目錄的內容永遠等於「每個 tag 各跑一次、且取最新
# 那次」的結果，跟實際重跑了幾次無關。這與 _rejected/ 既有的覆蓋行為同一套
# 語意，兩者不再互相矛盾。

# purge_tag_rows <檔案> <tag 所在欄位> <tag> — 刪掉屬於這個 tag 的舊列，其他
# tag 的列原封不動。檔案還不存在時建一個空的。
#
# 這是「讀出來、過濾、寫回去」，不是原子操作，前提是 Step 6 那個驅動迴圈一次
# 只跑一層（目前確實是循序的 for 迴圈）。要把五層改成平行跑的話，這裡跟下面
# 兩個 append 點都得先加互斥，否則一個行程的 mv 會蓋掉另一個行程剛寫進去的列。
#
# 欄位序號當參數傳而不是寫死 1，是因為 B 路線
# （scripts/extract-rules-taxonomy.sh）兩份紀錄的 tag 分別落在第 3 欄與第 1
# 欄。兩支腳本各留一份一模一樣的複本：這段邏輯屬於 scripts/ 這一層的重跑
# 語意，而 lib/ 是兩條管線共用的介面層，為了七行程式碼在共用層開一個新函式
# 的代價比複製高。
purge_tag_rows() {
  local file="$1" field="$2" tag="$3" tmpf
  if [ ! -f "$file" ]; then
    : > "$file" || { echo "LOG_INIT_FAILED：${file}" >&2; return 1; }
    return 0
  fi
  tmpf="$(mktemp "${TMPDIR:-/tmp}/rule-log.XXXXXX")" || return 1
  # 用 ENVIRON 傳值，不用 awk -v：-v 會先處理反斜線跳脫，而 tag 來自檔名，
  # 帶反斜線時會被改寫成另一個字串、比對不到。這跟 scripts/rule-repair.sh
  # 與 lib/corpus-targets.sh 的既有慣例一致。
  if ! MRA_TAG="$tag" MRA_FIELD="$field" awk -F'\t' \
      '$(ENVIRON["MRA_FIELD"]) != ENVIRON["MRA_TAG"]' "$file" > "$tmpf"; then
    rm -f "$tmpf"; echo "LOG_PURGE_FAILED：${file}" >&2; return 1
  fi
  mv "$tmpf" "$file" || { rm -f "$tmpf"; echo "LOG_PURGE_FAILED：${file}" >&2; return 1; }
}

purge_tag_rows "$OUT/_dropped.tsv" 1 "$CLUSTERS_TAG" || exit 1
purge_tag_rows "$OUT/_agent_failed.tsv" 1 "$CLUSTERS_TAG" || exit 1

AGENT="${MRA_RULE_AGENT_CMD:-}"
[ -n "$AGENT" ] || { echo "MRA_RULE_AGENT_CMD 未設定" >&2; exit 1; }

# 產出的 id 會直接拼進檔案路徑（$OUT/<id>.md）。這個 id 來自 agent（外部、
# 不可信）的原始輸出，不能直接信任——一個帶 `/` 或 `..` 的 id 會讓後面的 mv
# 寫到 $OUT 以外的路徑。id_is_safe() 定義在 lib/rule-schema.sh：
# scripts/rule-repair.sh 對同一個 id 有一模一樣的信任邊界（修復後重讀
# frontmatter 拿到的 id 一樣是模型輸出），兩邊共用同一份判斷，不要各寫一份
# 會漂移的複本。

# 把還留在暫存檔（尚未 mv 到 $OUT/<id>.md）的不合格產出留底到
# _rejected/，再清掉暫存檔並計數。給「id 缺欄位」「id 含不安全字元」
# 「id 撞名」三種在寫入正式位置之前就被攔下的情況共用。
reject_from_tmp() {
  local reason="$1"
  cp "$tmp" "$OUT/_rejected/${CLUSTERS_TAG}-${cid}.md" \
    || echo "REJECT_COPY_FAILED：${OUT}/_rejected/${CLUSTERS_TAG}-${cid}.md" >&2
  printf 'RULE_REJECTED\tcluster=%s(%s)\t%s，原始輸出留在 _rejected/%s-%s.md\n' \
    "$cid" "$CLUSTERS_TAG" "$reason" "$CLUSTERS_TAG" "$cid" >&2
  rm -f "$tmp"
  rejected=$((rejected + 1))
}

# log_agent_failed <最後一欄的說明> — 把一筆 agent 呼叫失敗記進
# _agent_failed.tsv。欄位形狀跟 _dropped.tsv 對齊（tag、cluster id、n、
# top_terms），最後一欄換成失敗的說明。給「非 0 退出」與「退出 0 但空輸出」
# 兩種呼叫失敗共用：兩者都是「這個群本來夠格，但這次呼叫沒拿到東西」。
log_agent_failed() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$CLUSTERS_TAG" "$cid" "$n" "$terms" "$1" \
    >> "$OUT/_agent_failed.tsv" \
    || { echo "AGENT_FAILED_LOG_WRITE_FAILED：${OUT}/_agent_failed.tsv" >&2; exit 1; }
}

produced=0; dropped=0; rejected=0; agent_failed=0; agent_empty=0
lineno=0
while IFS= read -r cluster; do
  lineno=$((lineno + 1))
  [ -n "$cluster" ] || continue

  # cluster 檔有一行壞掉（不是合法 JSON，或缺 cluster/members 欄位）要指名
  # 是哪個檔第幾行壞的，然後整批失敗——不能悄悄跳過壞行、也不能讓 nsrc 落到
  # 空字串然後讓下面 `[ "$nsrc" -lt 3 ]` 用一個不是整數的值去比較（那樣會是
  # bash 的 `[: integer expression expected` 錯誤，不是這支腳本自己的
  # 診斷）。jq 解析失敗的退出碼是 5，不是 1，所以不能只看「非 0」以外的
  # 假設，這裡就地分兩行拿退出碼，不靠 `local x="$(cmd)"` 那種會把退出碼
  # 洗成 local 自己的 0 的寫法（這裡本來就不是 local，但保留這個習慣，
  # 避免以後有人把這段抽進函式時連帶把退出碼洗掉）。
  cid="$(printf '%s' "$cluster" | jq -r '.cluster' 2>/dev/null)"
  cid_rc=$?
  if [ "$cid_rc" -ne 0 ] || [ -z "$cid" ] || [ "$cid" = "null" ]; then
    printf 'CLUSTER_LINE_INVALID\t%s\t第 %s 行不是合法的群組 JSON（找不到 cluster 欄位，jq 退出碼 %s）\n' \
      "$CLUSTERS" "$lineno" "$cid_rc" >&2
    exit 1
  fi

  nsrc="$(printf '%s' "$cluster" | jq -r '[.members[].html_url] | unique | length' 2>/dev/null)"
  nsrc_rc=$?
  if [ "$nsrc_rc" -ne 0 ] || [ -z "$nsrc" ]; then
    printf 'CLUSTER_LINE_INVALID\t%s\t第 %s 行（cluster=%s）的 members 欄位無法解析（jq 退出碼 %s）\n' \
      "$CLUSTERS" "$lineno" "$cid" "$nsrc_rc" >&2
    exit 1
  fi

  # n（群大小）跟 top_terms 只用來讓 _dropped.tsv／_agent_failed.tsv 這兩份
  # 診斷紀錄可讀，不影響任何控制流程，但一樣不能用 2>/dev/null 吞掉退出碼
  # 就算了——跟上面 cid／nsrc 的處理保持一致，才不會在同一個函式裡一半嚴謹
  # 一半隨便。往上挪到 nsrc 判斷之後、丟棄門檻之前算，因為 agent 失敗（下面）
  # 也需要這兩個值，不只丟棄分支要用。
  n="$(printf '%s' "$cluster" | jq -r '.n' 2>/dev/null)"
  n_rc=$?
  if [ "$n_rc" -ne 0 ]; then
    printf 'CLUSTER_LINE_INVALID\t%s\t第 %s 行（cluster=%s）的 n 欄位無法解析（jq 退出碼 %s）\n' \
      "$CLUSTERS" "$lineno" "$cid" "$n_rc" >&2
    exit 1
  fi

  terms="$(printf '%s' "$cluster" | jq -r '.top_terms | join(",")' 2>/dev/null)"
  terms_rc=$?
  if [ "$terms_rc" -ne 0 ]; then
    printf 'CLUSTER_LINE_INVALID\t%s\t第 %s 行（cluster=%s）的 top_terms 欄位無法解析（jq 退出碼 %s）\n' \
      "$CLUSTERS" "$lineno" "$cid" "$terms_rc" >&2
    exit 1
  fi

  if [ "$nsrc" -lt 3 ]; then
    printf '%s\t%s\t%s\t%s\t出處只有 %s 則\n' "$CLUSTERS_TAG" "$cid" "$n" "$terms" "$nsrc" \
      >> "$OUT/_dropped.tsv"
    dropped_rc=$?
    [ "$dropped_rc" -eq 0 ] || { echo "DROPPED_LOG_WRITE_FAILED：${OUT}/_dropped.tsv" >&2; exit 1; }
    dropped=$((dropped + 1))
    continue
  fi

  # agent 指令本身失敗（非驗證失敗——它根本沒機會被驗證）要有自己的持久
  # 記錄，不能只印到 stderr：ARG_MAX 那次事故發生時，事後完全查不到是哪個
  # cluster、多大、什麼主題失敗的，只剩一句已經捲走的 stderr。跟 _dropped.tsv
  # 一樣的欄位形狀（tag、cluster id、n、top_terms），最後一欄換成 agent 的
  # 退出碼。這個分支也不進 rejected 計數——rejected 是「有 raw 產出、但沒通過
  # 檢查」，agent 失敗連 raw 產出都沒有，混進同一個數字會讓 summary 那句
  # 「退回 K（驗證不過）」對這部分產出假的意涵。
  raw="$(printf '%s' "$cluster" | "$AGENT")"
  agent_rc=$?
  if [ "$agent_rc" -ne 0 ]; then
    log_agent_failed "agent 退出碼 ${agent_rc}"
    printf 'AGENT_FAILED\tcluster=%s(%s)\texit=%s\n' "$cid" "$CLUSTERS_TAG" "$agent_rc" >&2
    agent_failed=$((agent_failed + 1)); continue
  fi

  # agent 退出 0 但沒吐出任何東西：這跟「吐出來了但格式不合格」是兩種不同的
  # 失敗，混報會讓兩邊都失去診斷價值。原本的作法是讓它往下走驗證路徑，於是
  # 得到一句「沒通過驗證」跟一個 1 byte 的 _rejected 檔。那句話是錯的（根本
  # 沒有東西可驗），那個檔案也是空的：_rejected/ 存在的意義是留住原始產出供
  # 人判斷是 prompt 的問題還是模型的問題，而一個 1 byte 的檔案兩者都判斷不了，
  # 只是讓「退回 K（驗證不過）」這個數字灌水。空輸出的正確歸類是呼叫失敗，
  # 跟非 0 退出同一類，所以進 _agent_failed.tsv 並自己算一個數。
  if [ -z "$raw" ]; then
    log_agent_failed "agent 空輸出（退出碼 0）"
    printf 'AGENT_EMPTY_OUTPUT\tcluster=%s(%s)\tagent 退出 0 但沒有任何輸出\n' \
      "$cid" "$CLUSTERS_TAG" >&2
    agent_empty=$((agent_empty + 1)); continue
  fi

  # id 從產出的 frontmatter 讀，檔名跟著它 —— rule_validate 會驗兩者一致，
  # 所以先寫到暫存檔、讀出 id、再改名到正式位置。mktemp 一定帶 template：
  # macOS 的無參數版本會忽略 TMPDIR，寫到系統預設的 /tmp。
  tmp="$(mktemp "${TMPDIR:-/tmp}/rule.XXXXXX")" || exit 1
  printf '%s\n' "$raw" > "$tmp"

  id="$(rule_field "$tmp" id 2>/dev/null)"
  if [ -z "$id" ]; then
    reject_from_tmp "產出沒有 id 欄位"
    continue
  fi

  if ! id_is_safe "$id"; then
    reject_from_tmp "id 含有不安全字元（只接受英數字/連字號/底線）：${id}"
    continue
  fi

  dest="$OUT/${id}.md"
  # 不同群產出同一個 id（agent 幻覺撞名，或同一層重跑前沒清空舊產出）：不能
  # 直接 mv 蓋過去，那是把一條可能已經驗證過的規則靜默銷毀。
  #
  # 但「先 [ -e ] 檢查、再 mv」只在單一行程底下成立。多個行程共用同一個 --out
  # 目錄時，兩個都可以通過那個檢查，然後後到的 mv 靜默覆蓋先到的那個，也就是
  # 這段檢查本來要防的事照樣發生，而且完全無聲。目前 Step 6 的驅動迴圈是循序
  # 的，所以還踩不到；但這支腳本的介面就是「多次呼叫寫進同一個 --out」，把它
  # 改成平行是最自然的加速方式，而那時這個洞會安靜地吃掉規則。
  # 改用 noclobber 的 O_EXCL 建檔，把「檢查」與「宣告」併成同一個不可分割的
  # 動作：同時搶的兩個行程只會有一個建檔成功，另一個必定拿到失敗。代價是零，
  # 不必等到真的改平行才補。
  #
  # 宣告失敗有兩種原因，不能混報：dest 真的已經存在（撞名，記成
  # RULE_REJECTED、既有檔案原封不動），或寫入本身出錯（權限不足、磁碟滿，
  # 要整批停下來）。用事後檢查 dest 存不存在來區分，並把 noclobber 自己的
  # 錯誤訊息一起印出來，不丟掉。
  claim_err="$( { set -o noclobber; : > "$dest"; } 2>&1 )"
  claim_rc=$?
  if [ "$claim_rc" -ne 0 ]; then
    if [ -e "$dest" ]; then
      reject_from_tmp "id=${id} 與既有規則檔撞名（可能是不同群產出相同 id，或同一層重跑前沒清空舊產出）"
      continue
    fi
    echo "DEST_CLAIM_FAILED：${dest}：${claim_err}" >&2
    rm -f "$tmp"
    exit 1
  fi

  # 這裡蓋掉的是上一步自己建的 0 byte 佔位檔，不是別人的規則。mv 失敗時要把
  # 佔位檔一起清掉，否則留下一個空的 <id>.md 會讓之後每一次重跑都誤判成撞名。
  mv "$tmp" "$dest" || { echo "MOVE_FAILED：${dest}" >&2; rm -f "$tmp" "$dest"; exit 1; }
  if ! rule_validate "$dest"; then
    mv "$dest" "$OUT/_rejected/${CLUSTERS_TAG}-${cid}.md" \
      || echo "REJECT_MOVE_FAILED：${OUT}/_rejected/${CLUSTERS_TAG}-${cid}.md" >&2
    printf 'RULE_REJECTED\tcluster=%s(%s)\t沒通過驗證，原始輸出留在 _rejected/%s-%s.md\n' \
      "$cid" "$CLUSTERS_TAG" "$CLUSTERS_TAG" "$cid" >&2
    rejected=$((rejected + 1)); continue
  fi
  produced=$((produced + 1))
done < "$CLUSTERS"

printf '產出 %s、丟棄 %s（出處不足）、退回 %s（驗證不過）、agent 失敗 %s、agent 空輸出 %s\n' \
  "$produced" "$dropped" "$rejected" "$agent_failed" "$agent_empty"
