#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/db.sh"

errors=0

# ---------------------------------------------------------------------------
# Test: get_db_json_path returns correct path
# ---------------------------------------------------------------------------
result=$(get_db_json_path "/tmp/fake-workspace")
expected="/tmp/fake-workspace/.collab/db.json"
if [[ "$result" == "$expected" ]]; then
  echo "PASS: get_db_json_path returns correct path"
else
  echo "FAIL: get_db_json_path expected '$expected', got '$result'"
  ((errors++))
fi

# ---------------------------------------------------------------------------
# Test: db_json_exists returns false for nonexistent path
# ---------------------------------------------------------------------------
if ! db_json_exists "/tmp/nonexistent-workspace-$$"; then
  echo "PASS: db_json_exists returns false for nonexistent path"
else
  echo "FAIL: db_json_exists should return false for nonexistent path"
  ((errors++))
fi

# ---------------------------------------------------------------------------
# Test: db_json_exists returns true when file exists
# ---------------------------------------------------------------------------
tmp_ws=$(mktemp -d)
mkdir -p "$tmp_ws/.collab"
echo '{"databases":{}}' > "$tmp_ws/.collab/db.json"
if db_json_exists "$tmp_ws"; then
  echo "PASS: db_json_exists returns true when file exists"
else
  echo "FAIL: db_json_exists should return true when file exists"
  ((errors++))
fi
rm -rf "$tmp_ws"

# ---------------------------------------------------------------------------
# Test: decompress_dump with a plain .sql file
# ---------------------------------------------------------------------------
tmp_sql=$(mktemp /tmp/mra_test_XXXXXX.sql)
echo "CREATE TABLE test (id INT);" > "$tmp_sql"

result=$(decompress_dump "$tmp_sql")
if [[ "$result" == "$tmp_sql" ]]; then
  echo "PASS: decompress_dump returns original path for .sql file"
else
  echo "FAIL: decompress_dump expected '$tmp_sql', got '$result'"
  ((errors++))
fi

# Verify the returned file is readable and correct
if [[ -f "$result" ]] && grep -q "CREATE TABLE" "$result"; then
  echo "PASS: decompress_dump .sql file content is correct"
else
  echo "FAIL: decompress_dump .sql file content mismatch"
  ((errors++))
fi

rm -f "$tmp_sql"

# ---------------------------------------------------------------------------
# Test: decompress_dump fails gracefully for nonexistent file
# ---------------------------------------------------------------------------
if decompress_dump "/tmp/nonexistent_file_$$.sql" 2>/dev/null; then
  echo "FAIL: decompress_dump should fail for nonexistent file"
  ((errors++))
else
  echo "PASS: decompress_dump returns error for nonexistent file"
fi

# ---------------------------------------------------------------------------
# Test: decompress_dump with .sql.gz file
# ---------------------------------------------------------------------------
if command -v gzip &>/dev/null; then
  tmp_sql2=$(mktemp /tmp/mra_test_XXXXXX.sql)
  echo "SELECT 1;" > "$tmp_sql2"
  gzip -c "$tmp_sql2" > "${tmp_sql2}.gz"
  rm -f "$tmp_sql2"

  result=$(decompress_dump "${tmp_sql2}.gz")
  if [[ -f "$result" ]] && grep -q "SELECT 1;" "$result"; then
    echo "PASS: decompress_dump handles .sql.gz correctly"
  else
    echo "FAIL: decompress_dump .sql.gz decompression failed"
    ((errors++))
  fi
  rm -f "${tmp_sql2}.gz" "$result" 2>/dev/null || true
else
  echo "SKIP: gzip not available, skipping .sql.gz test"
fi

# ---------------------------------------------------------------------------
# Test: decompress_dump with .sql.bz2 file
# ---------------------------------------------------------------------------
if command -v bzip2 &>/dev/null; then
  tmp_sql3=$(mktemp /tmp/mra_test_XXXXXX.sql)
  echo "SELECT 2;" > "$tmp_sql3"
  bzip2 -c "$tmp_sql3" > "${tmp_sql3}.bz2"
  rm -f "$tmp_sql3"

  result=$(decompress_dump "${tmp_sql3}.bz2")
  if [[ -f "$result" ]] && grep -q "SELECT 2;" "$result"; then
    echo "PASS: decompress_dump handles .sql.bz2 correctly"
  else
    echo "FAIL: decompress_dump .sql.bz2 decompression failed"
    ((errors++))
  fi
  rm -f "${tmp_sql3}.bz2" "$result" 2>/dev/null || true
else
  echo "SKIP: bzip2 not available, skipping .sql.bz2 test"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ $errors -eq 0 ]]; then
  echo "PASS: all db tests passed"
else
  echo "FAIL: $errors test(s) failed"
  exit 1
fi
