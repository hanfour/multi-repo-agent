#!/usr/bin/env bash
# 用途：掃真實語料裡會讓五個篩選斷言炸掉的型別異常。用法：bash scripts/corpus-scan-anomalies.sh [owner/repo]（省略則掃描所有已快取的 repo）
# jq 的物件 key 用 ASCII，中文要加引號。
set -uo pipefail
C="${MRA_CORPUS_DIR:-$HOME/.cache/mra-review-corpus}"

_scan_dir() {
  local label="$1" dir="$2"
  echo "=== $label"
  jq -s 'add
    | { total: length,
        user_null: ([.[] | select(.user == null)] | length),
        login_not_string: ([.[] | select(.user != null and ((.user.login | type) != "string"))] | length),
        body_null: ([.[] | select(.body == null)] | length),
        body_not_string: ([.[] | select(.body != null and ((.body | type) != "string"))] | length),
        reactions_missing: ([.[] | select(.reactions == null)] | length),
        total_count_not_number: ([.[] | select(.reactions != null and ((.reactions.total_count | type) != "number"))] | length),
        author_association_missing: ([.[] | select(.author_association == null)] | length),
        diff_hunk_missing: ([.[] | select(.diff_hunk == null)] | length),
        path_missing: ([.[] | select(.path == null)] | length),
        html_url_missing: ([.[] | select(.html_url == null)] | length) }' "$dir"/[0-9]*.json 2>/dev/null
}

if [ -n "${1:-}" ]; then
  repo="$1"
  _scan_dir "$repo" "$C/${repo//\//__}"
else
  for d in "$C"/*/; do
    [ -d "$d" ] || continue
    pages=("$d"[0-9]*.json)
    [ -e "${pages[0]}" ] || continue
    repo="$(basename "$d")"
    _scan_dir "${repo//__//}" "$d"
  done
fi
