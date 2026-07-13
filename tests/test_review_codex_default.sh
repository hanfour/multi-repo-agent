#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
WS="$TMP/ws"; BIN="$TMP/bin"; CFG="$TMP/config.json"; REC="$TMP/rec"
mkdir -p "$WS/.collab" "$WS/app" "$BIN"
export REC

cat > "$CFG" <<'JSON'
{
  "review": {
    "providerMode": "codex",
    "allowUserOverride": false,
    "models": { "claude": "sonnet", "codex": "" },
    "context": {
      "loadAgentsMd": true,
      "loadLegacyClaudeMd": true,
      "loadClaudeRules": true,
      "loadClaudeSkills": "summary",
      "loadClaudeSettingsLocal": false
    }
  },
  "loadProjectMemory": true
}
JSON
echo '{"gitOrg":"x","projects":{"app":{"type":"node","deps":{},"consumedBy":[]}}}' > "$WS/.collab/dep-graph.json"

git -C "$WS/app" init -b main >/dev/null 2>&1
git -C "$WS/app" config user.email t@t.t
git -C "$WS/app" config user.name t
printf 'one\n' > "$WS/app/a.txt"
git -C "$WS/app" add a.txt
git -C "$WS/app" commit -m init >/dev/null 2>&1
printf 'two\n' > "$WS/app/a.txt"

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "codex: $*" >> "$REC"
cat <<'OUT'
Status: APPROVED
Summary: codex default path
Notes:
  - ok
OUT
STUB
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude should not run: $*" >> "$REC"
exit 44
STUB
chmod +x "$BIN/codex" "$BIN/claude"
mkdir -p "$TMP/home/.codex"
printf '{"auth_mode":"api_key","OPENAI_API_KEY":"test-only-key"}\n' > "$TMP/home/.codex/auth.json"

if out=$(HOME="$TMP/home" MRA_REVIEW_ALLOW_UNSANDBOXED_CODEX=1 MRA_WORKSPACE="$WS" MRA_CONFIG="$CFG" MRA_CODEX_BIN="$BIN/codex" MRA_CLAUDE_BIN="$BIN/claude" \
  bash "$SCRIPT_DIR/bin/mra.sh" review app --working --no-debate 2>&1); then
  rc=0
else
  rc=$?
fi

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

[[ $rc -eq 0 ]] && pass "review command exits 0" || fail "review command failed rc=$rc: $out"
case "$out" in *"provider: codex"*) pass "logs codex provider" ;; *) fail "missing codex provider log: $out" ;; esac
case "$out" in *"codex default path"*) pass "prints codex review output" ;; *) fail "missing codex output: $out" ;; esac
rec=$(cat "$REC")
case "$rec" in *"codex:"*) pass "codex binary invoked" ;; *) fail "codex binary was not invoked: $rec" ;; esac
case "$rec" in *"claude should not run"*) fail "claude binary should not run: $rec" ;; *) pass "claude binary not invoked" ;; esac
if grep -R "review-complete: Code review for app: COMPLETED" "$WS/.collab/logs" >/dev/null 2>&1; then
  pass "review completion notification logged"
else
  fail "review completion notification was not logged"
fi

rm -rf "$TMP"
if [[ $errors -eq 0 ]]; then
  echo "PASS: codex default review smoke passed"
else
  echo "FAIL: $errors codex default smoke test(s) failed"
  exit 1
fi
