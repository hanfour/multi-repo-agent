# Collapse the 5 scanners into a single Python walker — Design

**Date:** 2026-07-14
**Issue:** hanfour/multi-repo-agent#1 — `scan: collapse the 5 scanners/*.sh into a single jq/walker pipeline`
**Status:** Approved (brainstorming)

## Profiling result (the go/no-go evidence #1 required)

Profiled `mra scan` on `~/OneAD` (36 projects, 351 records). Per-scanner best-of-3:

| scanner | time | records |
|---|---|---|
| shared-db | **5.65s** | 2 |
| shared-packages | 1.54s | 320 |
| api-calls | 0.49s | 7 |
| gateway-routes | 0.43s | 2 |
| docker-compose | 0.17s | 20 |

**The dominant cost is not "5× subshell startup"** — it is that **no scanner prunes `node_modules`**. `shared-db`'s `find -maxdepth 3` descends into 20 `node_modules` trees. Pruning them made the same `find` go 3.04s → **0.28s (~10×) with identical results**. So the walker's speedup comes from **(1) pruning node_modules and (2) walking each tree once** (`.env*` is currently read by 3 scanners). Both are captured by the design below.

## Design

### `scanners/walk.py` — a single Python walker

The issue explicitly sanctions "a small Python helper." Python is chosen over jq because the rules need associative maps (`PORT_TO_SERVICE`, `HOST_TO_SERVICE`), regex, and cross-project correlation (`shared-db` groups by db name across projects; `shared-packages` matches against the known-project list) — awkward in jq, natural in Python.

```
python3 scanners/walk.py <workspace>:
  1. Enumerate projects (workspace/*/ , skip hidden + known infra-only dirs).
  2. For each project, ONE os.walk that PRUNES node_modules/.git/vendor and
     collects the needed files, each at its ORIGINAL max depth (to preserve
     equivalence exactly):
       .env* / env.example        depth <= 2   (api-calls, shared-db, gateway-routes)
       database*.yml              depth <= 3   (shared-db)
       docker-compose*.yml        depth <= 3   (docker-compose)
       Gemfile / package.json     depth <= 1   (shared-packages)
       nginx*.conf                depth <= 4   (gateway-routes)
       apisix*.yml/.yaml, routes*.yml  depth <= 4  (gateway-routes)
  3. Apply 5 rule functions — one per original scanner, reproducing its logic
     byte-equivalently (same maps, regex, confidence, type, skip-rules) — to the
     collected files. A file read once feeds every rule that consumes it.
  4. Print JSONL to stdout — the SAME record shape:
     {"source","target","type","confidence","scanner"}, scanner tag preserved
     ("docker-compose"/"shared-db"/"api-calls"/"shared-packages"/"gateway-routes").
```

Record types/confidence preserved exactly: docker-compose→infra/high, shared-db→infra/high (target "mysql"), shared-packages→package/high, api-calls→api/low, gateway-routes→api/(medium|high per its rules).

Single file to start; rule functions cleanly separated. If it exceeds ~800 lines, split into `scanners/walk.py` + a `scanners/rules/` package — but not preemptively.

### `run_all_scanners` change (`lib/scan.sh`)

Replace the built-in `for scanner in scanners/*.sh` glob with one call:
`python3 "$MRA_DIR/scanners/walk.py" "$workspace" >> "$results_file"`. **Keep the
custom-scanner subprocess loop unchanged** — `$workspace/.collab/scanners/*.sh` still
run as subprocesses and append their JSONL. The walker replaces only the 5 built-ins.

### Built-in `.sh` disposition

Delete the 5 built-in `scanners/*.sh` from the repo (git history preserves them as
reference). They must leave the auto-run path or they'd double-run with `walk.py`.
Add `scanners/README.md` documenting the **custom-scanner contract** (a `.sh` under
`.collab/scanners/` that takes `<workspace>` and emits the JSONL record shape) with a
minimal example — this satisfies the issue's "document writing a custom scanner"
acceptance item.

### python3 dependency

`mra scan` now requires `python3` (the issue sanctions the Python helper). The repo
already uses python3 (`docs/superpowers/render-html.py`, `mra prd`). Document the
requirement in `README.md` and add a `python3` presence check to the scan path with a
clear error if missing.

## Equivalence guarantee (the acceptance core)

`walk.py`'s output must equal the current 5 scanners' output as an **order-independent
record set**. Two layers:

1. **Committed test** — reuse the bundled `tests/fixtures/sample-workspace`. Rewrite
   `tests/test_scanners.sh` to run `walk.py` against the fixture and assert the exact
   expected record set (the fixture already exercises each rule). Add a direct
   equivalence assertion: `walk.py` output set == the union the 5 old scanners
   produced on the fixture (captured as a golden set during development, before the
   `.sh` are deleted).
2. **Dev-time real-world cross-check** — during implementation, run both the old 5
   scanners and `walk.py` on `~/OneAD` (36 projects, 351 records) and diff the record
   sets; they must match. This is a development gate, documented in the plan, not a
   committed test (it depends on external data).

Any record-set difference on a **real workspace** = a rule-expressivity regression → do
not land (per #1's acceptance).

**Prune is an intentional, real-world-equivalent divergence (decided 2026-07-14).** The
legacy scanners exclude only `.git`; `walk.py` also prunes `node_modules`/`vendor`. A
config file (`docker-compose.yml`, `database.yml`, …) buried *inside* `node_modules`/
`vendor` is dependency-internal noise, not the project's real dependency, so excluding
it is a correctness improvement — but it means byte-parity does NOT hold on a
pathological tree with real config files under those dirs. The equivalence guarantee is
therefore **"identical record set on real workspaces"**, enforced by the `~/OneAD`
cross-check (344 records, empty diff), not by a constructed pathological fixture. This
divergence is documented as intentional in `scanners/README.md`.

## Performance acceptance

Benchmark `walk.py` vs the old scanners on `~/OneAD`. Target: the full scan (walk +
merge) is **≥2× faster** (expected ~8.3s → ~1–2s). If it is not ≥2×, do not land the
rewrite (fall back to the minimal node_modules-prune fix on the existing scanners).

## Files touched

| File | Action |
|---|---|
| `scanners/walk.py` | new — the single walker + 5 rule functions |
| `scanners/README.md` | new — custom-scanner contract + example |
| `scanners/docker-compose.sh`, `api-calls.sh`, `gateway-routes.sh`, `shared-db.sh`, `shared-packages.sh` | delete (git history preserves) |
| `lib/scan.sh` | `run_all_scanners` calls `walk.py`; keep custom-scanner loop; python3 check |
| `tests/test_scanners.sh` | rewrite to test `walk.py` + record-set equivalence on the fixture |
| `README.md` | note python3 requirement for `mra scan` |

## Non-goals (YAGNI)

- No change to the JSONL contract or `merge_scan_results` (PR #4's single-pass jq stays).
- No change to custom-scanner behavior (still subprocess `.sh`).
- No new rule types or detection logic — exact behavior parity only.
- No split of `walk.py` into a package unless it exceeds ~800 lines.

## Acceptance

- `walk.py` reproduces the current 5 scanners' record set exactly (fixture test +
  ~/OneAD dev cross-check).
- Full scan is ≥2× faster on ~/OneAD; else do not land.
- Custom `.collab/scanners/*.sh` still run and contribute records.
- `scanners/README.md` documents the custom-scanner contract.
- `./test.sh` green; python3 requirement documented + checked.
