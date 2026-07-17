#!/usr/bin/env bash
# Review structural context (issue #25): a capped, best-effort prompt section
# combining symbol-level blast radius (codegraph explore over the changed
# files) and transitively affected test files. Any failure or absence of
# codegraph yields EMPTY output so the review prompt stays byte-identical.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/structural.sh"

errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

MRA_CONFIG=$(mktemp)
echo '{"configVersion":2}' > "$MRA_CONFIG"
export MRA_CONFIG

PROJ=$(mktemp -d); mkdir -p "$PROJ/.codegraph"
BIN=$(mktemp -d)
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  files)    echo '[{"path":"src/auth.ts","nodeCount":5},{"path":"src/session.ts","nodeCount":3},{"path":"config.yml","nodeCount":0}]' ;;
  explore)  echo "SYMBOL handleLogin (src/auth.ts) ← called by SessionController.create" ;;
  affected) cat >/dev/null; printf 'tests/auth.test.ts\ntests/session.test.ts\n' ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"

CHANGED=$'src/auth.ts\nsrc/session.ts'

# --- 1. Section combines blast radius + affected tests ---
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "$CHANGED")
echo "$out" | grep -q "Structural Context" && pass "section header present" || fail "header missing: $(echo "$out" | head -2)"
echo "$out" | grep -q "handleLogin" && pass "blast radius content present" || fail "blast radius missing"
echo "$out" | grep -q "tests/auth.test.ts" && pass "affected tests present" || fail "affected tests missing"

# --- 2. Capped at MRA_REVIEW_STRUCTURAL_MAX_BYTES ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  explore) head -c 40000 /dev/zero | tr '\0' 'x' ;;
  affected) cat >/dev/null ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" MRA_REVIEW_STRUCTURAL_MAX_BYTES=2048 structural_review_context "$PROJ" "$CHANGED")
[[ ${#out} -le 2048 ]] && pass "section capped (${#out} bytes)" || fail "cap exceeded: ${#out} bytes"

# --- 3. Best-effort: failing CLI yields empty, never an error ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "failing CLI yields empty section" || fail "failing CLI leaked output: $out"

# --- 4. No index / no CLI / empty change set: empty (byte-identical prompt) ---
NOIDX=$(mktemp -d)
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$NOIDX" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "no .codegraph/: empty" || fail "no index leaked: $out"
out=$(MRA_CODEGRAPH_BIN="$BIN/nonexistent" structural_review_context "$PROJ" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "no CLI: empty" || fail "no CLI leaked: $out"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "" 2>&1) || true
[[ -z "$out" ]] && pass "empty change set: empty" || fail "empty changes leaked: $out"

# --- 5. Out-of-index diff yields empty (no loose-match noise injection) ---
# Live finding from the mra-repo ablation: codegraph cannot parse bash, so a
# bash diff got 8KB of loosely-matched TS symbols. If the graph has symbols
# for NONE of the changed files, the section must be empty.
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  files)    echo '[{"path":"other/unrelated.ts","nodeCount":9},{"path":"lib/review.sh","nodeCount":0}]' ;;
  explore)  echo "LOOSE-MATCH noise that must not be injected" ;;
  affected) cat >/dev/null; echo "tests/loose.test.ts" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" $'lib/review.sh\nlib/pkb.sh' 2>&1) || true
[[ -z "$out" ]] && pass "no indexed changed file (incl. nodeCount=0): empty section" || fail "out-of-index diff leaked: $(echo "$out" | head -2)"

# --- 5b. Large index listing must not silently break the gate ---
# Live finding #2 (super-dsp-2.0, 12k nodes): the files listing exceeded the
# generic 64KB output cap, the truncated JSON failed to parse, and the gate
# fail-opened on exactly the repos where scoping matters. A large but valid
# listing that is DISJOINT from the diff must still yield an empty section.
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  files)
    printf '['
    for i in $(seq 1 900); do
      printf '{"path":"other/very/long/path/to/an/indexed/source/file-number-%04d.ts","nodeCount":7},' "$i"
    done
    printf '{"path":"other/last.ts","nodeCount":1}]'
    ;;
  explore)  echo "LOOSE-MATCH noise that must not be injected" ;;
  affected) cat >/dev/null; echo "tests/loose.test.ts" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "$CHANGED" 2>&1) || true
[[ -z "$out" ]] && pass "large (>64KB) index listing: gate still engages, empty section" || fail "large listing broke the gate (fail-open leak): $(echo "$out" | head -2)"

# --- 6. files-listing failure fails OPEN (legacy behaviour preserved) ---
cat > "$BIN/codegraph" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  files)    exit 3 ;;
  explore)  echo "SYMBOL handleLogin (src/auth.ts)" ;;
  affected) cat >/dev/null; echo "tests/auth.test.ts" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/codegraph"
out=$(MRA_CODEGRAPH_BIN="$BIN/codegraph" structural_review_context "$PROJ" "$CHANGED")
echo "$out" | grep -q "handleLogin" && pass "files-listing failure fails open (section kept)" || fail "fail-open broken: $(echo "$out" | head -2)"

# --- 7. review.sh wires the section into the review context ---
grep -q "structural_review_context" "$SCRIPT_DIR/lib/review.sh" \
  && pass "review.sh consumes structural_review_context" \
  || fail "review.sh does not reference structural_review_context"

rm -rf "$PROJ" "$NOIDX" "$BIN"; rm -f "$MRA_CONFIG"
if [[ $errors -eq 0 ]]; then
  echo "PASS: review structural context tests passed"
else
  echo "FAIL: $errors review structural test(s) failed"
  exit 1
fi
