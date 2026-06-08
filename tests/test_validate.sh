#!/usr/bin/env bash
# Verify lib/validate.sh detects valid and malformed .collab/*.json files.
set -euo pipefail

MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$MRA_DIR/lib/colors.sh"
source "$MRA_DIR/lib/validate.sh"

errors=0
pass=0
pass_test() { echo "PASS: $1"; ((pass++)) || true; }
fail_test() { echo "FAIL: $1"; errors=$((errors+1)) || true; }

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

# Files carrying a top-level $schema (for IDE hints) must still validate.
cat > "$WS/.collab/repos.json" <<'JSON'
{
  "$schema": "https://hanfour.github.io/multi-repo-agent/schemas/repos.schema.json",
  "repos": [{ "name": "alpha", "clone": true, "branch": "main", "description": "", "archived": false }]
}
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  pass_test "repos.json with \$schema property passes validation"
else
  fail_test "repos.json with \$schema property incorrectly rejected"
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

# --- TM-003: identifier regex enforcement on .collab/* keys/values ---

# Helpers: restore each file to a known-good baseline so the assertions
# below isolate the field we are deliberately corrupting.
_restore_good_dep_graph() {
  cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now",
  "projects": { "alpha": { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": [], "confidence": {} } }
}
JSON
}
_restore_good_repos() {
  cat > "$WS/.collab/repos.json" <<'JSON'
{ "repos": [{ "name": "alpha", "clone": true }] }
JSON
}
_restore_good_db() {
  cat > "$WS/.collab/db.json" <<'JSON'
{ "databases": { "mysql": { "engine": "mysql", "schemas": {} } } }
JSON
}
_restore_good_manual_deps() {
  cat > "$WS/.collab/manual-deps.json" <<'JSON'
[{ "source": "alpha", "target": "beta" }]
JSON
}
_restore_all() { _restore_good_dep_graph; _restore_good_repos; _restore_good_db; _restore_good_manual_deps; }

# Sanity: with all four files good, validation must now pass.
_restore_all
if validate_collab_files "$WS" 2>/dev/null; then
  pass_test "baseline restored .collab passes validation"
else
  fail_test "baseline .collab incorrectly rejected"
fi

# Path-traversal project key
_restore_all
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now",
  "projects": { "../escape": { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": [], "confidence": {} } }
}
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "dep-graph project key '../escape' should be rejected"
else
  pass_test "dep-graph rejected project key with traversal"
fi

# Slash in project key
_restore_all
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now",
  "projects": { "a/b": { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": [], "confidence": {} } }
}
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "dep-graph project key 'a/b' should be rejected"
else
  pass_test "dep-graph rejected project key with slash"
fi

# Unsafe consumer name inside consumedBy
_restore_all
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now",
  "projects": { "alpha": { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": ["../etc"], "confidence": {} } }
}
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "dep-graph consumedBy with traversal should be rejected"
else
  pass_test "dep-graph rejected unsafe consumedBy entry"
fi

# repos.json: unsafe name
_restore_all
cat > "$WS/.collab/repos.json" <<'JSON'
{ "repos": [{ "name": "../escape", "clone": true }] }
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "repos.json unsafe name should be rejected"
else
  pass_test "repos.json rejected unsafe name"
fi

# db.json: unsafe database key
_restore_all
cat > "$WS/.collab/db.json" <<'JSON'
{ "databases": { "../escape": { "engine": "mysql", "schemas": {} } } }
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "db.json unsafe database name should be rejected"
else
  pass_test "db.json rejected unsafe database name"
fi

# db.json: unsafe schema key (SQL-identifier domain)
_restore_all
cat > "$WS/.collab/db.json" <<'JSON'
{ "databases": { "mysql": { "engine": "mysql", "schemas": { "drop;table": { "source": "x", "usedBy": [] } } } } }
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "db.json unsafe schema name should be rejected"
else
  pass_test "db.json rejected unsafe schema name"
fi

# manual-deps: unsafe source
_restore_all
cat > "$WS/.collab/manual-deps.json" <<'JSON'
[{ "source": "../etc", "target": "alpha" }]
JSON
if validate_collab_files "$WS" 2>/dev/null; then
  fail_test "manual-deps unsafe source should be rejected"
else
  pass_test "manual-deps rejected unsafe source"
fi

# --- TM-003: deps.sh uses --arg, no jq path interpolation ---
# We exercise get_project_consumers with a project name that contains a
# double quote. If deps.sh interpolated $project into the jq filter the
# shell would either explode or silently return empty; with --arg it
# returns empty cleanly (no entry matches the malicious key).
source "$MRA_DIR/lib/deps.sh"
cat > "$WS/.collab/dep-graph.json" <<'JSON'
{
  "version": 1, "workspace": "x", "gitOrg": "", "lastScan": "now",
  "projects": {
    "alpha": { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": ["beta"], "confidence": {} },
    "beta":  { "type": "x", "port": null, "dockerImage": null, "dockerCompose": null, "lastCommit": "z", "deps": {}, "consumedBy": [],       "confidence": {} }
  }
}
JSON
out=$(get_project_consumers 'alpha' "$WS/.collab/dep-graph.json" 2>/dev/null)
if [[ "$out" == "beta" ]]; then
  pass_test "get_project_consumers returns correct value"
else
  fail_test "get_project_consumers expected 'beta', got '$out'"
fi
# Malicious project name: the old `.projects."$project"` interpolation
# would produce `.projects."alpha"; -- bad"` -> jq parse error. With
# --arg the call returns empty cleanly.
out=$(get_project_consumers 'alpha"; -- bad' "$WS/.collab/dep-graph.json" 2>/dev/null || true)
if [[ -z "$out" ]]; then
  pass_test "get_project_consumers safely handles injected name"
else
  fail_test "get_project_consumers leaked output for injected name: '$out'"
fi

rm -rf "$WS" "$JSONL"

echo ""
echo "=== validate: $pass passed, $errors failed ==="
[[ $errors -eq 0 ]]
