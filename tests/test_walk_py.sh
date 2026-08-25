#!/usr/bin/env bash
set -euo pipefail
MRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$MRA_DIR/tests/fixtures/sample-workspace"
errors=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; errors=$((errors+1)); }

out=$(python3 "$MRA_DIR/scanners/walk.py" "$FIX")

# every line valid JSON
while IFS= read -r l; do [[ -z "$l" ]] && continue; echo "$l" | jq -e . >/dev/null || fail "invalid JSON: $l"; done <<<"$out"

has(){ echo "$out" | jq -e --arg s "$1" --arg t "$2" --arg sc "$3" 'select(.source==$s and .target==$t and .scanner==$sc)' >/dev/null && pass "$3: $1->$2" || fail "$3: missing $1->$2"; }
# docker-compose
has erp mysql docker-compose; has erp redis docker-compose; has billing mysql docker-compose
# shared-db
has erp mysql shared-db; has billing mysql shared-db
# api-calls (low)
has erp api-gateway api-calls; has erp billing api-calls; has erp catalog api-calls
has partner-api-gateway erp api-calls
# gateway-routes (medium)
has partner-api-gateway erp gateway-routes
# shared-packages (high)
has analytics erp shared-packages; has analytics billing shared-packages
has analytics @acme/erp shared-packages

# Full record-set equivalence against the committed golden set (generated
# from the now-deleted legacy scanners/*.sh on this fixture; see
# scanners/README.md for how the golden file is produced).
GOLD="$MRA_DIR/tests/fixtures/expected-records.jsonl"
if diff <(python3 "$MRA_DIR/scanners/walk.py" "$FIX" | jq -cS . | sort -u) <(jq -cS . < "$GOLD" | sort -u) >/dev/null; then
  pass "walk.py matches golden record set exactly"
else
  fail "walk.py differs from golden"
fi

# --- service map ------------------------------------------------------------
# The port/host maps are conventions, not a description of any one workspace,
# so a workspace supplies its own at <workspace>/.collab/service-map.json.
# Every assertion below pins MRA_SCAN_SERVICE_MAP: the fixture has no .collab
# of its own today, but if one is ever added these would start reading it and
# fail while the code is fine.
SM_TMP="$(mktemp -d)"
trap 'rm -rf "$SM_TMP"' EXIT

# No file at all: the defaults still apply, so the golden set is unchanged.
if diff <(MRA_SCAN_SERVICE_MAP="$SM_TMP/absent.json" python3 "$MRA_DIR/scanners/walk.py" "$FIX" | jq -cS . | sort -u) \
        <(jq -cS . < "$GOLD" | sort -u) >/dev/null; then
  pass "service map 不存在時走內建預設，輸出與 golden 相同"
else
  fail "service map 不存在時輸出與 golden 不同"
fi

# A file present replaces the defaults wholesale. erp is mapped to 4000 by the
# defaults; a map that omits it must stop resolving that port, otherwise the
# file is merging rather than replacing.
cat > "$SM_TMP/map.json" <<'JSON'
{"ports": {"9999": "nowhere"}, "hosts": {"nowhere": "nowhere"}}
JSON
sm_out="$(MRA_SCAN_SERVICE_MAP="$SM_TMP/map.json" python3 "$MRA_DIR/scanners/walk.py" "$FIX")"
if echo "$sm_out" | jq -e 'select(.target=="api-gateway" and .scanner=="api-calls")' >/dev/null 2>&1; then
  fail "有 service map 時仍混入內建預設(api-gateway 還在解析)"
else
  pass "有 service map 時不混入內建預設"
fi

# Malformed maps are a hard failure, never a quiet fall back to the defaults:
# both outcomes would emit the same records, so falling back makes a broken
# config indistinguishable from no config.
sm_bad(){
  local desc="$1" body="$2" want="$3"
  printf '%s' "$body" > "$SM_TMP/bad.json"
  local err rc
  err="$(MRA_SCAN_SERVICE_MAP="$SM_TMP/bad.json" python3 "$MRA_DIR/scanners/walk.py" "$FIX" 2>&1 >/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    fail "$desc — 應該非 0 退出，卻是 0"
  elif [[ "$err" != *"$want"* ]]; then
    fail "$desc — stderr 沒有 $want：$err"
  else
    pass "$desc"
  fi
}
sm_bad "壞掉的 JSON 硬失敗"       '{"ports":'                       SERVICE_MAP_UNREADABLE
sm_bad "頂層不是物件硬失敗"        '[]'                              SERVICE_MAP_INVALID
sm_bad "缺 hosts 硬失敗"          '{"ports":{}}'                    SERVICE_MAP_INVALID
sm_bad "缺 ports 硬失敗"          '{"hosts":{}}'                    SERVICE_MAP_INVALID
sm_bad "多餘的鍵硬失敗"           '{"ports":{},"hosts":{},"prots":{}}' SERVICE_MAP_INVALID
sm_bad "ports 不是物件硬失敗"      '{"ports":[],"hosts":{}}'         SERVICE_MAP_INVALID
sm_bad "值不是字串硬失敗"          '{"ports":{"1":2},"hosts":{}}'    SERVICE_MAP_INVALID
sm_bad "值是空字串硬失敗"          '{"ports":{"1":""},"hosts":{}}'   SERVICE_MAP_INVALID

[[ "$errors" -eq 0 ]] && echo "walk.py infra tests passed" || { echo "$errors failures"; exit 1; }
