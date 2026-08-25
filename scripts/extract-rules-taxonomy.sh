#!/usr/bin/env bash
# B 路線：骨架來自回測分類，語料提供每一類的判準與反例。
#
# 與 A 路線的關鍵差異在 prompt：A 問「這群意見在講什麼共同問題」，B 問
# 「這一類問題在這個框架下長什麼樣、判準是什麼、什麼情況不該報」。
# 骨架已定，agent 的工作是填內容而不是決定主題。
#
# Step 7 會對五層各呼叫一次這支腳本，全部寫進同一個 --out 目錄——這點跟
# A 路線（scripts/extract-rules-tfidf.sh）用法一致，所以同一批「共用 --out
# 目錄跨多次呼叫」的坑也要在這裡防：
#
#   - _dropped.tsv 若每次呼叫都截斷重寫，五層跑完只會剩最後一層的紀錄。
#     改以來源層為單位重寫，重跑語意見下面 purge_tag_rows 前的說明。
#   - id 撞名（agent 幻覺撞名，或同一層重跑前沒清空舊產出）不能直接 mv
#     蓋過去，那是把一條可能已經驗證過的規則靜默銷毀。跟 A 路線一樣，
#     寫入正式位置之前用原子的方式宣告 dest。
#   - agent 產出的 id 是未清洗的模型輸出，拼進檔案路徑之前要過
#     lib/rule-schema.sh 的 id_is_safe()——一個帶 `/` 或 `..` 的 id 會讓
#     後面的 mv 寫到 $OUT 以外的路徑。這一步在最初的參考實作草稿裡漏掉，
#     這裡照 A 路線補上。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"
source "$MRA_DIR/lib/taxonomy-classes.sh"

CORPUS=""; LAYER=""; OUT=""; MIN_HITS="${MRA_TAXONOMY_MIN_HITS:-3}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    # 每個需要值的旗標都先驗 arity，理由同 extract-rules-tfidf.sh：少了這道，
    # 旗標後面沒接東西會踩到 set -u，訊息跟使用者打錯的東西完全對不上。
    --corpus)
      [ $# -ge 2 ] || { echo "用法：--corpus 需要接一個 jsonl 檔" >&2; exit 1; }
      CORPUS="$2"; shift 2 ;;
    --layer)
      [ $# -ge 2 ] || { echo "用法：--layer 需要接一個層名" >&2; exit 1; }
      LAYER="$2";  shift 2 ;;
    --out)
      [ $# -ge 2 ] || { echo "用法：--out 需要接一個目錄" >&2; exit 1; }
      OUT="$2";    shift 2 ;;
    *) echo "用法：extract-rules-taxonomy.sh --corpus <jsonl> --layer <層> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -s "$CORPUS" ] || { echo "CORPUS_MISSING：${CORPUS}" >&2; exit 1; }
[ -n "$LAYER" ] || { echo "LAYER_MISSING" >&2; exit 1; }
[ -n "$OUT" ] || { echo "OUT_MISSING：需要 --out <目錄>" >&2; exit 1; }
case "$MIN_HITS" in
  ''|*[!0-9]*) echo "MRA_TAXONOMY_MIN_HITS 必須是非負整數：${MIN_HITS}" >&2; exit 1 ;;
esac
mkdir -p "$OUT" "$OUT/_rejected" || exit 1

# 重跑語意選的是「以來源層為單位，最後一次跑覆蓋前一次」：開跑前先把屬於這
# 一層的舊列刪掉，別層的列原封不動，之後照常 append。跟 A 路線
# （scripts/extract-rules-tfidf.sh）同一套語意，那邊有完整的取捨說明。
#
# 為什麼不是無條件 append（原本的作法）：同一層重跑第二次會把同一批列再寫一
# 遍，而同一個目錄裡的 _rejected/<層>-<class>.md 走的卻是覆蓋，一個目錄裡並存
# 兩種相反的語意。
#
# 為什麼不是無條件截斷：Step 7 對五層各呼叫一次、全部寫進同一個 --out 目錄，
# 截斷會讓五層跑完只剩最後一層的紀錄。
#
# purge_tag_rows <檔案> <tag 所在欄位> <tag> — 刪掉屬於這個 tag 的舊列，其他
# tag 的列原封不動。檔案還不存在時建一個空的。
#
# 這是「讀出來、過濾、寫回去」，不是原子操作，前提是 Step 7 那個驅動迴圈一次
# 只跑一層（目前確實是循序的 for 迴圈）。要把五層改成平行跑的話，這裡跟下面
# 兩個 append 點都得先加互斥。
#
# 欄位序號當參數傳，是因為這兩份
# 紀錄的層欄位不在同一欄：_dropped.tsv 的欄位形狀是 class_id、class_name、
# 層，_agent_failed.tsv 是層、class_id、class_name。與 A 路線各留一份一模一樣
# 的複本：這段邏輯屬於 scripts/ 這一層的重跑語意，而 lib/ 是兩條管線共用的
# 介面層，為了七行程式碼在共用層開一個新函式的代價比複製高。
purge_tag_rows() {
  local file="$1" field="$2" tag="$3" tmpf
  if [ ! -f "$file" ]; then
    : > "$file" || { echo "LOG_INIT_FAILED：${file}" >&2; return 1; }
    return 0
  fi
  tmpf="$(mktemp "${TMPDIR:-/tmp}/rule-log.XXXXXX")" || return 1
  # 用 ENVIRON 傳值，不用 awk -v：-v 會先處理反斜線跳脫，帶反斜線的值會被
  # 改寫成另一個字串、比對不到。這跟 lib/corpus-targets.sh 的既有慣例一致。
  if ! MRA_TAG="$tag" MRA_FIELD="$field" awk -F'\t' \
      '$(ENVIRON["MRA_FIELD"]) != ENVIRON["MRA_TAG"]' "$file" > "$tmpf"; then
    rm -f "$tmpf"; echo "LOG_PURGE_FAILED：${file}" >&2; return 1
  fi
  mv "$tmpf" "$file" || { rm -f "$tmpf"; echo "LOG_PURGE_FAILED：${file}" >&2; return 1; }
}

purge_tag_rows "$OUT/_dropped.tsv" 3 "$LAYER" || exit 1
purge_tag_rows "$OUT/_agent_failed.tsv" 1 "$LAYER" || exit 1

AGENT="${MRA_RULE_AGENT_CMD:-}"
[ -n "$AGENT" ] || { echo "MRA_RULE_AGENT_CMD 未設定" >&2; exit 1; }

# reject_from_tmp <reason> <tag> — 把還留在暫存檔（尚未 mv 到 $OUT/<id>.md）
# 的不合格產出留底到 _rejected/，再清掉暫存檔並計數。給「id 缺欄位」
# 「id 含不安全字元」「id 撞名」三種在寫入正式位置之前就被攔下的情況共用，
# 跟 scripts/extract-rules-tfidf.sh 的 reject_from_tmp 是同一個角色。
reject_from_tmp() {
  local reason="$1" tag="$2"
  cp "$tmp" "$OUT/_rejected/${tag}.md" \
    || echo "REJECT_COPY_FAILED：${OUT}/_rejected/${tag}.md" >&2
  printf 'RULE_REJECTED\tclass=%s\t%s，原始輸出留在 _rejected/%s.md\n' \
    "$class_id" "$reason" "$tag" >&2
  rm -f "$tmp"
  rejected=$((rejected + 1))
}

# log_agent_failed <最後一欄的說明> — 把一筆 agent 呼叫失敗記進
# _agent_failed.tsv。給「非 0 退出」與「退出 0 但空輸出」兩種呼叫失敗共用：
# 兩者都是「這一類本來夠格，但這次呼叫沒拿到東西」。
log_agent_failed() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$LAYER" "$class_id" "$class_name" "$n" "$1" \
    >> "$OUT/_agent_failed.tsv" \
    || { echo "AGENT_FAILED_LOG_WRITE_FAILED：${OUT}/_agent_failed.tsv" >&2; exit 1; }
}

produced=0; dropped=0; rejected=0; agent_failed=0; agent_empty=0
while IFS=$'\t' read -r class_id class_name _; do
  [ -n "$class_id" ] || continue
  # taxonomy_search 的退出碼一定要接住。不接的話，語料檔壞掉（一行截斷的
  # JSON）與「這個類別在這一層真的沒有實例」會得到同一個結果：n=0，然後被
  # 記成「撈到 0 則，少於 3」丟棄。實測一行截斷讓 8 個類別裡的 7 個被誤報成
  # 實例不足，而真正的原因是語料壞了 —— 那是要重跑 materialize，不是要放寬
  # MIN_HITS。
  if ! hits="$(taxonomy_search "$class_id" "$CORPUS" 40)"; then
    echo "CORPUS_SEARCH_FAILED：在 ${CORPUS} 搜尋類別 ${class_id} 失敗（見上方 jq 的診斷）。這不是「實例不足」，是語料本身有問題，先修語料再跑" >&2
    exit 1
  fi
  n="$(printf '%s' "$hits" | grep -c . || true)"

  if [ "$n" -lt "$MIN_HITS" ]; then
    printf '%s\t%s\t%s\t撈到 %s 則，少於 %s\n' \
      "$class_id" "$class_name" "$LAYER" "$n" "$MIN_HITS" >> "$OUT/_dropped.tsv"
    dropped_rc=$?
    [ "$dropped_rc" -eq 0 ] || { echo "DROPPED_LOG_WRITE_FAILED：${OUT}/_dropped.tsv" >&2; exit 1; }
    dropped=$((dropped + 1)); continue
  fi

  # 用 jq -s 從 stdin 把撈到的多行 JSONL 收成陣列，不要把 hits 塞進
  # `--argjson m "$(...)"` 這種command substitution 再當 argv 傳給 jq——
  # 語料的 body/diff_hunk 欄位量測過最大到 291KB 一行，40 則候選疊起來很
  # 容易超過這台機器 `getconf ARG_MAX` 量到的 1,048,576 bytes，execve 會
  # 直接回 `Argument list too long`，跟 scripts/rule-agent.sh 檔頭記錄的
  # ARG_MAX 事故是同一個類型的坑，只是換了一個發生的位置。改成讓 jq 自己
  # 從 stdin slurp，資料量不受 argv 上限影響。
  payload="$(printf '%s' "$hits" | jq -s --arg c "$class_id" --arg name "$class_name" --arg l "$LAYER" \
    '{class_id: $c, class_name: $name, layer: $l, members: .}')"

  # agent 指令本身失敗要落地成檔案，不能只印 stderr。跟 A 路線一樣的欄位
  # 形狀（layer、class_id、class_name、命中數、agent 的退出碼），跟
  # 「驗證退回」分開計數——agent 失敗的那幾筆根本沒機會被驗證，併進
  # 「退回 K（驗證不過）」那句話是錯的。
  raw="$(printf '%s' "$payload" | MRA_RULE_PROMPT_PREFIX="$(taxonomy_prompt_prefix "$class_id" "$class_name" "$LAYER")" "$AGENT")"
  agent_rc=$?
  if [ "$agent_rc" -ne 0 ]; then
    log_agent_failed "$agent_rc"
    printf 'AGENT_FAILED\tclass=%s\t退出碼 %s\n' "$class_id" "$agent_rc" >&2
    agent_failed=$((agent_failed + 1)); continue
  fi

  # agent 退出 0 但沒吐出任何東西：這跟「吐出來了但格式不合格」是兩種不同的
  # 失敗，混報會讓兩邊都失去診斷價值。原本的作法是讓它往下走驗證路徑，於是
  # 得到一句「沒通過驗證」跟一個 1 byte 的 _rejected 檔。那句話是錯的（根本
  # 沒有東西可驗），那個檔案也是空的：_rejected/ 存在的意義是留住原始產出供
  # 人判斷是 prompt 的問題還是模型的問題，1 byte 的檔案兩者都判斷不了。空輸出
  # 的正確歸類是呼叫失敗，跟非 0 退出同一類，所以進 _agent_failed.tsv 並自己
  # 算一個數。跟 A 路線的處置一致。
  if [ -z "$raw" ]; then
    log_agent_failed "空輸出"
    printf 'AGENT_EMPTY_OUTPUT\tclass=%s\tagent 退出 0 但沒有任何輸出\n' "$class_id" >&2
    agent_empty=$((agent_empty + 1)); continue
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/rule.XXXXXX")" || exit 1
  printf '%s\n' "$raw" > "$tmp"
  id="$(rule_field "$tmp" id 2>/dev/null)"
  if [ -z "$id" ]; then
    reject_from_tmp "產出沒有 id 欄位" "${LAYER}-${class_id}"
    continue
  fi

  # id 是未清洗的模型輸出，直接拼進檔案路徑之前一定要過這道關卡：一個帶
  # `/` 或 `..` 的 id 會讓下面的 mv 寫到 $OUT 以外的路徑，且不會有任何錯誤
  # 訊號——這是路徑穿越。lib/rule-schema.sh 的 id_is_safe() 是兩條萃取管線
  # 共用的唯一判斷來源，不在這裡另外寫一份會漂移的複本。
  if ! id_is_safe "$id"; then
    reject_from_tmp "id 含有不安全字元（只接受英數字/連字號/底線）：${id}" "${LAYER}-${class_id}"
    continue
  fi

  dest="$OUT/${id}.md"
  # 同一個 id 被兩個不同 class（或同一層重跑前沒清空舊產出）產出：不能直接
  # mv 蓋過去，那是把一條可能已經驗證過的規則靜默銷毀。
  #
  # 但「先 [ -e ] 檢查、再 mv」只在單一行程底下成立。多個行程共用同一個 --out
  # 目錄時，兩個都可以通過那個檢查，然後後到的 mv 靜默覆蓋先到的那個。目前
  # Step 7 的驅動迴圈是循序的，所以還踩不到；但把它改成平行是最自然的加速
  # 方式。改用 noclobber 的 O_EXCL 建檔，把「檢查」與「宣告」
  # 併成同一個不可分割的動作。宣告失敗的兩種原因要分開報：dest 真的已存在
  # （撞名，記成 RULE_REJECTED、既有檔案原封不動），或寫入本身出錯（權限、
  # 磁碟滿，整批停下來）。跟 A 路線的撞名處理一致。
  claim_err="$( { set -o noclobber; : > "$dest"; } 2>&1 )"
  claim_rc=$?
  if [ "$claim_rc" -ne 0 ]; then
    if [ -e "$dest" ]; then
      reject_from_tmp "id=${id} 與既有規則檔撞名（可能是不同 class 產出相同 id，或同一層重跑前沒清空舊產出）" "${LAYER}-${class_id}"
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
    mv "$dest" "$OUT/_rejected/${LAYER}-${class_id}.md" \
      || echo "REJECT_MOVE_FAILED：${OUT}/_rejected/${LAYER}-${class_id}.md" >&2
    printf 'RULE_REJECTED\tclass=%s\t沒通過驗證，原始輸出留在 _rejected/%s-%s.md\n' \
      "$class_id" "$LAYER" "$class_id" >&2
    rejected=$((rejected + 1)); continue
  fi
  produced=$((produced + 1))
done < <(taxonomy_classes)

printf '%s 層：產出 %s、丟棄 %s（實例不足）、退回 %s（驗證不過）、agent 失敗 %s、agent 空輸出 %s\n' \
  "$LAYER" "$produced" "$dropped" "$rejected" "$agent_failed" "$agent_empty"
