#!/usr/bin/env bash
# TDD for review PR-discussion context. The review agents read existing PR
# comments/reviews (via MRA_REVIEW_PR_DISCUSSION) so they don't re-report
# already-raised issues and respect the author's clarifications.
# _review_format_pr_discussion is the PURE core: a JSON array of
# {author,loc,kind,body} in → a compact markdown block out. A failed/empty fetch
# must yield empty output so review behaviour is unchanged.
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/project-path.sh"
source "$MRA_DIR/lib/review.sh"
source "$MRA_DIR/lib/review-json.sh"

errors=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

# 1. empty / [] / garbage → empty output (best-effort: never alter review behaviour)
[[ -z "$(_review_format_pr_discussion '')"        ]] && ok "empty input → empty"   || fail "empty input must yield empty"
[[ -z "$(_review_format_pr_discussion '[]')"      ]] && ok "[] → empty"            || fail "[] must yield empty"
[[ -z "$(_review_format_pr_discussion 'not json')" ]] && ok "garbage → empty"      || fail "garbage must yield empty (best-effort)"

# 2. entries → header + one bullet each, with author + loc + body
OUT=$(_review_format_pr_discussion '[
  {"author":"alice","loc":"src/x.ts:42","kind":"inline","body":"missing null check"},
  {"author":"bob","loc":"","kind":"comment","body":"looks fine overall"}
]')
echo "$OUT" | grep -q "Existing PR discussion" || fail "must emit a header"
echo "$OUT" | grep -qF "@alice (src/x.ts:42): missing null check" || fail "inline entry must show author+loc+body"
echo "$OUT" | grep -qF "@bob: looks fine overall" || fail "comment entry must show author+body (no loc)"
echo "$OUT" | grep -q "Existing PR discussion" && echo "$OUT" | grep -qF "@alice (src/x.ts:42)" \
  && ok "formats entries with author/loc/body"

# 3. body newlines collapsed → exactly one bullet per entry
OUT=$(_review_format_pr_discussion '[{"author":"c","loc":"","kind":"comment","body":"line1\nline2"}]')
[[ "$(printf '%s\n' "$OUT" | grep -c '^- ')" == "1" ]] \
  && ok "multiline body collapsed to one bullet" || fail "multiline body must stay one bullet"

# 4. long body truncated with … and bounded
LONGBODY=$(printf 'x%.0s' {1..400})
OUT=$(_review_format_pr_discussion "[{\"author\":\"c\",\"loc\":\"\",\"kind\":\"comment\",\"body\":\"$LONGBODY\"}]")
printf '%s' "$OUT" | grep -q "…" && ok "long body truncated with …" || fail "long body must be truncated"
[[ "${#OUT}" -lt 400 ]] && ok "truncation bounds output length" || fail "truncated output should be shorter than the raw body"

# 5. the debate agents consume the env (guard so the wiring isn't silently dropped)
grep -q 'MRA_REVIEW_PR_DISCUSSION' "$MRA_DIR/lib/review-debate.sh" \
  && ok "debate agents reference MRA_REVIEW_PR_DISCUSSION" || fail "debate agents must consume MRA_REVIEW_PR_DISCUSSION"
grep -q 'MRA_REVIEW_PR_CONTEXT' "$MRA_DIR/lib/review.sh" \
  && ok "PR-context fetch is config-gated (MRA_REVIEW_PR_CONTEXT)" || fail "fetch must gate on MRA_REVIEW_PR_CONTEXT"
grep -q '_review_prompt_with_pr_discussion' "$MRA_DIR/lib/review.sh" \
  && ok "single-pass review injects PR discussion context" || fail "single-pass prompt must include PR discussion context"

OUT=$(_review_format_pr_scope '{"title":"List tracking codes","body":"Create is explicitly out of scope for this PR.","base":{"ref":"main"},"head":{"ref":"feature/list"},"labels":[{"name":"frontend"}]}')
printf '%s' "$OUT" | grep -qF 'Create is explicitly out of scope' && ok "PR description is included as scope context" || fail "PR description missing from scope context"
printf '%s' "$OUT" | grep -qF 'Untrusted PR Scope' && ok "PR metadata is marked untrusted" || fail "PR metadata must be marked untrusted"

export MRA_REVIEW_PR_DISCUSSION="$OUT"
single_pass_prompt=$(_review_prompt_with_pr_discussion 'BASE SINGLE PASS PROMPT')
unset MRA_REVIEW_PR_DISCUSSION
printf '%s' "$single_pass_prompt" | grep -qF 'Create is explicitly out of scope' \
  && ok "single-pass prompt carries out-of-scope PR text" || fail "single-pass prompt missing PR scope text"
printf '%s' "$single_pass_prompt" | grep -qF 'BASE SINGLE PASS PROMPT' \
  && ok "single-pass prompt preserves original review prompt" || fail "single-pass prompt lost base prompt"

echo ""
[[ $errors -eq 0 ]] && echo "PASS: all review-pr-context tests passed" || { echo "FAIL: $errors tests failed"; exit 1; }
