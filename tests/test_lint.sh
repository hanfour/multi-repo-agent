#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/lint.sh"

errors=0
TEST_DIR=$(mktemp -d)

# Setup: create a node-frontend project with violations
mkdir -p "$TEST_DIR/.collab" "$TEST_DIR/myapp/src"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"myapp":{"type":"node-frontend","deps":{},"consumedBy":[]}}}
EOF

# Create file WITH violations
cat > "$TEST_DIR/myapp/src/bad.ts" <<'TSEOF'
interface User {
  name: string;
}

enum Status {
  Active = 1,
  Inactive = 0,
}

function processData(data: any) {
  return data.value;
}
TSEOF

# Test: lint should find violations
output=$(lint_project "$TEST_DIR" "myapp" 2>&1) || true
if [[ "$output" != *"interface"* ]]; then echo "FAIL: should detect interface"; ((errors++)); fi
if [[ "$output" != *"enum"* ]]; then echo "FAIL: should detect enum"; ((errors++)); fi
if [[ "$output" != *"any"* ]]; then echo "FAIL: should detect any"; ((errors++)); fi
if [[ "$output" != *"violation"* ]]; then echo "FAIL: should report violations"; ((errors++)); fi

# Create clean file
cat > "$TEST_DIR/myapp/src/good.ts" <<'TSEOF'
type User = {
  name: string;
};

const STATUS = {
  Active: 1,
  Inactive: 0,
} as const;

function processData(data: unknown): string {
  if (typeof data === 'string') return data;
  throw new Error('invalid');
}
TSEOF

rm "$TEST_DIR/myapp/src/bad.ts"

# Test: lint should pass
output=$(lint_project "$TEST_DIR" "myapp" 2>&1)
if [[ "$output" != *"no violations"* ]]; then echo "FAIL: clean file should have no violations"; ((errors++)); fi

# Test: non-JS project should be skipped
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test","projects":{"myapi":{"type":"rails-api","deps":{},"consumedBy":[]}}}
EOF
mkdir -p "$TEST_DIR/myapi"
output=$(lint_project "$TEST_DIR" "myapi" 2>&1)
if [[ "$output" != *"skipping"* ]]; then echo "FAIL: rails should be skipped"; ((errors++)); fi

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all lint tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
