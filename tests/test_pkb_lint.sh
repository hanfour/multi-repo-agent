#!/usr/bin/env bash
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/pkb-cache.sh"

errors=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors + 1)); }
expect_invalid() {
  local label="$1" content="$2" reason=""
  if _pkb_valid_doc "$content" reason; then
    fail "$label: expected invalid"
  elif [[ -n "$reason" ]]; then
    pass "$label: invalid ($reason)"
  else
    fail "$label: invalid without a reason"
  fi
}
expect_valid() {
  local label="$1" content="$2"
  _pkb_valid_doc "$content" && pass "$label" || fail "$label: expected valid"
}

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pkb-lint-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/home"
HOME="$TEST_TMP/home"
export HOME

CHATTER="The write requires permission I don't have in this mode, so I'll present the CONVENTIONS document directly here instead of saving it to a file."
DOC_BODY=$(cat <<'EOF'
# Conventions: sample-api

## Coding Style
Use explicit names and keep modules focused. Validate external input at system boundaries, and add tests for behavior that could regress.
EOF
)
FRONTMATTER_DOC=$(cat <<'EOF'
---
title: sample-api
owner: platform
---
# Conventions: sample-api

The project keeps focused modules and validates external input at system boundaries.
EOF
)
HTML_COMMENT_DOC=$(cat <<'EOF'
<!-- generated from the repository -->
# Conventions: sample-api

The project keeps focused modules and validates external input at system boundaries.
EOF
)
CHINESE_CHATTER_DOC=$(cat <<'EOF'
我沒有權限，以下是我將直接呈現的內容。
# Conventions: sample-api

The project keeps focused modules and validates external input at system boundaries.
EOF
)
NO_HEADING_CHATTER=$(cat <<'EOF'
First line
Second line
I cannot write the file, so here is the content.
Fourth line
Fifth line

The rest of this document is long enough to pass the existing substantive-content check.
EOF
)
NO_HEADING_LATE_CHATTER=$(cat <<'EOF'
First line
Second line
Third line
Fourth line
Fifth line
I cannot write the file, so here is the content.

The rest of this document is long enough to pass the existing substantive-content check.
EOF
)

expect_invalid "model chatter example" "$CHATTER

$DOC_BODY"
expect_valid "same document without chatter" "$DOC_BODY"
expect_valid "permission in body" "$DOC_BODY

## Security
The permission check is performed before each write operation. This is a normal project convention in the body."
expect_valid "front matter before heading" "$FRONTMATTER_DOC"
expect_valid "HTML comment before heading" "$HTML_COMMENT_DOC"
expect_invalid "Chinese chatter before heading" "$CHINESE_CHATTER_DOC"
expect_invalid "no-heading preface chatter" "$NO_HEADING_CHATTER"
expect_valid "no-heading chatter after first five non-empty lines" "$NO_HEADING_LATE_CHATTER"

expect_invalid "existing agent error rejection" "Error: Reached max turns (5)"
expect_invalid "existing API error rejection" "API Error from provider

This response includes extra detail so it reaches the minimum length check."
expect_invalid "existing execution error rejection" "Execution error from provider

This response includes extra detail so it reaches the minimum length check."
expect_invalid "existing empty rejection" ""
expect_invalid "existing short rejection" "short"

source "$MRA_DIR/lib/review.sh"
pkb_exists() { return 0; }
pkb_incremental_update() { : > "$TEST_TMP/incremental-called"; }
pkb_capture_decisions() { : > "$TEST_TMP/capture-called"; }
_review_pkb_auto_update "sample-api" "$TEST_TMP/repo" "src/change.ts" "" '{"comments":[]}' "claude"
[[ -e "$TEST_TMP/incremental-called" ]] \
  && pass "review update still runs incremental PKB update" \
  || fail "review update skipped incremental PKB update"
[[ ! -e "$TEST_TMP/capture-called" ]] \
  && pass "review update does not capture bot findings" \
  || fail "review update called pkb_capture_decisions"

WORKSPACE="$TEST_TMP/workspace"
GOOD_REPO="$WORKSPACE/sample-good"
BAD_REPO="$WORKSPACE/sample-bad"
mkdir -p "$GOOD_REPO/.mra/pkb" "$BAD_REPO/.mra/pkb"
printf '%s\n' "$DOC_BODY" > "$GOOD_REPO/.mra/pkb/conventions.md"
printf '1234567890123456789012345678901234567890\n' > "$GOOD_REPO/.mra/pkb/identity.md"
printf '%s\n\n%s\n' "$CHATTER" "$DOC_BODY" > "$BAD_REPO/.mra/pkb/conventions.md"
before=$(find "$WORKSPACE" -type f -exec cksum {} \; | sort)
lint_output=$(bash "$MRA_DIR/scripts/pkb-lint.sh" "$WORKSPACE" 2>&1)
lint_status=$?
after=$(find "$WORKSPACE" -type f -exec cksum {} \; | sort)
[[ "$lint_status" -eq 1 ]] && pass "workspace lint exits 1 for an invalid doc" \
  || fail "workspace lint should exit 1, got $lint_status: $lint_output"
[[ "$(printf '%s\n' "$lint_output" | grep -c '^INVALID ')" -eq 1 ]] \
  && pass "workspace lint prints one INVALID line" \
  || fail "workspace lint should print one INVALID line: $lint_output"
[[ "$lint_output" == *"$BAD_REPO/.mra/pkb/conventions.md:"* ]] \
  && pass "workspace lint names the invalid document" \
  || fail "workspace lint omitted the invalid path: $lint_output"
[[ "$lint_output" == *"Invalid PKB docs: 1"* ]] \
  && pass "workspace lint prints its invalid count" \
  || fail "workspace lint omitted the invalid count: $lint_output"
[[ "$before" == "$after" ]] && pass "workspace lint does not modify files" \
  || fail "workspace lint modified a file"

MODULE_REPO="$WORKSPACE/sample-modules"
mkdir -p "$MODULE_REPO/.mra/pkb/modules"
printf '1234567890123456789012345678901234567890\n' > "$MODULE_REPO/.mra/pkb/identity.md"
printf '%s\n\n%s\n' "$CHATTER" "$DOC_BODY" > "$MODULE_REPO/.mra/pkb/modules/auth.md"
before=$(find "$MODULE_REPO" -type f -exec cksum {} \; | sort)
module_output=$(bash "$MRA_DIR/scripts/pkb-lint.sh" "$MODULE_REPO" 2>&1)
module_status=$?
after=$(find "$MODULE_REPO" -type f -exec cksum {} \; | sort)
[[ "$module_status" -eq 1 ]] && pass "module lint exits 1 for an invalid module doc" \
  || fail "module lint should exit 1, got $module_status: $module_output"
[[ "$(printf '%s\n' "$module_output" | grep -c '^INVALID ')" -eq 1 ]] \
  && pass "module lint reports only the invalid module doc" \
  || fail "module lint should print one INVALID line: $module_output"
[[ "$module_output" == *"$MODULE_REPO/.mra/pkb/modules/auth.md:"* ]] \
  && pass "module lint names the invalid module document" \
  || fail "module lint omitted the module path: $module_output"
[[ "$module_output" != *"identity.md"* ]] \
  && pass "module lint skips the short identity document" \
  || fail "module lint reported the short identity document: $module_output"
[[ "$before" == "$after" ]] && pass "module lint does not modify files" \
  || fail "module lint modified a file"

direct_output=$(bash "$MRA_DIR/scripts/pkb-lint.sh" "$GOOD_REPO")
[[ "$direct_output" == *"Invalid PKB docs: 0"* ]] \
  && pass "repo-dir lint accepts a valid PKB" \
  || fail "repo-dir lint failed: $direct_output"

if [[ $errors -eq 0 ]]; then
  echo "PASS: all pkb_lint tests passed"
else
  echo "FAIL: $errors pkb_lint test(s) failed"
  exit 1
fi
