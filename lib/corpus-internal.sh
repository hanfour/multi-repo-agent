#!/usr/bin/env bash
# 自家 repo 的語料取材。
#
# 與外部語料共用抓取與第 1、3、4 步篩選，只有第 2 步不同：自家 repo 的成員
# author_association 幾乎都是 MEMBER，分不出資深與否，改用近一年的留言數。

# 自家 repo 清單。這份專案是公開的，真實的 repo 名稱不進版控：放在
# MRA_CORPUS_INTERNAL_TARGETS 指的檔案，或預設的 .collab/
# corpus-internal-targets.tsv（已在 .gitignore 內）。格式是每列
# 「repo<TAB>layer」，layer 取值見 corpus_layers。
#
# 檔案不存在時退回底下的代號清單，讓沒有自家語料的人也跑得動、也看得懂格式。
# 檔案存在但讀不到或格式錯時硬失敗，不退回代號清單：那會讓「設定檔壞了」跟
# 「沒有設定檔」變成同一個外觀，而前者跑完會得到一份查無此 repo 的空語料。
corpus_internal_targets() {
  local f="${MRA_CORPUS_INTERNAL_TARGETS:-${MRA_DIR:-.}/.collab/corpus-internal-targets.tsv}"
  if [[ -e "$f" ]]; then
    if [[ ! -r "$f" || ! -s "$f" ]]; then
      printf 'INTERNAL_TARGETS_UNUSABLE\t%s\n' "$f" >&2
      return 1
    fi
    if ! awk -F'\t' 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$f"; then
      printf 'INTERNAL_TARGETS_MALFORMED\t%s\n' "$f" >&2
      return 1
    fi
    cat "$f"
    return 0
  fi
  cat <<'EOF'
acme/rails-app-1	rails
acme/rails-app-2	rails
acme/rails-app-3	rails
acme/nest-monorepo-2.0	nestjs
acme/nest-app-2	nestjs
acme/nest-app-3	nestjs
acme/react-app-1	react
acme/react-app-2	react
acme/vue-app-1	vue
acme/vue-app-2	vue
EOF
}

# corpus_internal_layer_of <repo> — 這個 Acme repo 屬於哪一層。查不到時
# 印不出東西、退出碼非 0，由呼叫端決定要擋下來還是退回 common：這裡不自己
# 預設成 common，那會讓「新開的 repo 還沒登記」跟「這個 repo 真的屬於通用
# 層」變成同一個外觀。
#
# repo 名稱透過 ENVIRON 傳給 awk，不用 -v，理由與 corpus_layer_of 相同
# （awk 的 -v 會先處理反斜線跳脫，含換行的值還會讓 awk crash）。
corpus_internal_layer_of() {
  local repo="$1"
  corpus_internal_targets \
    | CORPUS_REPO="$repo" awk -F'\t' '$1 == ENVIRON["CORPUS_REPO"] { print $2; found = 1 } END { exit !found }'
}

# 近一年留言數達門檻的人。輸出是 JSON 陣列，直接餵給 corpus_filter_active。
#
# 三頁全部要成功才能算數，不能只看「有沒有任何一頁成功」。舊版只要 1、2 頁成功
# 就繼續往下算，等於拿一個絕對門檻（留言數 >= 10）去套一個只剩三分之一或三分之二
# 的樣本，活躍的 reviewer 因此悄悄消失——下游看起來會跟「這個 repo 真的沒有活躍
# 的 reviewer」一模一樣，是三頁全失敗那次修過的同一種混淆，只是換了個觸發條件。
corpus_active_reviewers() {
  local repo="$1" min="${2:-10}" page succeeded=0
  local all=""
  for page in 1 2 3; do
    local one
    if one="$(gh api "repos/$repo/pulls/comments?per_page=100&page=$page&sort=created&direction=desc" \
                --jq '.[].user.login // empty' 2>/dev/null)"; then
      succeeded=$((succeeded + 1))
      all+="$one"$'\n'
    fi
  done
  if [[ "$succeeded" -lt 3 ]]; then
    if [[ "$succeeded" -eq 0 ]]; then
      printf 'ACTIVE_REVIEWERS_FETCH_FAILED\t%s\n' "$repo" >&2
    else
      printf 'ACTIVE_REVIEWERS_PARTIAL\t%s\t%s/3\n' "$repo" "$succeeded" >&2
    fi
    return 1
  fi
  printf '%s' "$all" \
    | grep -v '^$' \
    | sort | uniq -c \
    | CORPUS_MIN="$min" awk '$1 >= ENVIRON["CORPUS_MIN"] { print $2 }' \
    | jq -R . | jq -s -c .
}

corpus_filter_active() {
  local reviewers="$1"
  jq --argjson active "$reviewers" '[ .[] | select(.user.login as $u | $active | any(. == $u)) ]'
}

# 錯誤傳遞的規則與 corpus_filter_all 相同，理由見那邊的註解。
#
# 這裡刻意不疊 corpus_filter_all 新加的「該 repo 留言數前 15 名」子句：上面
# corpus_filter_active 的第 2 步本來就是依「近一年活躍留言數」挑人，再疊一層
# 「留言數前 15 名」是在同一個訊號上再篩一次，篩不出新東西，只會讓兩個判準的
# 交互作用變得難懂。
corpus_filter_all_internal() {
  local repo="$1" layer="$2" reviewers="$3"
  local s0 s1 s2 s3 s4
  s0="$(cat)"

  if ! printf '%s' "$s0" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'FILTER_INPUT_INVALID\t%s\n' "$repo" >&2
    return 1
  fi

  s1="$(printf '%s' "$s0" | corpus_filter_bots)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tbots\n' "$repo" >&2; return 1; }
  s2="$(printf '%s' "$s1" | corpus_filter_active "$reviewers")" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tactive\n' "$repo" >&2; return 1; }
  s3="$(printf '%s' "$s2" | corpus_filter_quality)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tquality\n' "$repo" >&2; return 1; }
  s4="$(printf '%s' "$s3" | corpus_filter_prose)" \
    || { printf 'FILTER_STAGE_FAILED\t%s\tprose\n' "$repo" >&2; return 1; }
  printf 'RETENTION\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" \
    "$(printf '%s' "$s0" | jq 'length')" \
    "$(printf '%s' "$s1" | jq 'length')" \
    "$(printf '%s' "$s2" | jq 'length')" \
    "$(printf '%s' "$s3" | jq 'length')" \
    "$(printf '%s' "$s4" | jq 'length')" >&2
  printf '%s' "$s4" | corpus_project "$repo" "$layer"
}
