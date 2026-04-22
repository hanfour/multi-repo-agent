# Personas

Named domain-expert prompt fragments used by `mra review --personas`, `mra plan`, and `mra test-audit`.

Each file is a self-contained prompt with a consistent header:
- `ROLE:` — the expert's title
- `STYLE:` — the voice / inspiration
- `FOCUS:` — bullet list of concerns
- `METHOD:` — how the persona should inspect the diff
- `OUTPUT FORMAT:` — how findings must be returned

Add a new persona by dropping a new `.md` file here and referencing its basename from a command. `lib/personas.sh` auto-discovers files.

## Severity ladder

All personas use the same three-tier ladder (though some tiers may not apply to every domain):

- **CRITICAL** — must block merge. Exploitable, broken, or will hit production users.
- **HIGH** — strong recommendation to fix before merge. Reproducible, high-likelihood impact.
- **MEDIUM** — polish / defense-in-depth / readability. Good judgement; not a blocker.

A persona MAY omit a tier that doesn't naturally apply to its domain (e.g. `refactoring-sage` usually has no CRITICAL findings). That's fine — don't force findings into a tier.

Guidelines:
- Keep each file under 3KB.
- Use the same severity ladder: CRITICAL / HIGH / MEDIUM.
- File:line evidence is mandatory.
