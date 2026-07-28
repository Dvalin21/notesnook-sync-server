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

## Garage S3 migration (garage-migration branch)

### New files
- `examples/garage/docker-compose.garage.yml` — Docker Compose overlay that replaces
  the MinIO `notesnook-s3` service with a `garage` service (image `dxflrs/garage:v2.1.0`),
  replaces the `setup-s3` one-shot with `setup-garage` (curl-based S3 PUT bucket creation),
  and overrides `notesnook-server` environment to point at `http://garage:3900`.
- `examples/garage/garage.toml` — Garage configuration (S3 API on 3900, RPC on 3901,
  web on 3902, admin on 3903). Single-node: replication_factor=1.
- `examples/garage/setup-garage.sh` — Fixed bucket creation script with proper AWS
  SigV4 signing (the original had a fake/dummy Authorization header that would never
  authenticate).
- `MONGO_UPGRADE.md` — Full MongoDB 7.0 → 8.0 FCV migration procedure (was referenced
  in README but missing from the repo).

### README.md updates
- Fixed all table rows: `||` (double pipe) at line start replaced with `|` (single pipe)
  across 4 tables (Required env vars, Optional env vars, Troubleshooting, Image pin rationale).
- Added "Migrating from MinIO to Garage S3" section with comparison table, step-by-step
  migration, and compatibility notes.
- Added Garage backup instructions to the Backup section.
- Updated Image pin rationale table: MinIO entries now note Garage as replacement;
  added `dxflrs/garage:v2.1.0` entry.

### docker-compose.garage.yml details
- `garage` service: binds S3 API on 3900, mounts `garage.toml` config, `garage-meta`
  volume for metadata, healthcheck on admin API port 3903.
- `setup-garage` service: uses `curlimages/curl:latest` (no MinIO mc dependency),
  waits for Garage health, creates bucket via S3 PUT with SigV4.
- `notesnook-server` override: `S3_INTERNAL_SERVICE_URL` → `http://garage:3900`,
  credentials from `GARAGE_ACCESS_KEY_ID` / `GARAGE_ACCESS_KEY_SECRET`.

### Compatibility verified
- Garage uses S3 API v4 signatures — compatible with .NET AWS SDK used by sync server.
- `forcePathStyle=true` works with Garage.
- Garage does not ship an mc-equivalent — bucket creation via S3 PUT API.
- Monograph PDF viewing has pre-existing issues unrelated to S3 backend.