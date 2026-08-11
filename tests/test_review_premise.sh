#!/usr/bin/env bash
# A finding may not invent the convention it says the code violates.
#
# Measured across 80 reviewed pull requests on one repository: 31 inline
# findings, of which 5 reviews were dismissed by hand — and every one of the
# five rested on a premise nobody had checked. Three of them were the SAME
# invented decorator, reported as [HIGH] and [CRITICAL] on three separate pull
# requests:
#
#   "this method is not annotated `@RequirePermission` like the existing
#    controller convention"
#
# The decorator does not exist. Independently confirmed by code search:
# RequirePermission 0 occurrences, PermissionGuard 0, AuthGuard 9. A reviewer
# refuted it with one grep, opening their reply "查證後回報" — reporting after
# verifying, which is what the finding should have done.
#
# The same 31 findings cite a concrete file, symbol, or line 2 times, and use
# convention-asserting language ("慣例", "既有", "must", "existing") 16 times.
# They assert; they do not cite. This makes the assertion checkable: if a
# finding says a symbol is the established convention, that symbol has to be
# somewhere in the repository.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/review-premise.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; mkdir -p "$REPO/src"
git -C "$REPO" init -q 2>/dev/null || { mkdir -p "$REPO"; git -C "$REPO" init -q; }
git -C "$REPO" config user.email t@t.t; git -C "$REPO" config user.name t
cat > "$REPO/src/controller.ts" <<'TS'
@UseGuards(AuthGuard, AdvertiserContextGuard)
export class LineItemController {
  patch() {}
}
TS
git -C "$REPO" add -A; git -C "$REPO" commit -qm base

# --- 1. the real case: an invented convention -------------------------------
invented='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"HIGH",
   "body":"這個 PR 新增的 PATCH 端點沒有像既有 controller 慣例那樣標註 `@RequirePermission`，會造成授權繞過。"}]}'
got=$(_review_enforce_premises "$invented" "$REPO")
[[ "$(jq -r '.comments | length' <<<"$got")" == "0" ]] \
  && ok "a finding citing a convention that does not exist is dropped" \
  || fail "the invented convention survived — this blocked three real PRs"

# --- 2. the same claim about something that DOES exist survives -------------
real='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"HIGH",
   "body":"此 handler 未依既有慣例套用 `AdvertiserContextGuard`，租戶隔離會失效。"}]}'
got=$(_review_enforce_premises "$real" "$REPO")
[[ "$(jq -r '.comments | length' <<<"$got")" == "1" ]] \
  && ok "a convention that really exists is not touched" \
  || fail "a legitimate finding was dropped — the gate must not silence real issues"

# --- 3. no convention claim → never gated -----------------------------------
# "add a `RetryPolicy` here" proposes something new; it does not claim the
# thing already exists, so an absent symbol proves nothing.
proposal='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"MEDIUM",
   "body":"建議新增一個 `RetryPolicy` 包裝這段呼叫，避免暫時性失敗直接往上拋。"}]}'
got=$(_review_enforce_premises "$proposal" "$REPO")
[[ "$(jq -r '.comments | length' <<<"$got")" == "1" ]] \
  && ok "proposing something new is not a claim that it exists" \
  || fail "a proposal was gated as though it asserted an existing convention"

# A plain defect report with no symbol at all must pass untouched.
plain='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"HIGH","body":"這裡會除以零。"}]}'
[[ "$(jq -r '.comments | length' <<<"$(_review_enforce_premises "$plain" "$REPO")")" == "1" ]] \
  && ok "a finding with no cited symbol is untouched" || fail "plain finding gated"

# --- 4. English phrasing is caught too --------------------------------------
en='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"HIGH",
   "body":"This endpoint does not use `RequirePermission`, unlike the existing controllers in this codebase."}]}'
[[ "$(jq -r '.comments | length' <<<"$(_review_enforce_premises "$en" "$REPO")")" == "0" ]] \
  && ok "the same claim in English is caught" || fail "only the zh-TW phrasing is checked"

# --- 5. a symbol introduced by this very diff counts as existing ------------
# The finding may reference something the PR just added; it is in the tree.
git -C "$REPO" checkout -q -b feature
printf 'export const NewlyAddedGuard = 1\n' > "$REPO/src/new.ts"
git -C "$REPO" add -A; git -C "$REPO" commit -qm add
added='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"HIGH",
   "body":"未依既有慣例套用 `NewlyAddedGuard`。"}]}'
[[ "$(jq -r '.comments | length' <<<"$(_review_enforce_premises "$added" "$REPO")")" == "1" ]] \
  && ok "a symbol the diff itself introduced is present, not invented" \
  || fail "the gate ignored code added by this PR"

# --- 6. the gate must never destroy a result it cannot read -----------------
[[ "$(_review_enforce_premises 'not json' "$REPO")" == "not json" ]] \
  && ok "unparseable input passes through" || fail "the gate ate a result it could not parse"
[[ "$(jq -r '.comments|length' <<<"$(_review_enforce_premises "$invented" "$TMP/nonexistent")")" == "1" ]] \
  && ok "an unsearchable tree gates nothing (cannot prove absence)" \
  || fail "absence was inferred from a tree that could not be searched"
[[ "$(jq -r '.status' <<<"$(_review_enforce_premises "$invented" "$REPO")")" == "CHANGES_REQUESTED" ]] \
  && ok "the gate does not rewrite the verdict" || fail "the gate changed status"

# --- 7. what it reports ------------------------------------------------------
out=$(_review_enforce_premises "$invented" "$REPO" 2>&1 >/dev/null)
printf '%s' "$out" | grep -qF 'RequirePermission' \
  && ok "the dropped premise is named in the log" \
  || fail "a silent drop is as opaque as the wrong finding was"

# --- 8. the three production phrasings, verbatim in shape ------------------
# All three blocked a pull request; all three were dismissed; all three name a
# decorator with zero occurrences. They are kept as separate cases because they
# make the claim three different ways, and an earlier version of this gate
# caught only the first two.
i=0
for body in \
  '[HIGH] 範圍內問題：這個 PR 新增可修改主欄位的 PATCH 端點，但此 method 沒有像既有 controller 慣例那樣標註 `@RequirePermission`。' \
  '[HIGH] 這是本 PR 新增且可直接觸發的狀態變更 API，但方法上沒有 `@RequirePermission` 權限標註；依專案架構，controller 需要標註 permission。' \
  '[CRITICAL] 這是本 PR 新增端點的 in-scope 問題：handler 沒有加上 `@RequirePermission` 或等效的授權。'; do
  i=$((i+1))
  j=$(jq -cn --arg b "$body" '{status:"CHANGES_REQUESTED",summary:"s",comments:[{path:"src/controller.ts",line:3,severity:"HIGH",body:$b}]}')
  [[ "$(jq -r '.comments|length' <<<"$(_review_enforce_premises "$j" "$REPO" 2>/dev/null)")" == "0" ]] \
    && ok "production phrasing #$i is caught" \
    || fail "production phrasing #$i survived — it blocked a real PR and was dismissed"
done

# Note the scope ritual visible in all three: "範圍內問題", "這是本 PR 新增…的
# in-scope 問題". The prompt says out-of-scope work is not a defect, so the
# model opens by declaring scope instead of establishing it. Asserting scope
# must not exempt a finding from having its premise checked.
ritual='{"status":"CHANGES_REQUESTED","summary":"s","comments":[
  {"path":"src/controller.ts","line":3,"severity":"CRITICAL",
   "body":"這是本 PR 範圍內、今天就可觸發的問題：未套用 `@RequirePermission`。"}]}'
[[ "$(jq -r '.comments|length' <<<"$(_review_enforce_premises "$ritual" "$REPO" 2>/dev/null)")" == "0" ]] \
  && ok "declaring in-scope does not exempt a finding from the premise check" \
  || fail "a scope declaration got the finding past the gate"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
