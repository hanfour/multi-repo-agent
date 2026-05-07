#!/usr/bin/env bash
# Verify lib/validate.sh detects valid and malformed .collab/*.json files.
set -uo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/validate.sh"

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
  "lastScan": "2026-01-01T00:00:00Z",
  "projects": {
    "alpha": {
      "type": "node-backend",
      "port": null,
      "dockerImage": null,
      "dockerCompose": null,
      "lastCommit": "abc",
      "deps": {},
      "consumedBy": [],
      "confidence": {}
    }
  }
}
JSON

cat > "$WS/.collab/repos.json" <<'JSON'
{ "repos": [{ "name": "alpha", "clone": true, "branch": "main", "description": "", "archived": false }] }
JSON

cat > "$WS/.collab/db.json" <<'JSON'
{
  "databases": {
    "mysql": {
      "engine": "mysql",
      "version": "5.7",
      "platform": "linux/amd64",
      "port": 3306,
      "password": "synthetic",
      "schemas": { "alpha_db": { "source": "./dumps/alpha.sql.bz2", "usedBy": ["alpha"] } }
    }
  }
}
JSON

cat > "$WS/.collab/manual-deps.json" <<'JSON'
[{ "source": "alpha", "target": "beta", "type": "api" }]
JSON

if validate_collab_files "$WS" 2>/dev/null; then
  pass_test "all valid .collab/*.json pass validation"
else
  fail_test "valid .collab/*.json incorrectly rejected"
fi

# 1. Corrupt dep-graph (missing projects)
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{ "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now" }
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "missing projects key not detected"
else
  pass_test "missing projects key detected"
fi

# Restore valid dep-graph
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now",
  "projects": { "a": { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": [], "confidence": {} } }
}
JSON

# 2. Corrupt db.json (engine not in enum)
cat > "$WS/.collab/db.json" <<'JSON'
{ "databases": { "x": { "engine": "sqlite", "schemas": {} } } }
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "invalid engine 'sqlite' not detected"
else
  pass_test "invalid db engine detected"
fi

# Restore valid db.json
cat > "$WS/.collab/db.json" <<'JSON'
{ "databases": { "mysql": { "engine": "mysql", "schemas": {} } } }
JSON

# 3. Corrupt manual-deps (missing target)
cat > "$WS/.collab/manual-deps.json" <<'JSON'
[{ "source": "a" }]
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "manual-deps missing target not detected"
else
  pass_test "manual-deps missing target detected"
fi

# 4. Scanner JSONL: bad confidence value
JSONL=$(mktemp)
cat > "$JSONL" <<'JSONL'
{"source":"a","target":"b","type":"api","confidence":"high","scanner":"x"}
{"source":"a","target":"c","type":"api","confidence":"banana","scanner":"x"}
JSONL
if validate_scanner_jsonl "$JSONL" 2>/dev/null; then
  fail_test "scanner JSONL bad confidence not detected"
else
  pass_test "scanner JSONL bad confidence detected"
fi

# 5. Scanner JSONL all-good lines
cat > "$JSONL" <<'JSONL'
{"source":"a","target":"b","type":"api","confidence":"high","scanner":"x"}
{"source":"a","target":"c","type":"infra","confidence":"low","scanner":"y"}
JSONL
if validate_scanner_jsonl "$JSONL" 2>/dev/null; then
  pass_test "scanner JSONL valid records pass"
else
  fail_test "valid scanner JSONL incorrectly rejected"
fi

rm -rf "$WS" "$JSONL"

echo ""
echo "=== validate: $pass passed, $errors failed ==="
[[ $errors -eq 0 ]]
