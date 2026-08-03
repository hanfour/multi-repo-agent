#!/usr/bin/env bash
# resolve_compose_config must return the compose file and service name intact,
# whatever the workspace path contains.
#
# It used to encode the pair as "file|service" and callers split it with
# ${config%%|*} / ${config##*|}. A `|` anywhere in the path truncated the file
# and turned the service name into a path fragment — and the trust gate in
# lib/docker-exec.sh was then evaluated against the truncated path, while
# `docker compose -f` failed with a "no such file" that named the wrong cause
# (#41).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/docker-exec.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Build a workspace containing one project with a compose file.
make_workspace() {
  local ws="$1" project="$2"
  mkdir -p "$ws/$project"
  cat > "$ws/$project/docker-compose.yml" <<YAML
services:
  web:
    build:
      context: ./$project
YAML
  printf '%s' "$ws/$project/docker-compose.yml"
}

check() {
  local label="$1" ws="$2" project="$3" want_file="$4"
  local got_file="" got_service=""
  resolve_compose_config "$ws" "$project" got_file got_service

  if [[ "$got_file" == "$want_file" ]]; then
    ok "$label — compose file"
  else
    fail "$label — compose file: got [$got_file] want [$want_file]"
  fi

  if [[ -n "$got_service" ]]; then
    ok "$label — service name resolved ($got_service)"
  else
    fail "$label — service name empty"
  fi
}

ws_plain="$TMP/plain"
want=$(make_workspace "$ws_plain" proj)
check "plain path" "$ws_plain" proj "$want"

# The regression: a pipe in the workspace path.
ws_pipe="$TMP/a|b"
want=$(make_workspace "$ws_pipe" proj)
check "path containing a pipe" "$ws_pipe" proj "$want"

# Other characters that a tuple-encoding scheme tends to trip over.
ws_space="$TMP/with space"
want=$(make_workspace "$ws_space" proj)
check "path containing a space" "$ws_space" proj "$want"

ws_colon="$TMP/a:b"
want=$(make_workspace "$ws_colon" proj)
check "path containing a colon" "$ws_colon" proj "$want"

# A project with no compose file anywhere must yield empty values, not stale
# ones left over from a previous call.
stale_file="pre-existing" stale_service="pre-existing"
mkdir -p "$TMP/empty/other"
resolve_compose_config "$TMP/empty" other stale_file stale_service
[[ -z "$stale_file" && -z "$stale_service" ]] \
  && ok "no compose file leaves both outputs empty" \
  || fail "stale values survived: file=[$stale_file] service=[$stale_service]"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
