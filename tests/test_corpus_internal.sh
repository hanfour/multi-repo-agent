#!/usr/bin/env bash
# 自家語料取材 (lib/corpus-internal.sh)。
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# MRA_CORPUS_DIR 要指到本測試專屬的目錄，理由同 tests/test_build_corpus.sh：
# 不設的話 corpus_cache_dir 會退回 $HOME/.cache/mra-review-corpus，跑這條測試
# 會動到使用者真正的快取，而且平行測試檔之間會互相污染 retention.tsv。
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MRA_CORPUS_DIR="$TMP/cache"
mkdir -p "$MRA_CORPUS_DIR"

source "$MRA_DIR/lib/corpus-filter.sh"
source "$MRA_DIR/lib/corpus-internal.sh"
FX="$MRA_DIR/tests/fixtures/corpus/sample-comments.json"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

# 目標清單：五層都要有代表，且 PR 量最高的 erp 要在
bad_cols=$(corpus_internal_targets | awk -F'\t' 'NF != 2' | wc -l | tr -d ' ')
eq "每行兩欄" "0" "$bad_cols"
for r in acme/rails-app-1 acme/nest-monorepo-2.0 acme/react-app-1 acme/vue-app-1; do
  if corpus_internal_targets | cut -f1 | grep -qx "$r"; then ok "含 $r"; else fail "缺 $r"; fi
done

# 第 2 步改用活躍留言者清單，不看 author_association。
# fixture 裡 member1 有 4 則、member2 與 member3 各 1 則、outsider 1 則。
active='["member1"]'
eq "只留 member1" "[4,5,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_active "$active" | jq -c '[.[].id]')"

# outsider 在 GitHub 上是 NONE，但只要留言夠多就該留下：
# 這正是自家 repo 與外部 repo 的差別。
active2='["member1","outsider"]'
eq "NONE 也能留下" "[3,4,5,8,9]" "$(corpus_filter_bots < "$FX" | corpus_filter_active "$active2" | jq -c '[.[].id]')"

# 完整管線的 stdout / stderr 契約與外部版一致
err="$(mktemp "${TMPDIR:-/tmp}/corpus-internal-test.XXXXXX")"
outn="$(corpus_filter_all_internal acme/rails-app-1 rails "$active" < "$FX" 2>"$err" | jq 'length')"
# 留 2 筆（id 5、9）。id 4 短且無回覆無 reaction 被第 3 步濾掉，
# id 8 只有 suggestion 區塊沒有說明文字被第 4 步濾掉。
eq "自家管線留 2" "2" "$outn"
eq "自家管線 ids" "[5,9]" "$(corpus_filter_all_internal acme/rails-app-1 rails "$active" < "$FX" 2>/dev/null | jq -c '[.[].id]')"
case "$(cat "$err")" in RETENTION*acme/rails-app-1*) ok "留存數 TSV 格式一致" ;; *) fail "TSV 格式不對：$(cat "$err")" ;; esac
rm -f "$err"

# 留存去重必須是字串比對。acme/nest-monorepo-2.0 的那個點如果被當成正規表示式，
# 會連 acme/nest-monorepo-2X0 這種不相干的列一起刪掉。Task 4 的目標清單裡沒有含
# metachar 的名稱，所以這條回歸測試只能放在這裡。
R="$MRA_CORPUS_DIR/retention.tsv"
mkdir -p "$MRA_CORPUS_DIR"
printf 'repo\tn0_raw\tn1_nobot\tn2_senior\tn3_quality\tn4_prose\n' > "$R"
printf 'acme/nest-monorepo-2.0\t1\t1\t1\t1\t1\n' >> "$R"
printf 'acme/nest-monorepo-2X0\t9\t9\t9\t9\t9\n' >> "$R"
CORPUS_REPO="acme/nest-monorepo-2.0" awk -F'\t' 'NR == 1 || $1 != ENVIRON["CORPUS_REPO"]' "$R" > "$R.probe"
eq "含 . 的名稱只刪自己那列" "1" "$(grep -c '^acme/nest-monorepo-2X0	' "$R.probe")"
eq "自己那列有刪掉" "0" "$(grep -c '^acme/nest-monorepo-2\.0	' "$R.probe")"
rm -f "$R.probe"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
