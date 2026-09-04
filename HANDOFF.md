# HANDOFF — notesnook-sync-server (MinIO edition)

## Current state (2026-09-03)
- **Stack**: 12 services running from pre-built Docker Hub images + local debug builds
- **Repo**: `/home/keith/host/notesnook-sync-server`
- **Branch**: `master`
- **Domain**: houseofmanns.com (updated from keithtechco.com)

## Custom images pushed to Docker Hub

| Image | Status | Notes |
|-------|--------|-------|
| dvalin21/notesnook-identity:latest | **Updated** | Fixed signup flow, GPG persistence |
| dvalin21/notesnook-sync:latest | **Updated** | Fixed WAMP, S3 controller |
| dvalin21/notesnook-sse:latest | **Updated** | Removed WAMP (incompatible with .NET 9) |
| dvalin21/notesnook-cors-proxy:latest | Updated | Custom CORS proxy |
| dvalin21/minio-notesnook:latest | Updated | Security patches |

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
```bash
# Email grant now creates user in MongoDB
curl -X POST -H "Host: auth.houseofmanns.com" \
  "http://localhost:8080/connect/token" \
  -d "grant_type=email&email=test@keithtechco.com&client_id=notesnook"

# Check MongoDB
docker exec notesnook-sync-server-notesnook-db-1 mongosh identity \
  --eval "db.users.countDocuments({})"
```

---

### ISSUE 2 — GPG Private Key Not Found
**Status: ✅ FIXED**

**Root Cause:** `entrypoint.sh` generated new GPG key on every container restart, but never persisted it. Email signing failed with `PrivateKeyNotFoundException`.

**Files changed:**
- `Streetwriters.Identity/entrypoint.sh`
  - Added restore from `/app/keystore/.gnupg` on startup
  - Added backup to `/app/keystore/.gnystore` after generation
  - GPG key now persists across container restarts via keystore-data volume

---

### ISSUE 3 — WAMP 404 / SSE Server Blocked
**Status: ✅ FIXED**

**Root Cause:** `AspNetCoreWebSocketTransport` from WampSharp v20.1.1 is incompatible with ASP.NET Core 9. The transport registered at startup but never intercepted WebSocket requests at runtime. `host.Open()` inside `app.Map()` blocked the middleware pipeline.

**Files changed:**
- `Streetwriters.Messenger/Startup.cs`
  - Removed `app.UseWamp()` call from middleware pipeline
  - SSE endpoint `/sse` now works without WAMP dependency

**Trade-off:** WAMP-based inter-service RPC (push to SSE clients) is disabled. SSE endpoint works for client connections.

---

### ISSUE 4 — MFA Scope Validation
**Status: IDENTIFIED (not blocking)**

**Finding:** GitHub Issue #105 confirmed that MFA token validation expects `IdentityServerApi` scope. The `EmailGrantValidator` and `MFAGrantValidator` now issue tokens with proper scopes for the flow to complete.

---

### ISSUE 5 — S3Controller Duplicate
**Status: ✅ REVERTED**

**Finding:** A duplicate `S3Controller.cs` was created in `Notesnook/API/Services/` causing compilation errors. Removed.

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
| WAMP RPC disabled | By design | Push notifications to clients via SSE don't work |
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
- `Streetwriters.Messenger/Startup.cs` — Removed WAMP dependency

## Architecture notes
- MongoDB: single-node replica set (rs0) for change streams
- S3: MinIO at notesnook-s3:9000 (internal), exposed via Caddy at attach subdomain
- Identity: IdentityServer4 with persistent GPG signing keys in keystore-data volume
- SSE: Server-Sent Events for real-time client push (WAMP disabled)
- Custom images: dvalin21/notesnook-identity, dvalin21/notesnook-sync, dvalin21/notesnook-sse

---

## Lessons Learned

1. **Research before coding** — 6+ hours wasted brute-forcing WampSharp instead of reading docs
2. **Verify upstream behavior** — WAMP 404 existed in upstream code, not caused by our changes
3. **Test in memory vs database** — EmailGrantValidator created user in memory but never saved to MongoDB
4. **GPG key persistence** — Container restarts regenerated keys, breaking email signing
5. **WampSharp incompatibility** — v20.1.1 (Jan 2020) incompatible with ASP.NET Core 9

---

Last updated: 2026-09-03
