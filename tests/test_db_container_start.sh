#!/usr/bin/env bash
# `docker run` failing must not be reported as a container that started.
#
# Observed against real Docker: mysql:5.7 has no arm64 image, so `docker run`
# printed "no matching manifest for linux/arm64/v8" and exited non-zero. mra
# printed, in green,
#
#   [db] container mra-db-probe started
#
# then "did not become ready within 60 seconds" — which reads as a slow or
# unhealthy container, not as an image that was never pulled. `mra db setup`
# exited 0 with nothing running.
#
# start_db_container ignored docker's exit code and ended with log_success, so
# its own return value was log_success's 0; the caller's `if ! start_db_container`
# could never fire.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/db.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"; export PATH="$BIN:$PATH"

make_docker() {  # $1 = exit code for `run`
  cat > "$BIN/docker" <<STUB
#!/usr/bin/env bash
case "\$1" in
  ps)  exit 0 ;;
  run) echo "docker: no matching manifest for linux/arm64/v8" >&2; exit $1 ;;
  *)   exit 0 ;;
esac
STUB
  chmod +x "$BIN/docker"
}

# --- docker run fails --------------------------------------------------------
make_docker 125
out=$(start_db_container probe mysql 5.7 33061 pw "" 2>&1); rc=$?

[[ $rc -ne 0 ]] && ok "a failed docker run is a failed start (rc=$rc)" \
                || fail "start_db_container returned 0 after docker run failed"
case "$out" in
  *"container mra-db-probe started"*) fail "reported success for a container that never started" ;;
  *) ok "no success message for a failed start" ;;
esac
case "$out" in
  *manifest*|*"docker"*) ok "docker's own error is surfaced" ;;
  *) fail "docker's reason was swallowed: $out" ;;
esac

# --- docker run succeeds -----------------------------------------------------
make_docker 0
out=$(start_db_container probe mysql 5.7 33061 pw "" 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "a successful docker run still succeeds" \
                || fail "start_db_container failed on a working docker (rc=$rc, $out)"
case "$out" in
  *"container mra-db-probe started"*) ok "success is still reported" ;;
  *) fail "lost the success message: $out" ;;
esac

# --- the caller must see it --------------------------------------------------
make_docker 125
if start_db_container probe mysql 5.7 33061 pw "" >/dev/null 2>&1; then
  fail "\`if ! start_db_container\` cannot fire — the caller skips its error path"
else
  ok "the caller's failure branch is reachable"
fi

# --- and the whole command must fail, not just log ---------------------------
# Both failure paths `continue`, so the loop finished and setup_all_databases
# returned 0. `mra db setup` exited successfully having started nothing.
WS="$TMP/ws"; mkdir -p "$WS/.collab"
cat > "$WS/.collab/db.json" <<'JSON'
{"databases":{"probe":{"engine":"mysql","version":"5.7","port":33061,"password":"pw","schemas":{"app":{}}}}}
JSON
make_docker 125
MRA_DB_HEALTH_TIMEOUT=1 setup_all_databases "$WS" >/dev/null 2>&1; src=$?
[[ $src -ne 0 ]] && ok "setup_all_databases fails when an instance never comes up (rc=$src)" \
                 || fail "setup_all_databases returned 0 having started nothing"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
