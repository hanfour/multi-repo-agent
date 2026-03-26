#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/deps.sh"
source "$SCRIPT_DIR/lib/federation.sh"

errors=0
TEST_DIR=$(mktemp -d)

# Setup workspace with a rails project
mkdir -p "$TEST_DIR/.collab"
cat > "$TEST_DIR/.collab/dep-graph.json" <<'EOF'
{"version":1,"workspace":"test-ws","projects":{"myapi":{"type":"rails-api","deps":{},"consumedBy":[]}}}
EOF

mkdir -p "$TEST_DIR/myapi/config"
cd "$TEST_DIR/myapi" && git init -b main . &>/dev/null
cat > config/routes.rb <<'ROUTES'
Rails.application.routes.draw do
  get '/users', to: 'users#index'
  post '/users', to: 'users#create'
  resources :orders
end
ROUTES
git add -A && git commit -m "init" &>/dev/null

# Test publish
publish_contract "$TEST_DIR" "myapi" 2>/dev/null
contract_file="$TEST_DIR/.collab/contracts/published/myapi.json"
if [[ ! -f "$contract_file" ]]; then
  echo "FAIL: contract file not created"; ((errors++))
else
  ep_count=$(jq '.endpointCount' "$contract_file")
  if [[ "$ep_count" -lt 2 ]]; then
    echo "FAIL: should have at least 2 endpoints, got $ep_count"; ((errors++))
  fi
  schema=$(jq -r '.schema' "$contract_file")
  if [[ "$schema" != "mra-contract-v1" ]]; then
    echo "FAIL: schema should be mra-contract-v1, got $schema"; ((errors++))
  fi
fi

# Test subscribe (local file)
subscribe_contract "$TEST_DIR" "$contract_file" 2>/dev/null
subs_file="$TEST_DIR/.collab/contracts/subscriptions.json"
if [[ ! -f "$subs_file" ]]; then
  echo "FAIL: subscriptions file not created"; ((errors++))
fi
sub_count=$(jq 'length' "$subs_file")
if [[ "$sub_count" != "1" ]]; then
  echo "FAIL: should have 1 subscription, got $sub_count"; ((errors++))
fi

# Test verify
output=$(verify_contracts "$TEST_DIR" 2>&1)
if [[ "$output" != *"passed"* ]]; then
  echo "FAIL: verify should show passed"; ((errors++))
fi

# Test list
output=$(list_contracts "$TEST_DIR" 2>&1)
if [[ "$output" != *"myapi"* ]]; then
  echo "FAIL: list should show myapi"; ((errors++))
fi

rm -rf "$TEST_DIR"
if [[ $errors -eq 0 ]]; then echo "PASS: all federation tests passed"
else echo "FAIL: $errors tests failed"; exit 1; fi
