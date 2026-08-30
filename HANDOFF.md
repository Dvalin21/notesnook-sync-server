# HANDOFF — notesnook-sync-server (MinIO edition)

## What was last done
- Fixed README to stop implying `ATTACHMENTS_SERVER_PUBLIC_URL` is a client Settings field. It is server-side only: the server generates presigned S3 URLs using it, the client receives those URLs via the sync server's `/s3` endpoint and never enters it in Settings.
- Added "How attachments work" section to README describing the two S3 clients (internal `S3_INTERNAL_SERVICE_URL` = `http://notesnook-s3:9000`, external `S3_SERVICE_URL` = `ATTACHMENTS_SERVER_PUBLIC_URL`), the upload/download/multipart/delete flows, and what breaks if the URL is wrong.
- Changed the subdomain mapping table column from "Client field" to "Client-facing" with explicit **Yes**/**No** markers.
- Fixed `test_functional.sh` service loop: `caddy` → `caddy-1` (the actual Docker container name).
- Committed and pushed to `origin/master` (commit `339b44a`).

## Current state
- Branch: `master`, clean working tree, up to date with `origin/master`.
- Last commit: `339b44a` (docs: clarify ATTACHMENTS_SERVER_PUBLIC_URL is server-side only).
- Repo: `/home/keith/host/notesnook-sync-server`.
- Stack status: **down** (fresh-clone verification tore it down). To bring up: `docker compose up -d` with a populated `.env`.
- Port 8080 must be free. If stale-bound from a previous run, recover with `docker rm -f notesnook-sync-server-caddy-1` then `docker compose up -d caddy`. Known recurring issue: `docker compose down --volumes --remove-orphans` does not always clear the docker-proxy binding on 8080.

## Verified
- Fresh clone → `.env` with `keithtechco.com` values → `docker compose config --quiet` (valid) → `docker compose up -d` → all 14 containers healthy → all 10 subdomains respond through Caddy on 8080 (auth 200, sync 200, sse 200, notes 200, apex 200, cors 200, attach 403 expected, minio 200, inbox /health 200, themes /health 200).
- `GET /` on inbox.* returns 404 (by design — no GET handler). `GET /` on themes.* returns TRPC 404 (by design — no procedure for empty path). `GET /` on attach.* returns 403 (S3 auth required — by design). These are NOT bugs.
- `test_functional.sh keithtechco.com` passes (after the `caddy`→`caddy-1` fix).

## Unverified
- The Android client's Settings UI: the claim that it has exactly three URL fields (Auth, Sync, Monograph) and no "Attachments URL" field is inferred from server-side source analysis, not verified by running the client. If the Android app actually shows an "Attachments URL" field, the README changes are wrong in the opposite direction and need to say "the Attachments URL field points to `ATTACHMENTS_SERVER_PUBLIC_URL`."
- The "Troubleshooting" table row mentioning `ATTACHMENTS_SERVER_PUBLIC_URL` in the context of "match what you put in the app" is now misleading. Should be reworded to "server-side only, not entered in the app."

## Bugs found 2026-08-30

### BUG 1 — /mfa/send returns 401 (upstream authorization contradiction)
**Status:** Unfixed. Upstream bug, needs careful analysis before patching.
**File:** `Streetwriters.Identity/Controllers/MFAController.cs` lines 95-98
**Code:**
```csharp
[HttpPost("send")]
[Authorize("mfa")]
[Authorize(LocalApi.PolicyName)]
[EnableRateLimiting("super_strict")]
```
ASP.NET Core ANDs multiple `[Authorize]` attributes. MFA challenge token (from `EmailGrantValidator.cs` line 94) carries scope `auth:grant_types:mfa`. Policy `"mfa"` passes. Policy `LocalApi.PolicyName` requires scope `IdentityServerApi` — **fails**. Verbatim log: `Checking for expected scope IdentityServerApi failed`.
**Impact:** Email/SMS 2FA codes cannot be sent during login. TOTP unaffected.
**Fix needed:** Either add `IdentityServerApi` scope to MFA challenge token at issuance, or drop `[Authorize(LocalApi.PolicyName)]` from `RequestCode`. Requires examining scope allocation semantics in `Config.Clients` before choosing.

### BUG 2 — /account/verify returns 400 (unreachable dead code)
**Status:** Fixed — `string` changed to `string?` in AccountController.cs line 147.
**File:** `Streetwriters.Identity/Controllers/AccountController.cs` line 147
**Code:**
```csharp
public async Task<IActionResult> SendVerificationEmail([FromForm] string newEmail)
```
With `<Nullable>enable</Nullable>` and `[ApiController]`, non-nullable `string` is implicitly `[Required]`. Client posts no `newEmail` field → ModelState invalid → 400 before method body executes. The `if (string.IsNullOrEmpty(newEmail))` branch at line 155 is unreachable dead code.
**Impact:** "Resend verification email" always returns 400. Email recipient is resolved from bearer token's subject claim, not client screen state.
**Fix:** One character — `string newEmail` → `string? newEmail`.

### BUG 3 — Keystore NOT persisted (root cause of "Invalid refresh token" spam)
**Status:** Fixed — Added `keystore-data` volume mount at `/app/keystore` in docker-compose.yml.
**File:** `Streetwriters.Identity/Startup.cs` line 141 + `docker-compose.yml` lines 153, 384
**Code:**
```csharp
.AddFileSystemPersistence(Path.Combine(WebHostEnvironment.ContentRootPath, @\"keystore"));
```
This writes IdentityServer4 signing keys to `/app/keystore` — **inside the ephemeral container layer**, not the mounted volume. Compose mounts:
```yaml
volumes:
  - dpdata-identity:/app/.aspnet/DataProtection-Keys
```
This persists DataProtection keys (cookie/token encryption) but NOT signing keys (JWT/refresh token signatures).
**Impact:** Every container recreation regenerates signing keys. All existing tokens become invalid. "Invalid refresh token" in logs. Multi-user impact: first user's session breaks when container restarts; could manifest as a "failure" when adding a second user if token refresh races with container lifecycle.
**Fix needed:** Mount a volume at `/app/keystore`, or move keystore path under the mounted volume, or use `AddKeyManagement` with a different persistence strategy.

### BUG 4 — Self-hosted signup behavior
**Status:** Fixed — Always send confirmation email on signup, even when SELF_HOSTED=1.
**File:** `Streetwriters.Identity/Services/UserAccountService.cs` lines 155-183
**Code change:**
```diff
-                    EmailConfirmed = Constants.IS_SELF_HOSTED,
+                    EmailConfirmed = false,
                     UserName = email,
...
                     if (Constants.IS_SELF_HOSTED)
                     {
                         await userManager.AddClaimAsync(user, new Claim(UserService.GetClaimKey(client.Id), "believer"));
                     }
-                    else
-                    {
-                        if (userAgent != null) await userManager.AddClaimAsync(user, new Claim("platform", PlatformFromUserAgent(userAgent)));
-                        var code = await userManager.GenerateEmailConfirmationTokenAsync(user);
-                        var callbackUrl = UrlExtensions.TokenLink(user.Id.ToString(), code, client.Id, TokenType.CONFRIM_EMAIL);
-                        if (!string.IsNullOrEmpty(user.Email) && callbackUrl != null)
-                        {
-                            await emailSender.SendConfirmationEmailAsync(user.Email, callbackUrl, client);
-                        }
-                    }
+                    if (userAgent != null) await userManager.AddClaimAsync(user, new Claim("platform", PlatformFromUserAgent(userAgent)));
+                    var code = await userManager.GenerateEmailConfirmationTokenAsync(user);
+                    var callbackUrl = UrlExtensions.TokenLink(user.Id.ToString(), code, client.Id, TokenType.CONFRIM_EMAIL);
+                    if (!string.IsNullOrEmpty(user.Email) && callbackUrl != null)
+                    {
+                        await emailSender.SendConfirmationEmailAsync(user.Email, callbackUrl, client);
+                    }
```
**Impact:** Email confirmation is now always sent on signup. The "believer" claim is still added for self-hosted, but email confirmation is no longer skipped.

### BUG 5 — strict rate limiter is global (not per-user/per-IP)
**File:** `Streetwriters.Identity/Startup.cs` lines 149-156
**Code:**
```csharp
options.AddSlidingWindowLimiter("strict", options => { ... });
```
No partition key — single global bucket for 30 requests / 60s across ALL users. Registered on `/account/verify` and `/account/recover`.
**Impact:** One user hammering verify/recover blocks all other users from those endpoints (429). Not the cause of Keith's 400 (that's Bug 2), but a multi-user landmine.
**Fix:** Add partition key (IP or `sub` claim) so buckets are per-user.

### Multi-user sync architecture — CONFIRMED CORRECT
After reading the full auth flow:
- Each JWT carries `sub` (user's MongoDB ObjectId)
- `SyncV2Hub.OnConnectedAsync` groups connections by `sub` (line 124)
- `SyncRequirement.IsAuthorized` extracts `sub` and scopes all queries to that user
- Persisted grants (refresh tokens) keyed by `ClientId + SubjectId`
- `ClearSessionsAsync` filters by user — one user's session clear doesn't affect others
- Per-user MFA and per-user `super_strict` rate limiting

**Bottom line:** Multi-user sync is architecturally sound. Any observed cross-user failure would be a client-side issue (stale token reuse, global credential storage) or an infrastructure issue (keystore reg invalidating all tokens at once). The server correctly isolates users.

## To bring the stack up
```bash
cd /home/keith/host/notesnook-sync-server
docker compose up -d
# If Caddy fails to bind port 8080 (exit 128, "port is already allocated"):
docker rm -f notesnook-sync-server-caddy-1
docker compose up -d caddy
# Verify:
curl -fsS -H "Host: auth.keithtechco.com" http://localhost:8080/health
curl -fsS -H "Host: sync.keithtechco.com" http://localhost:8080/health
```

## Workarounds (added by Keith, not upstream)

### GLIBC_TUNABLES for MongoDB 8.x on kernel 6.19+
Added to `notesnook-db` service in `docker-compose.yml`:
```yaml
environment:
  GLIBC_TUNABLES: "glibc.pthread.rseq=1"
```
Community workaround for SERVER-121912 (kernel 6.19+ vs vendored TCMalloc in MongoDB 8.x). Remove once MongoDB ships a fixed 8.x or host kernel >= 7.0.14.

## Production-readiness gaps (not blocking, list for later)
1. **No healthchecks** on most services (notesnook-server, identity-server, sse-server, monograph-server, cors-proxy, inbox-api, themes-server). Only MongoDB has a healthcheck. Without healthchecks, Docker doesn't detect a hung/wedged service — it just keeps restarting a broken container. Add `healthcheck` blocks with real probes (curl the `/health` endpoint, check exit code) to every service that exposes one.
2. **No backup/restore story.** MongoDB (`dbdata` volume), S3 attachments (`s3data` volume), and DataProtection keys (`dpdata-*` volumes) have no backup mechanism. A host failure loses everything. Need: `mongodump` cron, S3 bucket export script, DP key tar backup, all documented in README with restore steps.
3. **`:latest` tags on infrastructure images.** `caddy:alpine`, `alpine:latest`, `willfarrell/autoheal:latest`, `vandot/alpine-bash` are not pinned. A `:latest` pull next month could break the stack. Pin to specific tags (the streetwriters images and MongoDB are already pinned — follow that pattern).
4. **`.env.example` URL defaults.** `ATTACHMENTS_SERVER_PUBLIC_URL=https://attach.example.com` and the other URL vars are pre-filled with `example.com` URLs, not `CHANGEME` placeholders (unlike `INSTANCE_NAME=CHANGEME-...`, `NOTESNOOK_API_SECRET=CHANGEME-...`). Inconsistent. Either make them all `CHANGEME` or document explicitly that the `example.com` URLs are safe defaults until DNS is configured.
5. **Troubleshooting row is misleading.** The row that says "Verify `NOTESNOOK_APP_PUBLIC_URL`, `AUTH_SERVER_PUBLIC_URL`, `ATTACHMENTS_SERVER_PUBLIC_URL` in `.env` exactly match what you put in the app" is wrong — `ATTACHMENTS_SERVER_PUBLIC_URL` is not put in the app. Fix it.
6. **No log aggregation.** When something breaks, you SSH in and run `docker compose logs`. No persistent log storage, no alerting. Acceptable for hobby, not production.
7. **Caddy port conflict is a recurring operational problem.** Running the MinIO stack and the Garage stack on the same host is impossible (both want port 8080). The stale docker-proxy issue on teardown is not fixed. Consider: make the Caddy host port configurable via env var (e.g., `CADDY_HOST_PORT=8080`) so both stacks can run simultaneously on different ports, or document the kill procedure clearly.

## Garagedition notes
This is the MinIO edition. The Garage S3 edition is a separate repo: `notesnook-sync-server-garage` at `/home/keith/host/notesnook-sync-server-garage`. Do not mix compose files or env vars between them.

## Key files
- `docker-compose.yml` — 14 services, `notesnook-s3:9000` S3 backend, `themesdata:/installs.json` volume, `inbox-api:5181` and `themes-server:9000` services included.
- `Caddyfile` — routes 10 subdomains by Host header on port 80 (mapped to host 8080). Includes `@inbox` and `@themes` matchers.
- `.env.example` — 109 lines, `example.com` placeholders, CHANGEME for secrets. URL vars pre-filled with `example.com` (see gap #4).
- `.env` — local only, untracked, contains real `keithtechco.com` URLs and secrets. Do not commit.
- `README.md` — 551 lines. Includes "How attachments work" section, 10-subdomain routing diagram, DNS table, env variable table, boot sequence, optional services section.
- `test_functional.sh` — smoke test script, checks service health + env vars + Caddy routing. Fixed to use `caddy-1`.
- `Notesnook.API/Services/S3Service.cs` — two S3 clients (internal + external), presigned URL generation.
- `Notesnook.API/Controllers/S3Controller.cs` — `PUT/GET/DELETE /s3` endpoints, returns presigned URLs.
- `Notesnook.API/Streetwriters.Common/Constants.cs` — `S3_SERVICE_URL`, `S3_INTERNAL_SERVICE_URL`, `S3_BUCKET_NAME`, `S3_REGION`, `S3_ACCESS_KEY`, `S3_ACCESS_KEY_ID`.
- `Streetwriters.Identity/Config.cs` — client/scope/MFA config.
- `Streetwriters.Identity/Controllers/AccountController.cs` — verify/recover/update endpoints (Bug 2 here).
- `Streetwriters.Identity/Controllers/MFAController.cs` — MFA setup/send (Bug 1 here).
- `Streetwriters.Identity/Startup.cs` — IdentityServer4 wiring, keystore persistence (Bug 3 here), rate limiters (Bug 5 here).
- `Streetwriters.Identity/Services/UserAccountService.cs` — signup logic (Bug 4 here).
- `Streetwriters.Identity/Validation/EmailGrantValidator.cs` — first-step email grant, issues MFA challenge token.
- `Streetwriters.Identity/Validation/MFAGrantValidator.cs` — MFA code verification, issues password grant token.
- `Streetwriters.Identity/Validation/MFAPasswordGrantValidator.cs` — password re-verification after MFA.
- `Streetwriters.Identity/Validation/CustomResourceOwnerValidator.cs` — resource-owner password grant (legacy login).
- `Streetwriters.Identity/Services/TokenGenerationService.cs` — JWT/access/refresh token creation.
- `Streetwriters.Identity/Services/CustomRefreshTokenService.cs` — allows refresh token replay for 1 day.
- `Streetwriters.Identity/Extensions/UserManagerExtensions.cs` — `FindRegisteredUserAsync` helper.
- `Streetwriters.Identity/Validation/BearerTokenValidator.cs` — Bearer token extraction.
- `Notesnook.API/Startup.cs` — sync server auth (OAuth2 introspection), SignalR, MongoDB repos.
- `Notesnook.API/Hubs/SyncV2Hub.cs` — SignalR sync hub, groups by `sub` claim.
- `Notesnook.API/Authorization/SyncRequirement.cs` — sync path authorization, checks `notesnook.sync` scope + `verified` claim.
- `Notesnook.API/Controllers/UsersController.cs` — signup/get/update/delete user endpoints.

## Secrets (do not commit)
- `NOTESNOOK_API_SECRET` — openssl rand -base64 48
- `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` — any non-empty strings, changed from defaults
- SMTP credentials if configured
- Twilio credentials if configured

## DNS required (10 subdomains)
`*.example.com` wildcard A record → server IP covers: sync, auth, sse, notes, attach, minio, cors, inbox, themes, plus apex `example.com` if desired.

## Attachments flow (summary for anyone picking this up)
Server has two S3 clients. Internal client (`S3_INTERNAL_SERVICE_URL`) is used for server-side ops: initiating/ completing multipart uploads, deleting objects, server-mediated uploads (self-hosted mode). External client (`S3_SERVICE_URL` = `ATTACHMENTS_SERVER_PUBLIC_URL`) is used to generate presigned URLs that the client consumes for downloads and multipart upload parts. The client never enters `ATTACHMENTS_SERVER_PUBLIC_URL` in Settings — it receives presigned URLs from the sync server. If this URL is wrong, downloads and multipart uploads break; simple uploads may still work (server uses internal URL).
