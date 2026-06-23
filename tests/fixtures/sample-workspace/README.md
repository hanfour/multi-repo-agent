# Sample Workspace Fixture

Synthetic workspace used by `tests/test_scanners.sh` and other test
suites. Mirrors the relationships the scanners are designed to detect
without depending on any real local repo.

| Project | Purpose |
|---------|---------|
| `erp` | Backend with docker-compose deps (mysql, redis), shared `shared_db` db, env.example with cross-service URLs |
| `billing` | Backend that also uses `shared_db` to test shared-db scanner |
| `catalog` | Bare project so api-calls/gateway-routes can resolve `catalog` as a known target |
| `partner-api-gateway` | Gateway project (`*gateway*` pattern) with `ERP_BASE_URL` to validate gateway-routes scanner |
| `web-ui` | Bare frontend project to confirm scanners do not crash on minimal projects |

No `.git/` directories are required for scanner tests because the
scanners read files directly. Add stub `.git/` only if a future test
needs `git rev-parse`.
