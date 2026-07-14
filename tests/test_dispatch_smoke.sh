#!/usr/bin/env bash
# Dispatch smoke net: exercises every top-level command's entry (routing + first
# arg-parse + exit code) end-to-end through bin/mra.sh, with external tools stubbed
# and in an empty workspace so nothing does real work or hangs. Asserts the
# normalized (exit + first 3 lines, ANSI/paths stripped) output matches the
# committed golden — catching any routing/arg-parse/exit-code regression from the
# dispatch-extraction refactor (#16).
set -uo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$MRA_DIR/tests/fixtures/dispatch-smoke.golden"

# All top-level commands EXCEPT interactive/long-running TUIs (dashboard, watch).
CMDS="alias analyze ask branch ci clean config cost db deps dev diff doctor
eval-review export federation graph init integration lint log notify open plan
prd prd-issues prd-render prd-scaffold review rollback scan setup snapshot
snapshots status sync template test test-audit trust"

run_all() {
  local ws; ws=$(mktemp -d)
  mkdir -p "$ws/.collab" "$ws/stub/bin"
  echo '{"projects":{},"gitOrg":"acme"}' > "$ws/.collab/dep-graph.json"
  local t
  for t in claude codex docker gh; do
    printf '#!/usr/bin/env bash\necho "[stub:%s] $*"\nexit 0\n' "$t" > "$ws/stub/bin/$t"
    chmod +x "$ws/stub/bin/$t"
  done
  local c out ec
  for c in $CMDS; do
    out=$(cd "$ws" && PATH="$ws/stub/bin:$PATH" MRA_WORKSPACE="$ws" \
          MRA_CLAUDE_BIN="$ws/stub/bin/claude" MRA_CODEX_BIN="$ws/stub/bin/codex" \
          LC_ALL=C LANG=C \
          perl -e 'alarm 15; exec @ARGV' bash "$MRA_DIR/bin/mra.sh" "$c" --help </dev/null 2>&1)
    ec=$?
    # normalize: strip ANSI, replace dir/ws with placeholders, first 3 lines
    printf '=== %s (exit=%s) ===\n%s\n' "$c" "$ec" \
      "$(printf '%s' "$out" | sed -E $'s/\x1b\\[[0-9;]*m//g' | sed "s|$MRA_DIR|<DIR>|g; s|$ws|<WS>|g" | head -3)"
  done
  chmod -R u+w "$ws" 2>/dev/null || true; rm -rf "$ws"
}

live=$(run_all)
if [[ "${1:-}" == "--regen" ]]; then
  printf '%s\n' "$live" > "$GOLDEN"
  echo "regenerated $GOLDEN"; exit 0
fi
if diff <(printf '%s\n' "$live") "$GOLDEN" >/dev/null; then
  echo "PASS: dispatch smoke net matches golden ($(echo "$CMDS" | wc -w | tr -d ' ') commands)"
else
  echo "FAIL: dispatch behaviour changed vs golden:"; diff <(printf '%s\n' "$live") "$GOLDEN"; exit 1
fi
