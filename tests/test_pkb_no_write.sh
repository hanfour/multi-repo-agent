#!/usr/bin/env bash
# PKB prompt calls must return documents and disallow file-writing tools.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

BIN="$TEST_TMP/bin"
RECORD_DIR="$TEST_TMP/records"
mkdir -p "$BIN" "$RECORD_DIR"
export CLAUDE_RECORD_DIR="$RECORD_DIR"

cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
for existing in "$CLAUDE_RECORD_DIR"/call-*.argv; do
  [[ -e "$existing" ]] && count=$((count + 1))
done
record="$CLAUDE_RECORD_DIR/call-$(printf '%03d' "$((count + 1))").argv"
printf '%s\0' "$@" > "$record"
printf '# Generated document\n\nThis sufficiently detailed generated document is valid output for testing all PKB document prompt calls.\n'
STUB
chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"

source "$SCRIPT_DIR/lib/pkb-cache.sh"
source "$SCRIPT_DIR/lib/pkb-prompts.sh"
unset MRA_CLAUDE_DISALLOWED_TOOLS

errors=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; errors=$((errors + 1)); }
log_info() { :; }
log_warn() { :; }

PROJECT="$TEST_TMP/project"
PKB="$TEST_TMP/pkb"
mkdir -p "$PROJECT/src/modules/auth" "$PKB/modules"
printf 'module source\n' > "$PROJECT/src/modules/auth/index.ts"
printf '{"version":2}\n' > "$PKB/meta.json"

_pkb_generate_sitemap "sample-project" "$PROJECT" "app" "" "haiku" >/dev/null
_pkb_generate_architecture "sample-project" "$PROJECT" "app" "" "haiku" >/dev/null
_pkb_generate_conventions "sample-project" "$PROJECT" "app" "" "haiku" >/dev/null
_pkb_generate_api_surface "sample-project" "$PROJECT" "app" "" "haiku" >/dev/null
_pkb_generate_modules "sample-project" "$PROJECT" "app" "" "haiku" "$PKB" >/dev/null 2>&1
_pkb_update_one_module "$PROJECT" "auth" "$PROJECT/src/modules/auth" "# Module: auth" "src/modules/auth/index.ts" "" "haiku" >/dev/null
SITEMAP="$TEST_TMP/sitemap.md"
printf '# Sitemap: sample-project\n\nExisting content.\n' > "$SITEMAP"
_pkb_update_sitemap "sample-project" "$PROJECT" "$SITEMAP" "src/modules/auth/index.ts" "" "haiku"

expected_instruction='Return the complete document as your final reply, starting with its first heading. Do not create, write or edit any files, and do not describe what you are doing — the reply itself is saved as the document.'
expected_calls=7
prompt_calls=$(grep -c -- 'claude -p' "$SCRIPT_DIR/lib/pkb-prompts.sh")
[[ "$prompt_calls" -eq "$expected_calls" ]] \
  && pass "all $expected_calls claude -p call sites are exercised" \
  || fail "found $prompt_calls claude -p call sites; test exercises $expected_calls"

shopt -s nullglob
recorded_calls=("$RECORD_DIR"/call-*.argv)
[[ "${#recorded_calls[@]}" -eq "$expected_calls" ]] \
  && pass "recorded all $expected_calls claude calls" \
  || fail "recorded ${#recorded_calls[@]} claude calls; expected $expected_calls"
[[ "${#recorded_calls[@]}" -eq "$prompt_calls" ]] \
  && pass "every claude -p call site ran once" \
  || fail "recorded call count does not match claude -p call sites"

for record in "${recorded_calls[@]}"; do
  argv=()
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$record"

  has_disallowed_tools=false
  for ((i = 0; i < ${#argv[@]}; i++)); do
    if [[ "${argv[$i]}" == "--disallowedTools" && $((i + 1)) -lt ${#argv[@]} ]]; then
      tools_value="${argv[$((i + 1))]}"
      if [[ "$tools_value" == *Write* && "$tools_value" == *Edit* && "$tools_value" == *NotebookEdit* ]]; then
        has_disallowed_tools=true
      fi
    fi
  done
  [[ "$has_disallowed_tools" == true ]] \
    && pass "$(basename "$record"): disallowed file-writing tools passed" \
    || fail "$(basename "$record"): missing --disallowedTools value with Write, Edit and NotebookEdit"

  has_instruction=false
  if [[ ${#argv[@]} -ge 2 && "${argv[0]}" == "-p" && "${argv[1]}" == *"$expected_instruction"* ]]; then
    has_instruction=true
  fi
  [[ "$has_instruction" == true ]] \
    && pass "$(basename "$record"): document-return instruction is present" \
    || fail "$(basename "$record"): document-return instruction missing from prompt"
done

if [[ $errors -eq 0 ]]; then
  echo "PASS: PKB no-write prompt tests passed"
else
  echo "FAIL: $errors PKB no-write prompt test(s) failed"
  exit 1
fi
