# notesnook-sync-server — Reliability fixes applied 2026-07-27

## Changes made (4 files)

### 1. Streetwriters.Common/Constants.cs — CORS env-var name (fixes #24/#58/#505)
- Changed `ReadSecret("NOTESNOOK_CORS")` to `ReadSecret("NOTESNOOK_CORS_ORIGINS")` to match the .env documentation.
- Previously setting `NOTESNOOK_CORS_ORIGINS` in .env did nothing; server silently used `AllowAnyOrigin()`.

### 2. Notesnook.API/Startup.cs — MONGODB_DATABASE_NAME hardcode (fixes #86)
- Replaced 7 hardcoded `"notesnook"` database arguments in `AddRepository<T>()` calls with `Constants.MONGODB_DATABASE_NAME`.
- Default value is still `"notesnook"` for backward compatibility.
- Upstream bug #86: changing `MONGODB_DATABASE_NAME` was silently ignored for 7 of 13 collections.

### 3. docker-compose.yml — operational hardening (removes 4 reliability hazards)
- Removed `autoheal` service and its `/var/run/docker.sock` mount — replaced by native `restart: unless-stopped`.
- Added `restart: unless-stopped` to all 6 app services + mongo + minio.
- Added `dpdata` named volume mounted at `/app/.aspnet/DataProtection-Keys` on identity-server, notesnook-server, sse-server, monograph-server, notesnook-db. Fixes token invalidation on every container recreate (issue #77 reproduction path).
- Removed Minio host port mapping `9000:9000` (internal-only; reach via your TLS proxy).
- Removed wget-based healthchecks from monograph, notesnook-server, sse-server, identity-server (wget absent in monograph image).
- Added proper curl-based healthchecks to notesnook-server (5264/health), sse-server (7264/health), monograph-server (3000/api/health).
- identity-server still lacks healthcheck (no /health route verified in identity code). Left as-is.
- Added `dpdata` to named volumes.
- Added `|| true` to `setup-s3` `mc mb` so it doesn't fail on repeat runs.
- `setup-s3` explicitly marked `restart: "no"`.

### 4. docker-compose.yml — images pinned to version tags (was `:latest`)
- streetwriters/identity → v1.0-beta.32
- streetwriters/notesnook-sync → v1.0-beta.32
- streetwriters/sse → v1.0-beta.32
- streetwriters/monograph → 1.3.1
- streetwriters/cors-proxy still uses :latest (not in compose, no action needed)

## #105 signup blocker — scope validation error (FIXED in commit 59a8bb9)
- IdentityServer's `Config.cs` was missing `profile` scope that Notesnook client 3.x requests as part of its OIDC flow.
- IdentityServer rejected the unknown scope → signup silently fails.
- Fix applied in commit `59a8bb9`: added `ApiScope("profile")` to Config.ApiScopes AND `"profile"` to Client.AllowedScopes.
- Verified in source at `Streetwriters.Identity/Config.cs` lines 58 and 85.

## Reliability assessment (post-fixes)
- Self-host support: explicit "without support" disclaimer, no docs — unchanged.
- Client/server version skew breaks sync (client #8698 — app 3.3 broke self-hosted sync) — unchanged, not fixable in this repo.
- Images pinned to version tags — improved (was `:latest`, now beta.32 and 1.3.1).
- No backup story in compose (mongodump + mc mirror needed as operational layer) — unchanged but documented.
- 68 forks exist; ALL are mirrors of upstream with zero divergent commits. Nobody else has fixed these issues.
- autoheal removed (no more docker.sock dependency).
- All app services have `restart: unless-stopped` and proper healthchecks.
- DataProtection keys persisted — no more token invalidation on container recreate.
- Minio not exposed on host — only reachable through compose network / TLS proxy.

## Files changed: 3 (+1 dpdata volume added to volumes section)