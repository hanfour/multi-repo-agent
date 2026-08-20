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
    --clusters) CLUSTERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "用法：extract-rules-tfidf.sh --clusters <檔> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -s "$CLUSTERS" ] || { echo "CLUSTERS_MISSING：${CLUSTERS}" >&2; exit 1; }
mkdir -p "$OUT" "$OUT/_rejected" || exit 1

# Step 6 對五層各呼叫一次這支腳本，全部寫進同一個 --out 目錄，這兩點是照
# 那個實際用法設計的，brief 的參考實作沒考慮到：
#
#   - _dropped.tsv 若每次呼叫都截斷重寫（`: > file`），五層跑完只會剩最後
#     一層的紀錄，前四層的丟棄清單被悄悄蓋掉。改成只在檔案還不存在時建立，
#     之後一律 append；每一行帶著來源檔案的 tag，讀的人才分得出是哪一層。
#   - _rejected/<cluster>.md 這個檔名如果只用裸的 cluster id，兩層的
#     cluster 0 會互相覆蓋掉對方的診斷檔（cluster id 在每個 clusters.jsonl
#     裡都是從 0 重新編號的，不是全域唯一）。用來源檔案的 basename 當前綴
#     消掉碰撞。
[ -f "$OUT/_dropped.tsv" ] || : > "$OUT/_dropped.tsv"
# agent 指令本身失敗（非 0 退出碼：額度用盡、認證失效、崩潰等）跟「出處不足
# 被丟棄」是不同的失敗模式，不能共用 _dropped.tsv——那個檔案的語意是「這個
# 群的資料本身不夠格」，agent 失敗是「這個群本來夠格，但呼叫失敗了」，讀
# 記錄的人需要分得出這兩種。同樣以 append 累積、不截斷，理由跟 _dropped.tsv
# 一樣：Step 6 對五層各呼叫一次，全部寫進同一個 --out 目錄。
[ -f "$OUT/_agent_failed.tsv" ] || : > "$OUT/_agent_failed.tsv"
CLUSTERS_TAG="$(basename "$CLUSTERS" .jsonl)"

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

produced=0; dropped=0; rejected=0; agent_failed=0
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
  raw="$(printf '%s' "$cluster" | "$AGENT")" || {
    agent_rc=$?
    printf '%s\t%s\t%s\t%s\tagent 退出碼 %s\n' "$CLUSTERS_TAG" "$cid" "$n" "$terms" "$agent_rc" \
      >> "$OUT/_agent_failed.tsv"
    af_rc=$?
    [ "$af_rc" -eq 0 ] || { echo "AGENT_FAILED_LOG_WRITE_FAILED：${OUT}/_agent_failed.tsv" >&2; exit 1; }
    printf 'AGENT_FAILED\tcluster=%s(%s)\texit=%s\n' "$cid" "$CLUSTERS_TAG" "$agent_rc" >&2
    agent_failed=$((agent_failed + 1)); continue
  }

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
  # 不同群產出同一個 id（agent 幻覺撞名，或同一層重跑前沒清空舊產出）：
  # 不能直接 mv 蓋過去，那是把一條可能已經驗證過的規則靜默銷毀。攔下來
  # 記成 RULE_REJECTED，既有檔案原封不動。
  if [ -e "$dest" ]; then
    reject_from_tmp "id=${id} 與既有規則檔撞名（可能是不同群產出相同 id，或同一層重跑前沒清空舊產出）"
    continue
  fi

  mv "$tmp" "$dest" || { echo "MOVE_FAILED：${dest}" >&2; rm -f "$tmp"; exit 1; }
  if ! rule_validate "$dest"; then
    mv "$dest" "$OUT/_rejected/${CLUSTERS_TAG}-${cid}.md" \
      || echo "REJECT_MOVE_FAILED：${OUT}/_rejected/${CLUSTERS_TAG}-${cid}.md" >&2
    printf 'RULE_REJECTED\tcluster=%s(%s)\t沒通過驗證，原始輸出留在 _rejected/%s-%s.md\n' \
      "$cid" "$CLUSTERS_TAG" "$CLUSTERS_TAG" "$cid" >&2
    rejected=$((rejected + 1)); continue
  fi
  produced=$((produced + 1))
done < "$CLUSTERS"

printf '產出 %s、丟棄 %s（出處不足）、退回 %s（驗證不過）、agent 失敗 %s\n' \
  "$produced" "$dropped" "$rejected" "$agent_failed"
