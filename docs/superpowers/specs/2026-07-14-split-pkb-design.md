# Split `lib/pkb.sh` into cache / query / prompts modules — Design

**Date:** 2026-07-14
**Issue:** hanfour/multi-repo-agent#15 (follow-up from #12) — `refactor: 拆分 lib/pkb.sh(1133)`
**Status:** Approved (brainstorming)

## Problem

`lib/pkb.sh` (1133 lines, 27 functions) is a monolith — a remaining complexity
hotspot after #12 split the review subsystem. Same fix, same discipline as #12:
behavior-preserving relocation of whole functions into focused modules, guarded by
the existing `tests/test_pkb_*.sh` + `shellcheck`.

## Critical: the awk `}`-heuristic is UNSAFE here

`pkb.sh` has **27 functions but 28 column-0 `}`** — one extra closing brace lives
*inside* a `_pkb_generate_*` PROMPT heredoc (an embedded JSON `}`). This is exactly
the trap that bit #12 Task 5 (`run_synthesize`). So extraction MUST NOT use the
"function ends at the next `^}$`" heuristic.

**Extraction method:** slice each function by **line range from its `^name() {`
start to the line just before the NEXT top-level function's start** (or EOF for the
last). Functions are contiguous (only comments/blank lines between them, which
attach to the following function), so the next-function-start boundary is robust
regardless of internal braces/heredocs. Verify with a **line-multiset diff**: the
sorted non-blank lines of the original `pkb.sh` must equal the sorted union of
(new `pkb.sh` + 3 new modules) minus the added shebangs/headers.

## Design

### `lib/pkb.sh` (1133) → orchestrator + 3 modules

Ordering is irrelevant (all `lib/*.sh` are function-definition files sourced by
`bin/mra.sh` before `main()`; calls resolve at call-time), so a moved public-API
function (e.g. `pkb_build_context`, `pkb_exists`) still works from any module.

| Module | Functions moved (verbatim) | ~lines |
|---|---|---|
| `lib/pkb-cache.sh` | `pkb_dir`, `pkb_ensure_gitignore`, `pkb_exists`, `_pkb_valid_doc`, `_pkb_keep_doc`, `pkb_age_hours`, `pkb_init_meta`, `pkb_update_meta`, `_pkb_record_mtimes`, `_pkb_check_mtimes` | ~210 |
| `lib/pkb-query.sh` | `pkb_build_context`, `pkb_modules_from_files`, `_pkb_file_to_module`, `_pkb_module_to_dir` | ~210 |
| `lib/pkb-prompts.sh` | `_pkb_generate_sitemap`, `_pkb_generate_architecture`, `_pkb_generate_conventions`, `_pkb_generate_api_surface`, `_pkb_generate_modules`, `_pkb_generate_one_module`, `_pkb_update_one_module`, `_pkb_generate_identity`, `_pkb_generate_tunnels`, `_pkb_update_sitemap` | ~490 |

**Stays in `pkb.sh`:** the top-level orchestration entry points —
`pkb_generate`, `pkb_incremental_update`, `pkb_capture_decisions`. Target ~270 lines.

Function accounting: 10 (cache) + 4 (query) + 10 (prompts) + 3 (stay) = 27. ✓

`pkb-prompts.sh` at ~490 lines is the heredoc-heavy prompt-builder group; it stays a
single module (under the 800-line cap) — no preemptive further split.

### Sourcing wiring (`bin/mra.sh`)

Add three `source` lines next to the existing `source "$MRA_DIR/lib/pkb.sh"`
(line 72):
```
source "$MRA_DIR/lib/pkb-cache.sh"
source "$MRA_DIR/lib/pkb-query.sh"
source "$MRA_DIR/lib/pkb-prompts.sh"
```

The three tests that source `lib/pkb.sh` directly — `test_pkb_gitignore.sh`,
`test_pkb_context.sh`, `test_pkb_age.sh` — each get the three new module sources
added after their `lib/pkb.sh` source line (idempotent; the full suite verifies).

## Data flow / error handling

Unchanged — pure relocation. `pkb_generate` still calls `_pkb_generate_*` (now in
`pkb-prompts.sh`), resolved at call-time. `set -euo pipefail` behavior identical
(byte-identical function bodies, source order irrelevant).

## Testing

- After each module extraction: run the guarding `test_pkb_*.sh`, then full
  `./test.sh` — same counts.
- `shellcheck -S error` on every new + modified file.
- Line-multiset diff (original pkb.sh vs new pkb.sh + 3 modules) = zero content
  difference (the decisive no-loss/no-alter gate, safe against the heredoc-`}` trap).

## Files touched

| File | Action |
|---|---|
| `lib/pkb-cache.sh`, `lib/pkb-query.sh`, `lib/pkb-prompts.sh` | new (moved fns) |
| `lib/pkb.sh` | shrunk to 3 orchestrators |
| `bin/mra.sh` | +3 source lines |
| `tests/test_pkb_gitignore.sh`, `test_pkb_context.sh`, `test_pkb_age.sh` | +3 module sources each |

## Non-goals (YAGNI)

- No logic/signature/prompt changes.
- No further split of `pkb-prompts.sh`.
- No change to `bin/mra.sh` dispatch (that is #16).

## Acceptance

- `lib/pkb.sh` drops to ~270 lines (3 orchestrators); each new module has one clear
  responsibility, < 800 lines.
- Every original function present exactly once across (pkb.sh + 3 modules); line-
  multiset diff empty.
- `./test.sh` green with unchanged counts; `shellcheck -S error` clean.
