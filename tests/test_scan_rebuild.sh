#!/usr/bin/env bash
# Verify lib/scan.sh#merge_scan_results rebuilds edges and drops stale deps.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/scan.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; ((errors++)) || true; }

WS=$(mktemp -d)
mkdir -p "$WS/.collab"

cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1,
  "workspace": "smoke",
  "gitOrg": "",
  "lastScan": "1970-01-01T00:00:00Z",
  "projects": {
    "alpha": {
      "type": "node-backend",
      "port": null,
      "dockerImage": null,
      "dockerCompose": null,
      "lastCommit": "abc123",
      "deps": { "api": ["legacy-target"] },
      "consumedBy": ["legacy-source"],
      "confidence": { "legacy-target": "high" }
    },
    "beta": {
      "type": "node-frontend",
      "port": null,
      "dockerImage": null,
      "dockerCompose": null,
      "lastCommit": "def456",
      "deps": {},
      "consumedBy": [],
      "confidence": {}
    },
    "gamma": {
      "type": "node-backend",
      "port": null,
      "dockerImage": null,
      "dockerCompose": null,
      "lastCommit": "ghi789",
      "deps": {},
      "consumedBy": [],
      "confidence": {}
    }
  }
}
JSON

results=$(mktemp)
cat > "$results" <<'JSONL'
{"source":"alpha","target":"beta","type":"api","confidence":"high","scanner":"docker-compose"}
{"source":"alpha","target":"gamma","type":"api","confidence":"low","scanner":"api-calls"}
JSONL

cat > "$WS/.collab/manual-deps.json" <<'JSON'
[{"source":"beta","target":"gamma","type":"api"}]
JSON

merge_scan_results "$WS" "$results" >/dev/null

GRAPH="$WS/.collab/dep-graph.json"

if jq -e '.projects.alpha.deps.api | index("legacy-target")' "$GRAPH" >/dev/null; then
  fail_test "stale edge alpha -> legacy-target persisted after rebuild"
else
  pass_test "stale edges removed during rebuild"
fi

if jq -e '.projects.alpha.consumedBy | index("legacy-source")' "$GRAPH" >/dev/null; then
  fail_test "stale consumedBy entry persisted"
else
  pass_test "stale consumedBy cleared"
fi

if jq -e '.projects.alpha.deps.api | index("beta")' "$GRAPH" >/dev/null; then
  pass_test "scanner edge alpha -> beta applied"
else
  fail_test "scanner edge alpha -> beta missing"
fi

if jq -e '.projects.alpha.deps.api | index("gamma")' "$GRAPH" >/dev/null; then
  fail_test "low-confidence edge applied without manual confirmation"
else
  pass_test "low-confidence edge filtered out"
fi

if [[ "$(jq -r '.projects.beta.deps.api[0]' "$GRAPH")" == "gamma" ]] \
   && [[ "$(jq -r '.projects.beta.confidence.gamma' "$GRAPH")" == "high" ]]; then
  pass_test "manual override beta -> gamma applied as high"
else
  fail_test "manual override beta -> gamma not applied"
fi

if [[ "$(jq -r '.projects.gamma.consumedBy | sort | .[]' "$GRAPH" | tr '\n' ',')" == "beta," ]]; then
  pass_test "gamma.consumedBy reflects manual edge only"
else
  fail_test "gamma.consumedBy unexpected: $(jq -c '.projects.gamma.consumedBy' "$GRAPH")"
fi

if [[ "$(jq -r '.lastScan' "$GRAPH")" != "1970-01-01T00:00:00Z" ]]; then
  pass_test "lastScan timestamp updated"
else
  fail_test "lastScan not updated"
fi

if [[ "$(jq -r '.projects.alpha.type' "$GRAPH")" == "node-backend" ]] \
   && [[ "$(jq -r '.projects.alpha.lastCommit' "$GRAPH")" == "abc123" ]]; then
  pass_test "project metadata preserved across rebuild"
else
  fail_test "project metadata lost during rebuild"
fi

rm -rf "$WS" "$results"

echo ""
echo "=== scan-rebuild: $pass passed, $errors failed ==="
[[ $errors -eq 0 ]]
