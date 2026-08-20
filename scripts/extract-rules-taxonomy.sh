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
#     只在檔案還不存在時建立，之後一律 append。
#   - id 撞名（agent 幻覺撞名，或同一層重跑前沒清空舊產出）不能直接 mv
#     蓋過去——那是把一條可能已經驗證過的規則靜默銷毀。跟 A 路線一樣，
#     寫入正式位置之前先檢查 dest 是否已存在。
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
    --corpus) CORPUS="$2"; shift 2 ;;
    --layer)  LAYER="$2";  shift 2 ;;
    --out)    OUT="$2";    shift 2 ;;
    *) echo "用法：extract-rules-taxonomy.sh --corpus <jsonl> --layer <層> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -s "$CORPUS" ] || { echo "CORPUS_MISSING：${CORPUS}" >&2; exit 1; }
[ -n "$LAYER" ] || { echo "LAYER_MISSING" >&2; exit 1; }
case "$MIN_HITS" in
  ''|*[!0-9]*) echo "MRA_TAXONOMY_MIN_HITS 必須是非負整數：${MIN_HITS}" >&2; exit 1 ;;
esac
mkdir -p "$OUT" "$OUT/_rejected" || exit 1

# 只在檔案還不存在時建立，之後一律 append——見檔頭說明。Step 7 對五層各呼叫
# 一次，全部寫進同一個 --out 目錄，若每次呼叫都截斷重寫（`: > file`），
# 五層跑完只會剩最後一層的紀錄，前四層的丟棄清單被悄悄蓋掉。
[ -f "$OUT/_dropped.tsv" ] || : > "$OUT/_dropped.tsv"
[ -f "$OUT/_agent_failed.tsv" ] || : > "$OUT/_agent_failed.tsv"

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

produced=0; dropped=0; rejected=0; agent_failed=0
while IFS=$'\t' read -r class_id class_name _; do
  [ -n "$class_id" ] || continue
  hits="$(taxonomy_search "$class_id" "$CORPUS" 40)"
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
    printf '%s\t%s\t%s\t%s\t%s\n' "$LAYER" "$class_id" "$class_name" "$n" "$agent_rc" \
      >> "$OUT/_agent_failed.tsv"
    agent_failed_rc=$?
    [ "$agent_failed_rc" -eq 0 ] || { echo "AGENT_FAILED_LOG_WRITE_FAILED：${OUT}/_agent_failed.tsv" >&2; exit 1; }
    printf 'AGENT_FAILED\tclass=%s\t退出碼 %s\n' "$class_id" "$agent_rc" >&2
    agent_failed=$((agent_failed + 1)); continue
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
  # mv 蓋過去，那是把一條可能已經驗證過的規則靜默銷毀。攔下來記成
  # RULE_REJECTED，既有檔案原封不動——跟 A 路線的撞名處理一致。
  if [ -e "$dest" ]; then
    reject_from_tmp "id=${id} 與既有規則檔撞名（可能是不同 class 產出相同 id，或同一層重跑前沒清空舊產出）" "${LAYER}-${class_id}"
    continue
  fi

  mv "$tmp" "$dest" || { echo "MOVE_FAILED：${dest}" >&2; rm -f "$tmp"; exit 1; }
  if ! rule_validate "$dest"; then
    mv "$dest" "$OUT/_rejected/${LAYER}-${class_id}.md" \
      || echo "REJECT_MOVE_FAILED：${OUT}/_rejected/${LAYER}-${class_id}.md" >&2
    printf 'RULE_REJECTED\tclass=%s\t沒通過驗證，原始輸出留在 _rejected/%s-%s.md\n' \
      "$class_id" "$LAYER" "$class_id" >&2
    rejected=$((rejected + 1)); continue
  fi
  produced=$((produced + 1))
done < <(taxonomy_classes)

printf '%s 層：產出 %s、丟棄 %s（實例不足）、退回 %s（驗證不過）、agent 失敗 %s\n' \
  "$LAYER" "$produced" "$dropped" "$rejected" "$agent_failed"
