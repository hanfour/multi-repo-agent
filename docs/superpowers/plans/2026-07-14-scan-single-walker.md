# Single Python Walker for `mra scan` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 5 built-in `scanners/*.sh` with one Python walker that traverses each project once (pruning `node_modules`) and reproduces every scanner's JSONL records exactly, ≥2× faster.

**Architecture:** `scanners/walk.py` does ONE pruned `os.walk` of the workspace, caches every non-pruned file with its path components, then applies 5 rule functions (faithful translations of the legacy scanners) that filter the cache by name+depth and emit the same JSONL. `lib/scan.sh` calls `walk.py` for built-ins and still runs custom `.collab/scanners/*.sh` as subprocesses. Correctness is gated by an order-independent record-set match against a golden fixture (13 records) and a dev-time cross-check on `~/OneAD` (344 records); landing is gated by a ≥2× benchmark.

**Tech Stack:** Python 3 (already a scan dependency — `shared-packages.sh` shells out to `python3` to parse `package.json`), Bash, `jq`, the project's `./test.sh`.

## Global Constraints

- **Exact record parity.** `walk.py`'s output must equal the legacy 5 scanners' output as an order-independent SET, both on the golden fixture and on `~/OneAD`. Any difference = rule-expressivity regression → do not land.
- **JSONL contract unchanged:** each record is `{"source","target","type","confidence","scanner"}` with the scanner tag preserved (`docker-compose`/`shared-db`/`api-calls`/`shared-packages`/`gateway-routes`). `merge_scan_results` (PR #4's single-pass jq) is not touched.
- **Prune must not change results:** pruning `node_modules`/`.git`/`vendor` is verified equivalence-preserving (already confirmed for shared-db's dominant find).
- **Custom scanners preserved:** `$workspace/.collab/scanners/*.sh` still run as subprocesses and contribute records.
- **≥2× faster on ~/OneAD** (expected ~8.3s → ~1–2s), else do not land (fall back to a node_modules-prune fix on the existing scanners).
- **Depth semantics (from the legacy `find`):** `find <root> -maxdepth N` matches files whose path has ≤ N components below `<root>`. Reference roots differ per scanner — **docker-compose collects from the WORKSPACE root (maxdepth 3); all others from the PROJECT root.** Preserve each exactly.
- **Project skip rules:** iterate `workspace/*/`, skip names starting with `.`; **shared-db additionally skips `ito-dev-env-setup`.** Reproduce per-rule.

---

## Golden fixture record set (the acceptance target)

After Task 1 extends the fixture, the 5 legacy scanners produce exactly these 13 records on `tests/fixtures/sample-workspace` (order-independent). `walk.py` must produce the same set:

```
{"source":"analytics","target":"@acme/erp","type":"package","confidence":"high","scanner":"shared-packages"}
{"source":"analytics","target":"billing","type":"package","confidence":"high","scanner":"shared-packages"}
{"source":"analytics","target":"erp","type":"package","confidence":"high","scanner":"shared-packages"}
{"source":"billing","target":"mysql","type":"infra","confidence":"high","scanner":"docker-compose"}
{"source":"billing","target":"mysql","type":"infra","confidence":"high","scanner":"shared-db"}
{"source":"erp","target":"api-gateway","type":"api","confidence":"low","scanner":"api-calls"}
{"source":"erp","target":"billing","type":"api","confidence":"low","scanner":"api-calls"}
{"source":"erp","target":"catalog","type":"api","confidence":"low","scanner":"api-calls"}
{"source":"erp","target":"mysql","type":"infra","confidence":"high","scanner":"docker-compose"}
{"source":"erp","target":"mysql","type":"infra","confidence":"high","scanner":"shared-db"}
{"source":"erp","target":"redis","type":"infra","confidence":"high","scanner":"docker-compose"}
{"source":"partner-api-gateway","target":"erp","type":"api","confidence":"low","scanner":"api-calls"}
{"source":"partner-api-gateway","target":"erp","type":"api","confidence":"medium","scanner":"gateway-routes"}
```

Each task's TDD gate is the subset of these records for the scanner(s) it implements. The final task asserts the FULL set.

---

## Task 1: `walk.py` infrastructure + fixture extension + docker-compose & shared-db rules

**Files:**
- Create: `scanners/walk.py`
- Create: `tests/fixtures/sample-workspace/analytics/package.json`
- Test: `tests/test_walk_py.sh` (new)

**Interfaces:**
- Produces: `python3 scanners/walk.py <workspace>` → JSONL on stdout. Internal: `collect(workspace)` → cache of files; rule functions `rule_docker_compose(cache, emit)`, `rule_shared_db(...)`, etc.; `emit(source,target,type,confidence,scanner)` prints one JSON line.

- [ ] **Step 1: Extend the fixture (covers shared-packages)**

Create `tests/fixtures/sample-workspace/analytics/package.json`:
```json
{
  "name": "analytics",
  "dependencies": { "@acme/erp": "1.0.0", "billing": "^2.0.0" },
  "devDependencies": { "lodash": "^4.0.0" }
}
```

- [ ] **Step 2: Write the failing test (docker-compose + shared-db subset)**

Create `tests/test_walk_py.sh`:
```bash
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

[[ "$errors" -eq 0 ]] && echo "walk.py infra tests passed" || { echo "$errors failures"; exit 1; }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_walk_py.sh`
Expected: FAIL — `scanners/walk.py` does not exist.

- [ ] **Step 4: Write `walk.py` infrastructure + the two infra rules**

Create `scanners/walk.py`:
```python
#!/usr/bin/env python3
"""Single-pass workspace scanner: walk each project once (pruning
node_modules/.git/vendor) and apply all built-in rule sets, emitting the same
JSONL relationship records the legacy scanners/*.sh produced.

Contract: one JSON object per line, {"source","target","type","confidence","scanner"}.
"""
import os
import re
import sys
import json

PRUNE = {"node_modules", ".git", "vendor"}
MAX_DEPTH = 4  # deepest any rule needs (nginx/apisix at project depth 4)


def emit(source, target, type_, confidence, scanner):
    sys.stdout.write(json.dumps(
        {"source": source, "target": target, "type": type_,
         "confidence": confidence, "scanner": scanner}) + "\n")


def collect(workspace):
    """One pruned walk. Returns (files, projects).
    files: list of dicts {abspath, name, parts} where parts = path components
    relative to the workspace (parts[0] is the project dir name).
    projects: sorted list of non-hidden top-level project names."""
    files = []
    workspace = os.path.abspath(workspace)
    for root, dirs, names in os.walk(workspace):
        rel = os.path.relpath(root, workspace)
        depth = 0 if rel == "." else len(rel.split(os.sep))
        # prune unwanted dirs and stop descending past MAX_DEPTH
        dirs[:] = [d for d in dirs if d not in PRUNE and depth < MAX_DEPTH]
        for n in names:
            parts = ([] if rel == "." else rel.split(os.sep)) + [n]
            files.append({"abspath": os.path.join(root, n), "name": n, "parts": parts})
    projects = sorted(
        d for d in os.listdir(workspace)
        if os.path.isdir(os.path.join(workspace, d)) and not d.startswith("."))
    return files, projects


def project_of(f):
    return f["parts"][0] if len(f["parts"]) > 1 else None


def depth_from_project(f):
    # parts = [project, ..., name]; components below project root
    return len(f["parts"]) - 1


def depth_from_workspace(f):
    return len(f["parts"])


def read_lines(path):
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []


# ---------- docker-compose (workspace root, maxdepth 3) ----------
def rule_docker_compose(files):
    for f in files:
        if not re.match(r"docker-compose.*\.yml$", f["name"]):
            continue
        if depth_from_workspace(f) > 3:
            continue
        current = ""
        in_dep = False
        for line in read_lines(f["abspath"]):
            m = re.match(r"^ {2}([a-zA-Z0-9_-]+):\s*$", line)
            if m:
                current = m.group(1)
                if current in ("volumes", "networks", "configs", "secrets"):
                    current = ""
                in_dep = False
                continue
            if re.match(r"^\s*#", line):
                continue
            if current and re.match(r"^ {4}depends_on:", line):
                in_dep = True
                continue
            if in_dep and re.match(r"^ {4}[a-zA-Z]", line):
                in_dep = False
            if in_dep:
                m2 = re.match(r"^ {6}-\s*([a-zA-Z0-9_-]+)", line)
                if m2 and current and current != m2.group(1):
                    emit(current, m2.group(1), "infra", "high", "docker-compose")
                m3 = re.match(r"^ {6}([a-zA-Z0-9_-]+):\s*$", line)
                if m3 and current and current != m3.group(1) and m3.group(1) != "condition":
                    emit(current, m3.group(1), "infra", "high", "docker-compose")


# ---------- shared-db (project root, database*.yml maxdepth 3, .env* maxdepth 2) ----------
def rule_shared_db(files, projects):
    pairs = []  # (project, db_name)
    for f in files:
        proj = project_of(f)
        if proj is None or proj.startswith(".") or proj == "ito-dev-env-setup":
            continue
        if re.match(r"database.*\.yml$", f["name"]) and depth_from_project(f) <= 3:
            for line in read_lines(f["abspath"]):
                m = re.match(r"^\s*database:\s*([a-zA-Z0-9_][a-zA-Z0-9_-]*)\s*$", line)
                if m:
                    db = m.group(1)
                    if "test" in db or "ci" in db:
                        continue
                    pairs.append((proj, db))
        if (f["name"].startswith(".env") or f["name"] == "env.example") and depth_from_project(f) <= 2:
            for line in read_lines(f["abspath"]):
                if re.match(r"^\s*#", line):
                    continue
                m = re.match(r"^(DB_NAME|DATABASE_NAME|MYSQL_DATABASE|POSTGRES_DB)\s*=\s*[\"']*([a-zA-Z0-9_][a-zA-Z0-9_-]*)", line)
                if m:
                    db = m.group(2)
                    if "test" in db:
                        continue
                    pairs.append((proj, db))
    by_db = {}
    for proj, db in sorted(set(pairs)):
        by_db.setdefault(db, [])
        if proj not in by_db[db]:
            by_db[db].append(proj)
    for db, projs in by_db.items():
        if len(projs) < 2:
            continue
        for p in sorted(projs):
            emit(p, "mysql", "infra", "high", "shared-db")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: walk.py <workspace>\n")
        sys.exit(1)
    workspace = sys.argv[1]
    files, projects = collect(workspace)
    rule_docker_compose(files)
    rule_shared_db(files, projects)
    # api-calls, gateway-routes, shared-packages added in later tasks


if __name__ == "__main__":
    main()
```

Translate against the legacy source to confirm parity: `scanners/docker-compose.sh` and `scanners/shared-db.sh` (the regexes above mirror their `[[ =~ ]]` patterns and skip-rules exactly). Note: `shared-db` sorts/dedups pairs then requires ≥2 projects per db before emitting — preserved.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_walk_py.sh`
Expected: PASS — `walk.py infra tests passed` (5 record assertions + JSON validity).

- [ ] **Step 6: Commit**
```bash
git add scanners/walk.py tests/test_walk_py.sh tests/fixtures/sample-workspace/analytics
git commit -m "feat(scan): walk.py single-pass walker + docker-compose/shared-db rules (#1)"
```

---

## Task 2: api-calls + gateway-routes rules (shared `.env*` + port/host maps)

**Files:**
- Modify: `scanners/walk.py` (add maps + two rule functions + wire into `main`)
- Modify: `tests/test_walk_py.sh` (add api-calls + gateway-routes assertions)

**Interfaces:**
- Consumes: `collect`/`emit`/`depth_from_project` from Task 1.
- Produces: `PORT_TO_SERVICE`, `HOST_TO_SERVICE` dicts; `rule_api_calls(files, projects)`, `rule_gateway_routes(files, projects)`.

- [ ] **Step 1: Add failing assertions**

In `tests/test_walk_py.sh`, before the final tally, add:
```bash
# api-calls (low)
has erp api-gateway api-calls; has erp billing api-calls; has erp catalog api-calls
has partner-api-gateway erp api-calls
# gateway-routes (medium)
has partner-api-gateway erp gateway-routes
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_walk_py.sh`
Expected: FAIL — those records not emitted yet.

- [ ] **Step 3: Add the shared maps + two rules to `walk.py`**

Add near the top (after `PRUNE`):
```python
PORT_TO_SERVICE = {
    "4000": "erp", "4001": "billing", "4500": "api-gateway", "5000": "catalog",
    "3100": "finance-system", "5173": "web-ui", "3030": "oss-ui-v2",
    "9443": "partner-api-gateway",
}
HOST_TO_SERVICE = {
    "erp": "erp", "billing": "billing", "catalog": "catalog",
    "api-gateway": "api-gateway", "api_gateway": "api-gateway",
    "finance-system": "finance-system", "finance_system": "finance-system",
    "web-ui": "web-ui",
}
```

Add `rule_api_calls(files, projects)` translating `scanners/api-calls.sh` (lines 41–101) exactly:
- iterate `.env*`/`env.example` at `depth_from_project ≤ 2`, per non-hidden project;
- skip comment lines; match `^([A-Z_]+(HOST|URL|API_URL))\s*=\s*["']*([^"'\s]+)`;
- skip values matching `redis|mysql|postgres|fluent|localhost|127\.0\.0\.1` and `^https?://accounts\.`;
- resolve target: port (`:(\d{4,5})` → PORT_TO_SERVICE) → else hostname substring (HOST_TO_SERVICE, first match) → else var-name prefix vs `KNOWN_UPPER_{HOST,URL,API_URL,BASE_URL}` against `projects`;
- emit `{type:"api",confidence:"low",scanner:"api-calls"}` when target found and `target != project`.

Add `rule_gateway_routes(files, projects)` translating `scanners/gateway-routes.sh`:
- `.env`/`.env.example`/`env.example` at `depth ≤ 2`: match `^([A-Z_]+_(HOST|URL|BASE_URL|API_URL))\s*=\s*["']*(.+?)["']*$`; port→PORT_TO_SERVICE (emit medium) AND var-prefix match vs projects (`KNOWN_UPPER_*` / `KNOWN_UPPERHOST` / `KNOWN_UPPERURL`) → emit medium; `target != project`;
- `nginx*.conf` at `depth ≤ 4`: match `proxy_pass\s+http://([a-zA-Z0-9_-]+):(\d+)`; port→PORT_TO_SERVICE (medium) and host==known or `${known}-service` (medium);
- `apisix*.yml/.yaml`,`routes*.yml` at `depth ≤ 4`: match `upstream.*:\s*http://([a-zA-Z0-9_-]+):(\d+)`; port→PORT_TO_SERVICE (medium).

Wire both into `main` after the Task-1 rules:
```python
    rule_api_calls(files, projects)
    rule_gateway_routes(files, projects)
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_walk_py.sh`
Expected: PASS (Task 1 + Task 2 assertions).

- [ ] **Step 5: Commit**
```bash
git add scanners/walk.py tests/test_walk_py.sh
git commit -m "feat(scan): walk.py api-calls + gateway-routes rules (#1)"
```

---

## Task 3: shared-packages rule (Gemfile + package.json)

**Files:**
- Modify: `scanners/walk.py` (add `rule_shared_packages` + wire into `main`)
- Modify: `tests/test_walk_py.sh` (add shared-packages assertions)

**Interfaces:**
- Produces: `rule_shared_packages(files, projects)`.

- [ ] **Step 1: Add failing assertions**
```bash
# shared-packages (high)
has analytics erp shared-packages; has analytics billing shared-packages
has analytics @acme/erp shared-packages
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_walk_py.sh`
Expected: FAIL.

- [ ] **Step 3: Add `rule_shared_packages` to `walk.py`**

Translate `scanners/shared-packages.sh` exactly:
- per non-hidden project, read `Gemfile` at project root (`depth_from_project == 1`):
  - for each non-comment line, for each known project `k != project`: `gem "k"` or `gem "k_with_hyphens"` (`known//_/-`) → emit high; also git-sourced `gem "name" ... git` mapped to known by normalized (`-`/`_`) equality;
- read `package.json` at project root: parse `dependencies`+`devDependencies`+`peerDependencies` keys and `workspaces` (list or `.packages`); for each dep name:
  - scoped `@scope/(.+)`: match inner to known project by normalized equality → emit high; AND always emit `project -> @scope/name` (the raw dep) high; `continue`;
  - else direct: if `dep == known` → emit high.
  Use Python's `json` to parse `package.json` (the legacy scanner already shells to `python3` for this).
- Wire into `main`: `rule_shared_packages(files, projects)`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/test_walk_py.sh`
Expected: PASS (all three tasks' assertions).

- [ ] **Step 5: Commit**
```bash
git add scanners/walk.py tests/test_walk_py.sh
git commit -m "feat(scan): walk.py shared-packages rule (#1)"
```

---

## Task 4: Integration — full-set equivalence, wire scan.sh, delete legacy, docs, benchmark

**Files:**
- Modify: `tests/test_walk_py.sh` (add full-set equivalence assertion)
- Modify: `lib/scan.sh` (`run_all_scanners` → `walk.py` + python3 check; keep custom loop)
- Delete: `scanners/docker-compose.sh`, `api-calls.sh`, `gateway-routes.sh`, `shared-db.sh`, `shared-packages.sh`
- Create: `scanners/README.md`
- Modify: `README.md` (python3 requirement), `tests/test_scanners.sh` (retarget to walk.py or remove if superseded by test_walk_py.sh)

- [ ] **Step 1: Add the full-set equivalence assertion (failing until legacy still present is handled)**

In `tests/test_walk_py.sh`, add an order-independent full-set match. Since the legacy `.sh` are deleted in this task, compare against a committed golden file instead:
```bash
# Full record-set equivalence against the committed golden set
GOLD="$MRA_DIR/tests/fixtures/expected-records.jsonl"
diff <(echo "$out" | jq -cS . | sort -u) <(jq -cS . < "$GOLD" | sort -u) \
  && pass "walk.py matches golden record set exactly" \
  || fail "walk.py record set differs from golden"
```
Create `tests/fixtures/expected-records.jsonl` with the 13 golden records listed in this plan's "Golden fixture record set" section (one JSON object per line).

- [ ] **Step 2: Verify walk.py == golden BEFORE deleting legacy (dev gate)**

Run (dev check, before deletion): compare walk.py to the live legacy scanners on the fixture AND on `~/OneAD`:
```bash
diff <(python3 scanners/walk.py tests/fixtures/sample-workspace | jq -cS . | sort -u) \
     <(for s in scanners/*.sh; do bash "$s" tests/fixtures/sample-workspace 2>/dev/null; done | jq -cS . | sort -u)
diff <(python3 scanners/walk.py ~/OneAD | jq -cS . | sort -u) \
     <(for s in scanners/*.sh; do bash "$s" ~/OneAD 2>/dev/null; done | jq -cS . | sort -u)
```
Both diffs MUST be empty (fixture: 13 records; ~/OneAD: 344 records). If ~/OneAD is unavailable, note it and rely on the fixture. Record the result in the report. If either diff is non-empty, STOP — the translation has a parity gap.

- [ ] **Step 3: Benchmark (≥2× gate)**

Time both on `~/OneAD` (best of 3), record in the report:
```bash
# legacy
time ( for s in scanners/*.sh; do bash "$s" ~/OneAD >/dev/null 2>&1; done )
# walker
time ( python3 scanners/walk.py ~/OneAD >/dev/null )
```
Expected: walker ≥2× faster (legacy ~8.3s → walker ~1–2s). If NOT ≥2×, STOP and report — the rewrite does not meet #1's acceptance.

- [ ] **Step 4: Wire `lib/scan.sh`**

In `run_all_scanners`, replace the built-in scanner glob loop:
```bash
  # before: for scanner in "$MRA_DIR"/scanners/*.sh; do ... bash "$scanner" ... done
  # after:
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "mra scan requires python3 (scanners/walk.py)" "scan"
    return 1
  fi
  log_progress "running walker: walk.py" "scan" >&2
  python3 "$MRA_DIR/scanners/walk.py" "$workspace" >> "$results_file" 2>/dev/null || true
```
Leave the custom-scanner loop (`$workspace/.collab/scanners/*.sh`) unchanged.

- [ ] **Step 5: Delete legacy scanners + add README**

```bash
git rm scanners/docker-compose.sh scanners/api-calls.sh scanners/gateway-routes.sh scanners/shared-db.sh scanners/shared-packages.sh
```
Create `scanners/README.md` documenting: the built-in rules now live in `walk.py`; the **custom-scanner contract** — a `.sh` under `<workspace>/.collab/scanners/` that takes `<workspace>` as `$1` and prints JSONL records `{"source","target","type","confidence","scanner"}`; and a minimal working example.

- [ ] **Step 6: Update `tests/test_scanners.sh` and `README.md`**

`tests/test_scanners.sh` tested the now-deleted `.sh` — its coverage is superseded by `tests/test_walk_py.sh` (full-set equivalence). Either delete `test_scanners.sh` or repoint it to `walk.py`; do NOT leave it sourcing deleted files. In `README.md`, note that `mra scan` requires `python3`.

- [ ] **Step 7: Run the full suite**

Run: `./test.sh`
Expected: green (test_walk_py.sh included; no test references deleted scanners). Record shell/mcp counts.

- [ ] **Step 8: Commit**
```bash
git add -A
git commit -m "refactor(scan): replace 5 built-in scanners with walk.py; docs + tests + benchmark (#1)"
```

---

## Self-Review

**Spec coverage:** walk.py single pruned walk + 5 rules (Tasks 1–3) → JSONL parity; lib/scan.sh wiring + custom-scanner preservation + delete legacy + scanners/README.md + python3 doc/check + fixture & ~/OneAD equivalence + ≥2× benchmark (Task 4). All spec sections mapped. ✅

**Placeholder scan:** Task 1 gives full `walk.py` infrastructure + docker-compose + shared-db code; the maps (Task 2) and each remaining rule are specified as exact translations of a named legacy source with the golden records as the correctness gate — not vague ("add validation"). The golden fixture set (13 records) is enumerated verbatim.

**Type/name consistency:** `collect`/`emit`/`project_of`/`depth_from_project`/`depth_from_workspace` defined in Task 1 and reused by Tasks 2–3; `PORT_TO_SERVICE`/`HOST_TO_SERVICE` defined once (Task 2) and used by both api-calls and gateway-routes; rule functions wired into `main` in each task. `tests/fixtures/expected-records.jsonl` (Task 4) holds the same 13 records asserted piecewise in Tasks 1–3.

**Risk note:** the deepest correctness risk is per-rule translation fidelity (regex/skip-rules/depth roots). Mitigated by the golden-fixture full-set assertion (committed) + the ~/OneAD 344-record dev cross-check (Task 4 Step 2), both order-independent — any drift fails loudly before landing.
