# mra analyze — Project Knowledge Base

Distil a project into reusable knowledge documents instead of re-reading the whole codebase every session.

```bash
mra analyze my-api               # generate
mra analyze my-api --model haiku # cheaper for module summaries
```

## What it generates

| Document | Content |
|----------|---------|
| `identity.md` | Name, type, one-line purpose (~50 tokens) |
| `sitemap.md` | File tree + module purpose index |
| `architecture.md` | Patterns, data flow, tech stack |
| `conventions.md` | Coding style, `[CONVENTION]`/`[PATTERN]`/`[DECISION]` tags |
| `api-surface.md` | Endpoints, exports, event contracts |
| `tunnels.md` | Cross-module entity references (auto-detected) |
| `modules/*.md` | Per-module deep summaries |

## 4-layer memory stack

Inspired by [mempalace](https://github.com/milla-jovovich/mempalace).

| Layer | Content | Tokens | Loaded |
|-------|---------|--------|--------|
| L0 Identity | Name + type + purpose | ~50 | Always |
| L1 Essential | Tagged conventions + patterns | ~200 | Always |
| L2 Room Recall | Sitemap + architecture + relevant modules | ~500 | On review/ask |
| L3 Deep Search | Full API surface + all modules | ~800+ | On orchestrator launch |

**Result:** review wake-up cost drops from ~150K tokens to ~250.

## Auto-update

After every review:
- Changed modules get updated summaries (background, haiku)
- New files update the sitemap
- CRITICAL/HIGH findings captured as `[DECISION]` tags in `conventions.md`
- Tunnel links regenerated

`mtime` detection skips unchanged modules.
