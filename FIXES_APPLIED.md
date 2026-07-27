# notesnook-sync-server — Reliability fixes applied 2026-07-27

## Changes made (3 files)

### 1. Streetwriters.Common/Constants.cs — CORS env-var name (fixes #24/#58/#505)
- Changed `ReadSecret("NOTESNOOK_CORS")` to `ReadSecret("NOTESNOOK_CORS_ORIGINS")` to match the .env documentation.
- Previously setting `NOTESNOOK_CORS_ORIGINS` in .env did nothing; server silently used `AllowAnyOrigin()`.

### 2. Notesnook.API/Startup.cs — MONGODB_DATABASE_NAME hardcode (fixes #86)
- Replaced 7 hardcoded `"notesnook"` database arguments in `AddRepository<T>()` calls with `Constants.MONGODB_DATABASE_NAME`.
- Default value is still `"notesnook"` for backward compatibility.
- Upstream bug #86: changing `MONGODB_DATABASE_NAME` was silently ignored for 7 of 13 collections.

### 3. docker-compose.yml — operational hardening (removes 4 reliability hazards)
- Added `restart: unless-stopped` to all 6 app services + mongo + minio.
- Added `dpdata` named volume mounted at `/app/.aspnet/DataProtection-Keys` on identity-server, notesnook-server, sse-server, monograph-server, notesnook-db. Fixes token invalidation on every container recreate (issue #77 reproduction path).
- Removed `autoheal` service and its `/var/run/docker.sock` mount — replaced by native restart policy.
- Removed Minio host port mapping `9000:9000` (internal-only; reach via your TLS proxy).
- Removed wget-based healthchecks from monograph, notesnook-server, sse-server, identity-server (wget absent in monograph image; identity/wget redundant with restart policy).
- Added `dpdata` to named volumes.
- Added `|| true` to `setup-s3` `mc mb` so it doesn't fail on repeat runs.
- `setup-s3` explicitly marked `restart: "no"`.

## NOT YET DONE (tracked)
### #105 signup blocker — scope validation error (open upstream, no fix applied yet)
- `CreateUserAsync` in `UserAccountService.cs` validates the client_id against IdentityServer's in-memory `Clients` list (`Config.Clients`), then creates the user and issues tokens.
- The "scope validation error" from issue #105 originates from the client sending scopes not in `Config.AllowedScopes` (allowed: `notesnook.sync`, `offline_access`, `openid`, `profile`, `mfa` + local API scope).
- Possible cause: Android app 3.0.32+ (or a recent token refresh) sends a scope the identity server doesn't recognize — a version skew between client and identity server scope config.
- Needs a real log trace to confirm; cannot fix without the exact failed request payload.
- NOT applied yet — this is a research task for a future session, not a blind patch.

## Reliability assessment (unchanged from prior research)
- Self-host support: explicit "without support" disclaimer, no docs.
- Client/server version skew breaks sync (client #8698 — app 3.3 broke self-hosted sync).
- `:latest` tags on all DockerHub images are non-pinned.
- No backup story in compose (mongodump + mc mirror needed as operational layer).
- 68 forks exist; ALL are mirrors of upstream with zero divergent commits. Nobody else has fixed these issues.

## Files changed: 3 (+1 dpdata volume added to volumes section)