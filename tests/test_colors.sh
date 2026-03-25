#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"

errors=0

output=$(log_progress "testing progress")
if [[ -z "$output" ]]; then echo "FAIL: log_progress empty"; ((errors++)); fi

output=$(log_success "testing success")
if [[ -z "$output" ]]; then echo "FAIL: log_success empty"; ((errors++)); fi

output=$(log_info "testing info")
if [[ -z "$output" ]]; then echo "FAIL: log_info empty"; ((errors++)); fi

output=$(log_warn "testing warn")
if [[ -z "$output" ]]; then echo "FAIL: log_warn empty"; ((errors++)); fi

output=$(log_error "testing error")
if [[ -z "$output" ]]; then echo "FAIL: log_error empty"; ((errors++)); fi

output=$(log_progress "hello" "test")
if [[ "$output" != *"[test]"* ]]; then echo "FAIL: tag not found"; ((errors++)); fi
if [[ "$output" != *"hello"* ]]; then echo "FAIL: message not found"; ((errors++)); fi

if [[ $errors -eq 0 ]]; then
  echo "PASS: all color tests passed"
else
  echo "FAIL: $errors tests failed"
  exit 1
fi
