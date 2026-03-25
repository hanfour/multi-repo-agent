#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/detect-type.sh"
errors=0
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/rails-app/config"
touch "$TEST_DIR/rails-app/Gemfile" "$TEST_DIR/rails-app/config/routes.rb"
result=$(detect_project_type "$TEST_DIR/rails-app")
if [[ "$result" != "rails-api" ]]; then echo "FAIL: rails should be detected, got $result"; ((errors++)); fi
mkdir -p "$TEST_DIR/vue-app"
echo '{}' > "$TEST_DIR/vue-app/package.json"
touch "$TEST_DIR/vue-app/vite.config.ts"
result=$(detect_project_type "$TEST_DIR/vue-app")
if [[ "$result" != "node-frontend" ]]; then echo "FAIL: node-frontend should be detected, got $result"; ((errors++)); fi
mkdir -p "$TEST_DIR/mystery"
result=$(detect_project_type "$TEST_DIR/mystery")
if [[ "$result" != "unknown" ]]; then echo "FAIL: unknown should be detected, got $result"; ((errors++)); fi
rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all detect-type tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
