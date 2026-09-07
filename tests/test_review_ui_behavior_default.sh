#!/usr/bin/env bash
# lib/review.sh：personas 路徑要把這次 diff 的變更檔交給
# default_review_personas()，ui-behavior-inspector 才能依變更檔自動開關。
#
# 這條線只有走完整的 review_project 才驗得到：default_review_personas() 的
# 單元測試（tests/test_review_personas.sh）證明函式本身會判斷，但函式拿不到
# 變更檔的話，判斷永遠是「沒有前端變更」。呼叫端漏傳參數不會讓任何單元測試
# 變紅，只會讓這個功能安靜地什麼都不做。
#
# 骨架沿用 tests/test_review_personas_all_failed.sh：照 bin/mra.sh 的 MRA_LIBS
# 清單載入，準備最小 workspace 與 git repo，覆寫 run_persona_review 把收到的
# persona 清單寫進旗標檔，不連網路也不用真的模型憑證。
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else fail "$1，找不到[$3]：$2"; fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else fail "$1，不應含[$3]：$2"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-ui-behavior-default.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export MRA_CONFIG="$TMP/config.json"
printf '%s' '{"configVersion":2,"review":{"providerMode":"claude","primaryProvider":"claude"}}' \
  > "$MRA_CONFIG"
export MRA_REVIEW_POST_MODE=none
export MRA_REVIEW_PR_CONTEXT=0
export MRA_REVIEW_PREMISE_CHECK=0
export MRA_REVIEW_PERSONAS=true
export MRA_REVIEW_EMIT_JSON=1

WS="$TMP/ws"
mkdir -p "$WS/.collab" "$WS/proj"
printf '%s' '{"projects":{"proj":{"type":"node","deps":{},"consumedBy":[],"confidence":{}}},"gitOrg":"acme","workspace":"'"$WS"'","version":1,"lastScan":"now"}' \
  > "$WS/.collab/dep-graph.json"

R="$WS/proj"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
mkdir -p "$R/apps/frontend/src" "$R/apps/backend/src"
printf 'export const a = 1\n' > "$R/apps/backend/src/service.ts"
printf 'export const L = () => null\n' > "$R/apps/frontend/src/list-page.tsx"
git -C "$R" add .; git -C "$R" commit -q -m init

eval "$(sed -n '/^MRA_LIBS=(/,/^)/p' "$MRA_DIR/bin/mra.sh")"
for lib in "${MRA_LIBS[@]}"; do
  # shellcheck source=/dev/null
  source "$MRA_DIR/lib/${lib}.sh"
done

PERSONAS_FLAG="$TMP/personas-received"

# run_persona_review 在 command substitution 的子 shell 裡跑，函式外的變數
# 觀察不到，所以把收到的 persona 清單寫進旗標檔。
run_persona_review() { printf '%s\n' "$5" > "$PERSONAS_FLAG"; printf '%s' "finding"; }
run_synthesize() { printf '%s' '{"status":"APPROVED","summary":"ok","comments":[]}'; }

# 每個案例都從 main 開一支新分支，只改指定的檔案，再跑一次 review。
review_with_change() {
  local branch="$1" file="$2"
  git -C "$R" checkout -q main
  git -C "$R" checkout -q -b "$branch"
  printf 'export const changed = 2\n' >> "$R/$file"
  git -C "$R" add .; git -C "$R" commit -q -m "change $file"
  rm -f "$PERSONAS_FLAG"
  review_project "$WS" proj --base main >/dev/null 2>&1
  wait 2>/dev/null || true
  cat "$PERSONAS_FLAG" 2>/dev/null
}

# 案例一：diff 只碰前端元件檔，ui-behavior-inspector 要自動加入。
personas_ui="$(review_with_change ui-change apps/frontend/src/list-page.tsx)"
contains "前端變更時 persona 清單含 ui-behavior-inspector" "$personas_ui" "ui-behavior-inspector"
contains "前端變更時原本五個 persona 仍在" "$personas_ui" "security-auditor"

# 案例二：diff 只碰後端檔，ui-behavior-inspector 不該被加進去。
personas_backend="$(review_with_change backend-change apps/backend/src/service.ts)"
not_contains "純後端變更時 persona 清單不含 ui-behavior-inspector" "$personas_backend" "ui-behavior-inspector"
contains "純後端變更時原本五個 persona 仍在" "$personas_backend" "security-auditor"

# 案例三：明確設 0 時，前端變更也不加。
personas_off="$(MRA_REVIEW_ENABLE_UI_BEHAVIOR=0 review_with_change ui-change-off apps/frontend/src/list-page.tsx)"
not_contains "MRA_REVIEW_ENABLE_UI_BEHAVIOR=0 時前端變更也不加" "$personas_off" "ui-behavior-inspector"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
