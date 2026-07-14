# scanners/

## Built-in rules: `walk.py`

`mra scan` runs `scanners/walk.py <workspace>` to detect cross-repo
dependencies. It replaces the five separate `scanners/*.sh` scripts that
used to exist here (`docker-compose.sh`, `api-calls.sh`,
`gateway-routes.sh`, `shared-db.sh`, `shared-packages.sh`).

Instead of each rule walking the workspace tree on its own (5 separate
`find`/directory walks), `walk.py` does a **single pruned `os.walk`** over
the workspace and applies all five rule sets — docker-compose service
dependencies, shared MySQL databases, `.env`-based API calls, gateway/proxy
routes, and shared Ruby/Node packages — to the same in-memory file list.
This is what gives the ~30-50x speedup over the old per-rule shell scanners
(see the perf numbers in the Task 4 report) while producing the exact same
JSONL relationship records.

Output contract (unchanged from the legacy scanners): one JSON object per
line —

```json
{"source": "erp", "target": "billing", "type": "package", "confidence": "high", "scanner": "shared-packages"}
```

`source`/`target` are project (top-level workspace directory) names,
`type` is one of `infra`/`api`/`package`, `confidence` is
`low`/`medium`/`high`, and `scanner` identifies which rule produced the
record (kept as the historical rule/script names above for continuity with
existing dep-graph data and reporting).

## Custom-scanner contract

Workspaces can add their own scanners without touching `mra` itself. Any
executable `.sh` file under `<workspace>/.collab/scanners/` is run by `mra
scan` after `walk.py`, with the workspace root as `$1`. It must print JSONL
records on stdout using the same schema as above (extra rule types beyond
`infra`/`api`/`package` are accepted).

Minimal working example — `<workspace>/.collab/scanners/graphql-schema.sh`:

```bash
#!/usr/bin/env bash
# Custom scanner: flag projects that import a shared GraphQL schema package.
set -euo pipefail

workspace="$1"

for proj_dir in "$workspace"/*/; do
  [[ -f "$proj_dir/package.json" ]] || continue
  proj="$(basename "$proj_dir")"
  if grep -q '"@acme/graphql-schema"' "$proj_dir/package.json" 2>/dev/null; then
    printf '{"source":"%s","target":"graphql-schema","type":"package","confidence":"high","scanner":"graphql-schema"}\n' "$proj"
  fi
done
```

Make it executable (`chmod +x`) so `mra scan` picks it up; `mra scan` runs
every `*.sh` file in that directory regardless of the executable bit
(`bash "$scanner"`), but keeping scripts executable is good practice and
matches this example.

## Intentional divergences from the old scanners

`walk.py`'s output is verified record-for-record equivalent to the five
legacy scanners on the committed fixture (`tests/fixtures/sample-workspace`,
golden file `tests/fixtures/expected-records.jsonl`) and was cross-checked
against a real ~344-project workspace (`~/OneAD`) with an empty diff. A
handful of behavior changes were made deliberately during the rewrite; they
are documented here so they are never mistaken for regressions:

1. **Pruned directories.** `walk.py` prunes `node_modules/`, `vendor/`, and
   `.git/` from its walk (the legacy scanners only excluded `.git`, since
   each rule used its own bounded `find -maxdepth`). Config-shaped files
   that happen to live inside a vendored `node_modules`/`vendor` tree (e.g.
   a dependency's own `docker-compose.yml` or `package.json`) are
   dependency-internal noise and are intentionally excluded from scan
   results. Validated as real-world-equivalent against `~/OneAD` — pruning
   these directories changed zero records there.

2. **Deterministic host-substring matching.** When a `.env` value's
   hostname matches more than one entry in `HOST_TO_SERVICE` as a
   substring, `walk.py` deterministically picks the **longest** matching
   key (most specific host name), tie-broken by key name. The legacy
   `api-calls.sh` iterated a bash associative array, which iterates in
   hash-bucket order — nondeterministic across bash builds/versions. There
   was never a well-defined legacy behavior to replicate for this case;
   longest-match-wins is a principled, deterministic replacement.

3. **Hidden top-level directories excluded from project matching.** Both
   the legacy and new scanners skip hidden (`.`-prefixed) directories as
   *scan targets* (e.g. never scanning inside `.collab/`). `walk.py` also
   excludes hidden directories from the "known project" name list used for
   substring/prefix matching (e.g. in `shared-packages` and `api-calls`);
   the legacy shell scripts built their `known_projects` list the same way
   (`"$WORKSPACE"/*/` with a `[[ "$project" == .* ]] && continue` guard per
   rule), so in practice this is the same behavior, called out here
   because it is easy to assume otherwise when reading `walk.py`
   standalone.

4. **Malformed `package.json` fields: partial output instead of
   all-or-nothing.** If `package.json` parses as valid JSON but one of its
   dependency-shaped fields is structurally wrong (e.g. `"dependencies"`
   is a list/string instead of an object), `walk.py` checks each of
   `dependencies`/`devDependencies`/`peerDependencies`/`workspaces` with
   `isinstance(..., dict)` independently and simply skips the malformed
   field, still emitting records from any well-formed fields on the same
   file. The legacy scanner built one combined `dict` via
   `deps.update(d.get(field, {}))` inside a single `try/except`: a
   malformed field raised on `.update()` and was swallowed by the
   surrounding `except Exception: pass`, silently discarding output from
   *all* fields on that file, not just the bad one. This is a
   pathological-input difference (a hand-authored, spec-violating
   `package.json`) with no observed manifestation on the fixture or
   `~/OneAD` — flagged for completeness, not because it changed any golden
   record.
