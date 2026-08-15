#!/usr/bin/env bash
# 自家 Acme repo 的語料取材。
#
# 與外部語料共用抓取與第 1、3、4 步篩選，只有第 2 步不同：Acme repo 的成員
# author_association 幾乎都是 MEMBER，分不出資深與否，改用近一年的留言數。

corpus_internal_targets() {
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

# 近一年留言數達門檻的人。輸出是 JSON 陣列，直接餵給 corpus_filter_active。
# 三頁全部抓失敗時要回 1，不能靜默回空陣列：那會讓認證或網路故障看起來像
# 「這個 repo 沒有活躍的 reviewer」，語料靜默變空而流程回報成功。
corpus_active_reviewers() {
  local repo="$1" min="${2:-10}" page ok=0
  local all=""
  for page in 1 2 3; do
    local one
    if one="$(gh api "repos/$repo/pulls/comments?per_page=100&page=$page&sort=created&direction=desc" \
                --jq '.[].user.login // empty' 2>/dev/null)"; then
      ok=1
      all+="$one"$'\n'
    fi
  done
  if [[ "$ok" -eq 0 ]]; then
    printf 'ACTIVE_REVIEWERS_FETCH_FAILED\t%s\n' "$repo" >&2
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
