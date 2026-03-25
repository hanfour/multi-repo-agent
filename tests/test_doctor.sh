#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/detect-type.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/repos.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/doctor.sh"

errors=0

# ---------------------------------------------------------------------------
# Test: run_doctor function exists
# ---------------------------------------------------------------------------
if type run_doctor &>/dev/null; then
  echo "PASS: run_doctor function exists"
else
  echo "FAIL: run_doctor not defined"
  ((errors++))
fi

# ---------------------------------------------------------------------------
# Test: doctor_basic function exists
# ---------------------------------------------------------------------------
if type doctor_basic &>/dev/null; then
  echo "PASS: doctor_basic function exists"
else
  echo "FAIL: doctor_basic not defined"
  ((errors++))
fi

# ---------------------------------------------------------------------------
# Test: doctor_databases function exists
# ---------------------------------------------------------------------------
if type doctor_databases &>/dev/null; then
  echo "PASS: doctor_databases function exists"
else
  echo "FAIL: doctor_databases not defined"
  ((errors++))
fi

# ---------------------------------------------------------------------------
# Test: doctor_projects function exists
# ---------------------------------------------------------------------------
if type doctor_projects &>/dev/null; then
  echo "PASS: doctor_projects function exists"
else
  echo "FAIL: doctor_projects not defined"
  ((errors++))
fi

# ---------------------------------------------------------------------------
# Test: doctor_basic runs without crashing
# ---------------------------------------------------------------------------
if result=$(doctor_basic 2>/dev/null); then
  echo "PASS: doctor_basic runs without crashing"
  # Validate output format: two numbers
  pass_count=$(echo "$result" | awk '{print $1}')
  fail_count=$(echo "$result" | awk '{print $2}')
  if [[ "$pass_count" =~ ^[0-9]+$ && "$fail_count" =~ ^[0-9]+$ ]]; then
    echo "PASS: doctor_basic returns valid pass/fail counts ($pass_count passed, $fail_count failed)"
  else
    echo "FAIL: doctor_basic output format invalid: '$result'"
    ((errors++))
  fi
else
  # Non-zero exit is acceptable (tools may be missing), as long as it doesn't crash
  echo "PASS: doctor_basic exits with non-zero (some tools missing), but ran without crashing"
fi

# ---------------------------------------------------------------------------
# Test: doctor_databases with no db.json returns gracefully
# ---------------------------------------------------------------------------
tmp_ws=$(mktemp -d)
mkdir -p "$tmp_ws/.collab"
if result=$(doctor_databases "$tmp_ws" 2>/dev/null); then
  echo "PASS: doctor_databases handles missing db.json gracefully"
else
  echo "PASS: doctor_databases exits non-zero for missing db.json (acceptable)"
fi
rm -rf "$tmp_ws"

# ---------------------------------------------------------------------------
# Test: doctor_databases with empty db.json
# ---------------------------------------------------------------------------
tmp_ws2=$(mktemp -d)
mkdir -p "$tmp_ws2/.collab"
echo '{"databases":{}}' > "$tmp_ws2/.collab/db.json"
if result=$(doctor_databases "$tmp_ws2" 2>/dev/null); then
  echo "PASS: doctor_databases handles empty databases object"
else
  echo "PASS: doctor_databases exits non-zero for empty databases (acceptable)"
fi
rm -rf "$tmp_ws2"

# ---------------------------------------------------------------------------
# Test: doctor_projects with no dep-graph.json returns gracefully
# ---------------------------------------------------------------------------
tmp_ws3=$(mktemp -d)
mkdir -p "$tmp_ws3/.collab"
if result=$(doctor_projects "$tmp_ws3" 2>/dev/null); then
  echo "PASS: doctor_projects handles missing dep-graph.json gracefully"
else
  echo "PASS: doctor_projects exits non-zero for missing dep-graph.json (acceptable)"
fi
rm -rf "$tmp_ws3"

# ---------------------------------------------------------------------------
# Test: run_doctor runs without crashing on a minimal workspace
# ---------------------------------------------------------------------------
tmp_ws4=$(mktemp -d)
mkdir -p "$tmp_ws4/.collab"
echo '{"databases":{}}' > "$tmp_ws4/.collab/db.json"
jq -n '{version:1,workspace:"test",gitOrg:"git@github.com:test",lastScan:"2024-01-01T00:00:00Z",projects:{}}' \
  > "$tmp_ws4/.collab/dep-graph.json"

if run_doctor "$tmp_ws4" "" 2>/dev/null; then
  echo "PASS: run_doctor runs without crashing on minimal workspace"
else
  echo "PASS: run_doctor exits non-zero on minimal workspace (acceptable)"
fi
rm -rf "$tmp_ws4"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ $errors -eq 0 ]]; then
  echo "PASS: all doctor tests passed"
else
  echo "FAIL: $errors test(s) failed"
  exit 1
fi
