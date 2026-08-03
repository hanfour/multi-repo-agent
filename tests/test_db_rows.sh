#!/usr/bin/env bash
# Row helpers that replace per-field jq forks must render EXACTLY what the
# per-field `jq -r` calls rendered (#37).
#
# The trap: `jq -r '.a.missing'` prints the literal text "null", while the same
# value inside `@tsv` prints an empty string. A naive one-pass rewrite silently
# turns "null" into "" and every downstream `[[ -z ... ]]` changes meaning.
# These tests pin the rendering, the field order and the record order so the
# fork reduction cannot alter behaviour unnoticed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/colors.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/doctor.sh"

errors=0; pass=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
fail() { echo "FAIL: $1"; errors=$((errors+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 — expected [$2] got [$3]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# `zeta` sorts after `alpha`, so key ordering is observable. `alpha` omits
# every optional field; `zeta` supplies them all.
cat > "$TMP/db.json" <<'JSON'
{
  "databases": {
    "zeta": {
      "engine": "postgres",
      "version": "16",
      "port": 5432,
      "password": "secret",
      "platform": "linux/amd64",
      "schemas": { "public": { "source": "dump.sql" }, "audit": {} }
    },
    "alpha": {
      "engine": "mysql",
      "port": 3306
    }
  }
}
JSON

# --- doctor: name, engine, version // "latest", port, password // default ----
mapfile -t rows < <(_doctor_db_rows "$TMP/db.json")

eq "doctor emits one row per database" "2" "${#rows[@]}"
eq "doctor preserves keys[] ordering" "alpha" "$(cut -d $'\037' -f1 <<<"${rows[0]}")"

IFS=$'\037' read -r name engine version port password <<<"${rows[0]}"
eq "doctor alpha name"     "alpha"         "$name"
eq "doctor alpha engine"   "mysql"         "$engine"
eq "doctor alpha version"  "latest"        "$version"
eq "doctor alpha port"     "3306"          "$port"
eq "doctor alpha password" "mra_password"  "$password"

IFS=$'\037' read -r name engine version port password <<<"${rows[1]}"
eq "doctor zeta version"   "16"            "$version"
eq "doctor zeta password"  "secret"        "$password"

# --- db: name, engine, version (NO default), port, password, platform -------
mapfile -t drows < <(_db_instance_rows "$TMP/db.json")

IFS=$'\037' read -r name engine version port password platform has_schemas schemas <<<"${drows[0]}"
eq "db alpha version renders as null, not empty" "null" "$version"
eq "db alpha platform default"                   ""     "$platform"
eq "db alpha password default"          "mra_password"  "$password"
eq "db alpha has_schemas"               "false"         "$has_schemas"
eq "db alpha schemas joined"            ""              "$schemas"

IFS=$'\037' read -r name engine version port password platform has_schemas schemas <<<"${drows[1]}"
eq "db zeta platform"      "linux/amd64"   "$platform"
eq "db zeta has_schemas"   "true"          "$has_schemas"
eq "db zeta schemas joined (keys order)" "audit, public" "$schemas"

# --- the rendering must match what the replaced calls produced ---------------
# Field-by-field jq -r, exactly as the loops used to run it.
legacy_version=$(jq -r --arg n alpha '.databases[$n].version' "$TMP/db.json")
IFS=$'\037' read -r _ _ version _ <<<"${drows[0]}"
eq "db version matches legacy jq -r rendering" "$legacy_version" "$version"

legacy_platform=$(jq -r --arg n alpha '.databases[$n].platform // ""' "$TMP/db.json")
IFS=$'\037' read -r _ _ _ _ _ platform _ _ <<<"${drows[0]}"
eq "db platform matches legacy jq -r rendering" "$legacy_platform" "$platform"

legacy_has=$(jq -r --arg n zeta '.databases[$n] | has("schemas")' "$TMP/db.json")
legacy_join=$(jq -r --arg n zeta '.databases[$n].schemas | keys | join(", ")' "$TMP/db.json")
IFS=$'\037' read -r _ _ _ _ _ _ has_schemas schemas <<<"${drows[1]}"
eq "db has_schemas matches legacy" "$legacy_has"  "$has_schemas"
eq "db schemas join matches legacy" "$legacy_join" "$schemas"

# Edge the two fields exist to preserve: schemas present but EMPTY. Legacy
# printed an empty SCHEMAS column; collapsing to one field would have made the
# caller fall back to the instance name instead.
cat > "$TMP/empty-schemas.json" <<'JSON'
{ "databases": { "solo": { "engine": "mysql", "port": 3306, "schemas": {} } } }
JSON
IFS=$'\037' read -r _ _ _ _ _ _ has_schemas schemas < <(_db_instance_rows "$TMP/empty-schemas.json")
eq "empty schemas object still reports has_schemas true" "true" "$has_schemas"
eq "empty schemas object joins to empty string"          ""     "$schemas"

legacy_dv=$(jq -r --arg n alpha '.databases[$n].version // "latest"' "$TMP/db.json")
IFS=$'\037' read -r _ _ version _ <<<"${rows[0]}"
eq "doctor version matches legacy jq -r rendering" "$legacy_dv" "$version"

# --- empty and malformed inputs must not emit rows ---------------------------
echo '{"databases":{}}' > "$TMP/empty.json"
mapfile -t none < <(_db_instance_rows "$TMP/empty.json")
eq "no databases yields no rows" "0" "${#none[@]}"

echo "---"; echo "Passed: $pass"; echo "Failed: $errors"
exit $((errors > 0 ? 1 : 0))
