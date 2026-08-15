#!/usr/bin/env bash
# 語料篩選五步 (lib/corpus-filter.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/corpus-filter.sh"
FX="$MRA_DIR/tests/fixtures/corpus/sample-comments.json"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }
n()    { jq 'length'; }
ids()  { jq -c '[.[].id]'; }

eq "fixture 九筆" "9" "$(n < "$FX")"

eq "1 去 bot 留 7"    "7" "$(corpus_filter_bots < "$FX" | n)"
eq "1 濾掉 id 1,2"    "[3,4,5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | ids)"

eq "2 資深留 6"       "6" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | n)"
eq "2 濾掉 id 3"      "[4,5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | ids)"

eq "3 品質留 5"       "5" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | n)"
eq "3 濾掉 id 4"      "[5,6,7,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | ids)"

eq "4 有說明留 4"     "4" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | n)"
eq "4 濾掉 id 8"      "[5,6,7,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | ids)"

# 投影保留 diff_hunk 與出處 URL
proj="$(corpus_project rails/rails rails < "$FX")"
eq "投影保留 diff_hunk" "@@ -10,3 +10,5 @@" "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .diff_hunk')"
eq "投影帶 repo"        "rails/rails"       "$(printf '%s' "$proj" | jq -r '.[0].repo')"
eq "投影帶 layer"       "rails"             "$(printf '%s' "$proj" | jq -r '.[0].layer')"
eq "投影帶出處 URL"     "https://x/5"       "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .url')"
eq "投影帶 reviewer"    "member1"           "$(printf '%s' "$proj" | jq -r '.[] | select(.id==5) | .reviewer')"

# 串完整管線：stdout 是結果，stderr 是留存數
err="$(mktemp)"
outn="$(corpus_filter_all rails/rails rails < "$FX" 2>"$err" | n)"
eq "全管線留 4" "4" "$outn"
eq "留存數 TSV" "RETENTION	rails/rails	9	7	6	5	4" "$(cat "$err")"
rm -f "$err"

# 空輸入不炸
eq "空陣列進出都是 0" "0" "$(printf '[]' | corpus_filter_bots | corpus_filter_senior | corpus_filter_quality | corpus_filter_prose | n)"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
