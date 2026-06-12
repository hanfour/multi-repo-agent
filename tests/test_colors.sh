#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

errors=0

output=$(log_progress "testing progress")
if [[ -z "$output" ]]; then echo "FAIL: log_progress empty"; errors=$((errors+1)); fi

output=$(log_success "testing success")
if [[ -z "$output" ]]; then echo "FAIL: log_success empty"; errors=$((errors+1)); fi

output=$(log_info "testing info")
if [[ -z "$output" ]]; then echo "FAIL: log_info empty"; errors=$((errors+1)); fi

output=$(log_warn "testing warn")
if [[ -z "$output" ]]; then echo "FAIL: log_warn empty"; errors=$((errors+1)); fi

# log_error must write to stderr, never stdout: many functions return
# values via stdout command substitution, and an error printed to stdout
# would be swallowed into the captured value instead of shown.
output=$(log_error "testing error" 2>/dev/null)
if [[ -n "$output" ]]; then echo "FAIL: log_error leaked to stdout"; errors=$((errors+1)); fi

output=$(log_error "testing error" 2>&1 >/dev/null)
if [[ "$output" != *"testing error"* ]]; then echo "FAIL: log_error missing on stderr"; errors=$((errors+1)); fi

output=$(log_progress "hello" "test")
if [[ "$output" != *"[test]"* ]]; then echo "FAIL: tag not found"; errors=$((errors+1)); fi
if [[ "$output" != *"hello"* ]]; then echo "FAIL: message not found"; errors=$((errors+1)); fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all color tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
