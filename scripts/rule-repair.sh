#!/usr/bin/env bash
# scripts/rule-repair.sh --rejected <目錄> --out <目錄>
#
# 萃取產出有相當比例因為 frontmatter 少了收尾的 --- 而被 rule_validate 擋下。
# 這支腳本只做一件事：在「frontmatter 最後一個 key: value 之後、第一個 ## 之前」
# 插入一行 ---，重新驗證，通過的以其 id 搬到 <out>。不補欄位、不改標題、不猜
# 內容——那些是模型該產出的東西，補了就是我們自己在寫規則，不是從語料萃取。
#
# 邊界（task-4b-brief.md，每一種都有 tests/test_rule_repair.sh 的測試覆蓋）：
#   1. frontmatter 已經有成對的 --- → 不插入第二個，原內容原封不動送去驗證
#   2. 第一個 ## 出現在（NR>1 的）任何候選收尾 --- 之後才有 --- → 格式整個壞掉
#      （那個 --- 出現在 heading 之後，不是 frontmatter 的收尾），不可修復
#   3. 完全沒有 ## → 沒有插入點，不可修復
#   4. 第一行不是 --- → 不是 frontmatter 格式，不可修復
#   5. 殘缺輸出（例如整個檔案只剩一行 URL）→ 必落在 3、4 其中一種形狀，一律
#      不可修復，不會被誤判成可修復
#   6. 修復後 id 與檔名（_rejected 底下是 cluster tag）不符是正常的，搬到
#      <out> 時用 id 重新命名，不沿用原檔名
#   7. <out> 已有同名檔 → 印診斷、跳過，不靜默覆蓋既有規則
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-targets.sh"
source "$MRA_DIR/lib/rule-schema.sh"

REJECTED=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rejected) REJECTED="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "用法：rule-repair.sh --rejected <目錄> --out <目錄>" >&2; exit 1 ;;
  esac
done
[ -d "$REJECTED" ] || { echo "用法：rule-repair.sh --rejected <目錄> --out <目錄>" >&2; exit 1; }
mkdir -p "$OUT" || exit 1

# rule_repair_plan <file> — 印出一行修復計畫到 stdout，tab 分隔：
#   INSERT\t<行號>   在該行號（第一個 ## 所在行）之前插入 ---
#   ALREADY_CLOSED   frontmatter 已經有成對的 ---，不需要（也不該）插入
#   UNFIXABLE\t<原因代碼>
# 退出碼：INSERT／ALREADY_CLOSED 回 0，UNFIXABLE 回 1。
#
# 判斷邏輯只看兩個座標：第一個 ## 開頭行的行號、以及第 2 行以後第一個「整行
# 就是 ---」的行號（如果有的話）。用 head -n1 單獨判斷第一行是不是 ---，不
# 塞進 awk 裡跟其他邏輯共用一個 exit 路徑——awk 的 exit 在非 END 區塊裡會先
# 跳到 END 再結束，容易在忘記加旗標時讓 END 區塊誤判成別的分支，寧可用兩段
# 各自單純的檢查。
rule_repair_plan() {
  local f="$1"
  local first_line; first_line="$(head -n1 "$f")"
  if [ "$first_line" != "---" ]; then
    printf 'UNFIXABLE\tFIRST_LINE_NOT_DASH\n'
    return 1
  fi
  awk '
    NR==1 { next }
    /^## / && !first_hh { first_hh = NR }
    $0 == "---" && !first_dash { first_dash = NR }
    END {
      if (!first_hh) { print "UNFIXABLE\tNO_HEADING"; exit 1 }
      if (first_dash && first_dash < first_hh) { print "ALREADY_CLOSED"; exit 0 }
      if (first_dash && first_dash > first_hh) { print "UNFIXABLE\tHEADING_BEFORE_CLOSER"; exit 1 }
      print "INSERT\t" first_hh; exit 0
    }' "$f"
}

# 「仍不通過」的原因分開計數，不要全部併進同一個數字：呼叫端要能分辨
# UNFIXABLE（資料本身的問題，正常——模型輸出被截斷、格式整個壞掉）跟撞名
# （設定錯誤，要修——同一層重跑前沒清空舊產出）是完全不同性質的訊號，混在
# 一起就沒辦法自動化地判斷「這批要不要人看」。原本是四種
# （UNFIXABLE／缺id／驗證未過／撞名），unsafe_id 是修 Critical 1（id 路徑
# 穿越）之後新增的第五種：id 本身含不安全字元，理論上不該發生（prompt
# 已經要求格式），但如果發生了，代表模型輸出偏離 prompt 的程度比一般
# UNFIXABLE 更值得注意，所以獨立算一類，不要悄悄併進 missing_id。
rescued=0; unfixable=0; missing_id=0; unsafe_id=0; still_invalid=0; conflicts=0

for f in "$REJECTED"/*.md; do
  [ -e "$f" ] || continue

  plan_out="$(rule_repair_plan "$f")"
  plan_rc=$?
  action="$(printf '%s' "$plan_out" | cut -f1)"

  if [ "$plan_rc" -ne 0 ]; then
    reason="$(printf '%s' "$plan_out" | cut -f2)"
    printf 'RULE_REPAIR_UNFIXABLE\t%s\t%s\n' "$f" "$reason" >&2
    unfixable=$((unfixable + 1))
    continue
  fi

  # mktemp 一定帶 template：macOS 的無參數版本會忽略 TMPDIR，寫到系統預設的
  # /tmp。用一個獨立的 scratch 目錄裝這個檔案的修復內容與（之後）id 命名的
  # 副本，處理完立刻清掉，不留殘骸，也避免同一輪跑到的兩個不同 id 檔案互相
  #踩到彼此的暫存檔名。
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/rule-repair.XXXXXX")" || exit 1
  content="$scratch/content.md"

  if [ "$action" = "INSERT" ]; then
    ins_line="$(printf '%s' "$plan_out" | cut -f2)"
    # 用 ENVIRON 傳行號，不用 awk -v：-v 會先處理反斜線跳脫，跟
    # lib/corpus-targets.sh corpus_layer_of() 的既有慣例一致（見該檔註解）。
    # 這裡的值是純數字，不會被反斜線跳脫影響到結果，但保持同一套習慣，避免
    # 以後有人在別處抄這行去傳真正可能含反斜線的值。
    INS_LINE="$ins_line" awk 'NR==ENVIRON["INS_LINE"] { print "---" } { print }' "$f" > "$content"
  else
    # ALREADY_CLOSED：不插入任何東西，原內容原封不動送去驗證。如果它仍然
    # 不合格（多半是別的原因，例如出處不足），下面的驗證會照實回報，這裡
    # 不需要也不該猜測還缺什麼。
    cp "$f" "$content" || {
      echo "RULE_REPAIR_COPY_FAILED：${content}" >&2
      rm -rf "$scratch"
      exit 1
    }
  fi

  id="$(rule_field "$content" id)"
  id_rc=$?

  if [ "$id_rc" -ne 0 ] || [ -z "$id" ]; then
    printf 'RULE_REPAIR_STILL_INVALID\t%s\t修復後仍缺 id 欄位\n' "$f" >&2
    missing_id=$((missing_id + 1))
    rm -rf "$scratch"
    continue
  fi

  # id 會直接拼進檔案路徑（$scratch/<id>.md、之後的 $OUT/<id>.md）。這個 id
  # 來自修復後重讀的 frontmatter，跟 extract-rules-tfidf.sh 讀到的 id 一樣
  # 是未經清洗的模型輸出，同一個信任邊界、同一個威脅（帶 `/` 或 `..` 的 id
  # 會讓後面的 mv 寫到 $OUT 以外的路徑），所以用同一份 id_is_safe()
  # （lib/rule-schema.sh）判斷，不要在這裡另外寫一份會漂移的複本。
  if ! id_is_safe "$id"; then
    printf 'RULE_REPAIR_UNSAFE_ID\t%s\tid=%s 含有不安全字元（只接受英數字/連字號/底線），拒絕寫入\n' \
      "$f" "$id" >&2
    unsafe_id=$((unsafe_id + 1))
    rm -rf "$scratch"
    continue
  fi

  # rule_validate 會用 basename 跟 frontmatter 裡的 id 比對；_rejected 底下
  # 的檔名是 cluster tag，跟 id 本來就不會一致（邊界 6），所以驗證前先把
  # 內容複製成用 id 命名的檔案，而不是照原檔名驗證——否則每個檔案都會被
  # RULE_ID_MISMATCH 擋下，不管 frontmatter 本身修得對不對。
  named="$scratch/${id}.md"
  mv "$content" "$named" || {
    echo "RULE_REPAIR_RENAME_FAILED：${named}" >&2
    rm -rf "$scratch"
    exit 1
  }

  if ! rule_validate "$named" 2>"$scratch/validate.err"; then
    printf 'RULE_REPAIR_STILL_INVALID\t%s\t修復後仍未通過驗證：%s\n' \
      "$f" "$(tr '\n' ' ' < "$scratch/validate.err")" >&2
    still_invalid=$((still_invalid + 1))
    rm -rf "$scratch"
    continue
  fi

  dest="$OUT/${id}.md"
  if [ -e "$dest" ]; then
    printf 'RULE_REPAIR_CONFLICT\t%s\tid=%s 的目的地 %s 已存在，不覆蓋\n' \
      "$f" "$id" "$dest" >&2
    conflicts=$((conflicts + 1))
    rm -rf "$scratch"
    continue
  fi

  mv "$named" "$dest" || {
    echo "RULE_REPAIR_MOVE_FAILED：${dest}" >&2
    rm -rf "$scratch"
    exit 1
  }
  # 成功搬到 <out> 之後，原始檔案要從 <rejected> 移除（介面說的是「搬」，不是
  # 「複製」）——只有仍不通過的才「留在原地」。
  rm -f "$f" || {
    echo "RULE_REPAIR_SOURCE_CLEANUP_FAILED：${f}" >&2
    rm -rf "$scratch"
    exit 1
  }
  rm -rf "$scratch"
  rescued=$((rescued + 1))
done

# 「仍不通過」的總數維持原本的相容格式（呼叫端既有的字串比對還能用），
# 括號裡的拆解是 Task 8 呼叫端要用來分辨五種失敗原因的地方：撞名是設定
# 錯誤（要修），UNFIXABLE 是資料本身的問題（正常），兩者不該共用同一個數字。
unfixed=$((unfixable + missing_id + unsafe_id + still_invalid + conflicts))
printf '救回 %s、仍不通過 %s（UNFIXABLE %s、缺 id %s、id 不安全 %s、驗證未過 %s、撞名 %s）\n' \
  "$rescued" "$unfixed" "$unfixable" "$missing_id" "$unsafe_id" "$still_invalid" "$conflicts"
[ "$conflicts" -eq 0 ]
