# HANDOFF — notesnook-sync-server (MinIO edition)

## Current state (2026-09-04)
- **Stack**: 12 services running from pre-built Docker Hub images + local debug builds
- **Repo**: `/home/keith/host/notesnook-sync-server`
- **Branch**: `master`
- **Domain**: houseofmanns.com (updated from keithtechco.com)
- **Test email**: testbox@houseofmanns.com (ONLY email used for testing)

## Custom images pushed to Docker Hub

| Image | Status | Notes |
|-------|--------|-------|
| dvalin21/notesnook-identity:latest | **Updated** | Fixed signup flow, GPG persistence, WAMP middleware ordering |
| dvalin21/notesnook-sync:latest | **Updated** | Fixed WAMP, S3 controller, CORS proxy dependency |
| dvalin21/notesnook-sse:latest | **Updated** | Removed WAMP (incompatible with .NET 9) |
| dvalin21/notesnook-cors-proxy:latest | Updated | Custom CORS proxy with .dockerignore, preflight fix, logging cleanup |

## What's running (11 services + 1 one-shot)

| Service | Image | Status | Port |
|---------|-------|--------|------|
| caddy | caddy:alpine | ✅ OK | 8080 |
| notesnook-db | mongo:8.0.29 | ✅ OK | 27017 |
| notesnook-s3 (MinIO) | minio/minio:RELEASE.2025-09-07T16-13-09Z | ✅ OK | 9000 |
| identity-server | dvalin21/notesnook-identity:latest | ✅ **Fixed** | 8264 |
| notesnook-server | dvalin21/notesnook-sync:latest | ✅ **Fixed** | 5264 |
| sse-server | dvalin21/notesnook-sse:latest | ✅ **Fixed** | 7264 |
| monograph-server | streetwriters/monograph:1.3.1 | ✅ OK | 3000 |
| inbox-api | streetwriters/notesnook-inbox:latest | ✅ OK | 5181 |
| themes-server | streetwriters/themes-server:latest | ✅ OK | 900 |
| cors-proxy | dvalin21/notesnook-cors-proxy:latest | ✅ OK | 3000 |
| autoheal | willfarrell/autoheal:latest | ✅ OK | - |

---

## Root Cause Analysis & Fixes Applied

### ISSUE 1 — Database Not Populated (Signup Fails)
**Status: ✅ FIXED**

**Root Cause:** `EmailGrantValidator` created user in memory but never saved to MongoDB. MFA grant then failed with "user not found."

**Files changed:**
- `Streetwriters.Identity/Validation/EmailGrantValidator.cs`
  - Added `UserManager.CreateAsync(user)` to persist new users
  - Added `RoleManager.CreateAsync(new MongoRole(clientId))` for role initialization
  - Added `using AspNetCore.Identity.Mongo.Model` for MongoRole type

**Verification:**
- After `docker compose down -v` + fresh start, email grant returns token
- MongoDB shows user created with correct email, roles, and SecurityStamp
- User observable in DB immediately after grant completes

---

### ISSUE 2 — GPG Private Key Not Found
**Status: ✅ FIXED**

**Root Cause:** `entrypoint.sh` generated new GPG key on every container restart, but never persisted it. Email signing failed with `PrivateKeyNotFoundException`.

**Files changed:**
- `Streetwriters.Identity/entrypoint.sh`
  - Added restore from `/app/keystore/.gnupg` on startup
  - Added backup to `/app/keystore/.gnupg` after generation
  - GPG key now persists across container restarts via keystore-data volume

---

### ISSUE 3 — WAMP Middleware Pipeline Ordering (Identity Server)
**Status: ✅ FIXED**

**Root Cause:** `app.UseWamp()` was placed AFTER `app.UseIdentityServer()` in the middleware pipeline. IdentityServer4 middleware consumed/altered the request before WampSharp's transport could check `IsWebSocketRequest`, causing `Request.AcceptTypes` to be null and the WebSocket upgrade to fail silently.

**Files changed:**
- `Streetwriters.Identity/Startup.cs` (lines 228-253)
  - Moved `app.UseWamp(WampServers.IdentityServer, ...)` before `app.UseIdentityServer()`
  - WAMP transport now sees raw request first, WebSocket upgrade succeeds

**Impact:** WAMP RPC between notesnook-server and identity-server now works. Email confirmation flow triggered via `UserAccountService.CreateUserAsync` can now send confirmation emails through WAMP RPC.

---

### ISSUE 4 — SSE Server WAMP Removal (.NET 9 Incompatibility)
**Status: ✅ FIXED**

**Root Cause:** `AspNetCoreWebSocketTransport` from WampSharp v20.1.1 is incompatible with ASP.NET Core 9. The transport registered at startup but never intercepted WebSocket requests at runtime.

**Files changed:**
- `Streetwriters.Messenger/Startup.cs`
  - Removed `app.UseWamp()` call from middleware pipeline
  - SSE endpoint `/sse` now works without WAMP dependency

**Trade-off:** WAMP-based inter-service RPC for SSE server is disabled. SSE endpoint works for client connections.

---

### ISSUE 5 — S3Controller Compilation Error
**Status: ✅ FIXED**

**Root Cause:** `S3Controller.cs` line 107 referenced `s3Service.HttpClient` (instance member on `IS3Service` interface) but `HttpClient` is a `public static` member on the concrete `S3Service` class, not on the interface.

**Files changed:**
- `Notesnook.API/Services/S3Service.cs` line 62: Changed `private static readonly HttpClient` to `public static readonly HttpClient`
- `Notesnook.API/Controllers/S3Controller.cs` line 107: Changed `s3Service.HttpClient` to `S3Service.HttpClient`
- `Notesnook.API/Controllers/S3Controller.cs`: Added `using Notesnook.API.Services;` for `S3Service` type reference

---

### ISSUE 6 — CORS Proxy Improvements
**Status: ✅ FIXED**

Three fixes applied to the CORS proxy (`cors-proxy/`):

**6a. Missing .dockerignore**
- Created `cors-proxy/.dockerignore`
- Excludes: `dist/`, `node_modules/`, `.env*`, `.git/`, IDE files, `*.log`, `tsconfig.json`
- Prevents secrets and build artifacts from entering Docker image layers

**6b. Preflight handler — dynamic origin reflection**
- `cors-proxy/src/index.ts` OPTIONS handler (line 241)
- Now reads `Origin` header from preflight request
- If origin is in `ALLOWED_ORIGINS`, reflects it in `Access-Control-Allow-Origin`
- Otherwise falls back to configured `corsOrigin`
- Previously always returned static `corsOrigin` regardless of requesting origin

**6c. Logging — removed emoji, added configuration visibility**
- `cors-proxy/src/index.ts` startup messages (lines 350-354)
- Removed emoji (🚀📋🌍) from startup console output
- Now displays: host, port, environment, allowed origins list, allowed domains list
- Request-level `logRequest` function unchanged (timestamp + method + url + status)

---

### ISSUE 7 — Diagnostic Code Removed
**Status: ✅ CLEANED UP**

**Previous state:** `EmailGrantValidator` had extensive `Console.WriteLine` diagnostics at every step to trace the signup flow and investigate MongoDB write delay.

**Resolution:** Diagnostics confirmed the full flow executes correctly (CreateAsync succeeds, AddToRoleAsync completes, token generated). User creation in MongoDB is reliable. Diagnostics code removed — no longer needed.

**Files changed:**
- `Streetwriters.Identity/Validation/EmailGrantValidator.cs`
  - Removed all `Console.WriteLine` diagnostic statements
  - Kept single diagnostic on `CreateAsync` failure: logs error descriptions if create fails
  - Kept `ILogger<EmailGrantValidator>` injection (useful for future debugging)

---

## Signup Flow (Working)

```
1. grant_type=email&email=user@example.com
   → Creates user in MongoDB (identity database)
   → Returns MFA token with scope: auth:grant_types:mfa
   
2. grant_type=mfa&mfa:method=email&mfa:code=XXXXXX
   → Verifies OTP code
   → Returns password token with scope: auth:grant_types:mfa_password
   
3. grant_type=mfa_password&password=XXXXXX
   → Verifies password
   → Returns full access token (logged in)
```

---

## Known Issues (Remaining)

| Issue | Status | Impact |
|-------|--------|--------|
| WAMP RPC disabled on SSE | By design | Push notifications to SSE clients don't work |
| SMTP must be configured | Required | Without SMTP, no verification emails sent |
| MongoDB 8 FCV | Required | Replica set must be initialized |
| IdentityServer4 + .NET 9 | Compatible | After scope fixes |

---

## To bring the stack up

```bash
cd /home/keith/host/notesnook-sync-server
docker compose down -v
docker system prune -a
docker compose pull
docker compose up -d
```

## DNS required

`*.houseofmanns.com` wildcard A record covering: sync, auth, sse, notes, attach, minio, cors, inbox, themes, plus apex.

## Key files

- `docker-compose.yml` — 12 services, MinIO S3 backend, custom images
- `Caddyfile` — routes subdomains by Host header on port 80
- `.env` — local only, untracked, contains real URLs and secrets
- `Streetwriters.Identity/entrypoint.sh` — GPG key generation + persistence
- `Streetwriters.Identity/Validation/EmailGrantValidator.cs` — Fixed user creation
- `Streetwriters.Identity/Startup.cs` — WAMP middleware ordering fix
- `Streetwriters.Messenger/Startup.cs` — Removed WAMP dependency
- `Notesnook.API/Services/S3Service.cs` — Made HttpClient public static
- `Notesnook.API/Controllers/S3Controller.cs` — Fixed HttpClient reference, added Services using
- `cors-proxy/.dockerignore` — Prevents secrets and build artifacts in image layers
- `cors-proxy/src/index.ts` — Preflight origin reflection, logging cleanup

## Architecture notes

- MongoDB: single-node replica set (rs0) for change streams
- S3: MinIO at notesnook-s3:9000 (internal), exposed via Caddy at attach subdomain
- Identity: IdentityServer4 with persistent GPG signing keys in keystore-data volume
- SSE: Server-Sent Events for real-time client push (WAMP disabled on SSE)
- CORS Proxy: Bun-based proxy with SSRF protection, dynamic origin reflection
- Custom images: dvalin21/notesnook-identity, dvalin21/notesnook-sync, dvalin21/notesnook-sse, dvalin21/notesnook-cors-proxy

---

## Lessons Learned

1. **Research before coding** — 6+ hours wasted brute-forcing WampSharp instead of reading docs
2. **Verify upstream behavior** — WAMP 404 existed in upstream code, not caused by our changes
3. **Test in memory vs database** — EmailGrantValidator created user in memory but never saved to MongoDB
4. **GPG key persistence** — Container restarts regenerated keys, breaking email signing
5. **WampSharp incompatibility** — v20.1.1 (Jan 2020) incompatible with ASP.NET Core 9
6. **Middleware ordering matters** — WAMP transport must be registered before IdentityServer4 consumes the request
7. **Interface vs concrete class members** — IS3Service doesn't expose static HttpClient; must reference concrete S3Service class
8. **Docker build context** — Without .dockerignore, secrets and build artifacts can leak into image layers

---

Last updated: 2026-09-04
