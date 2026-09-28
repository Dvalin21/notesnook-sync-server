# Notesnook Sync Server (Dvalin21 fork)

Self-hosted Notesnook sync backend in Docker. No .NET build required.
This fork adds operational hardening, fixed CORS wiring, per-service ASP.NET
DataProtection key persistence, and a single-port Caddy reverse proxy.

One port, all traffic:

```  
YOUR TLS PROXY :443  →  this host :8080  →  Caddy :80  →  by Host header:  
  sync.example.com     →  notesnook-server:5264  
  auth.example.com     →  identity-server:8264  
  sse.example.com      →  sse-server:7264  
  notes.example.com    →  monograph-server:3000  
  example.com          →  monograph-server:3000  
  app.example.com      →  web:80  (web client)
  attach.example.com   →  notesnook-s3:9000  
  minio.example.com    →  notesnook-s3:9090  (MinIO console — optional)  
  cors.example.com     →  cors-proxy:3000  
  inbox.example.com    →  inbox-api:5181  (optional)  
  themes.example.com   →  themes-server:9000  (optional)  
```

Clients never touch internal ports. Everything behind 8080 is plain HTTP.
Your external proxy terminates TLS.

---

## What this fork changed from upstream

1. `MONGODB_DATABASE_NAME` is honored by all repositories (upstream hardcoded "notesnook" for 7 collections).
2. `NOTESNOOK_CORS_ORIGINS` env var is wired correctly (upstream read wrong key `NOTESNOOK_CORS`).
3. Missing OAuth `profile` scope added in identity config (required by Notesnook 3.x OIDC flow).
4. Per-service ASP.NET DataProtection key volumes instead of one shared `dpdata`.
5. `init-dpdata` one-shot container fixes volume permissions automatically on first boot.
6. MongoDB is NOT exposed on a host port.
7. Healthchecks exercise the real app: `wget` against `/health` for the .NET services and Caddy, `node` for cors-proxy, `bun` for monograph and inbox. A TCP port check (`nc -z`) is *not* used — it passes the instant the socket binds, before the app has resolved Mongo or read its config, so a broken service reports healthy and the proxy routes live traffic into it.
8. App services run custom images (`dvalin21/notesnook-sync`, `-identity`, `-sse`, `-monograph`, `-web`, all `:latest` = verified build); upstream inbox/themes; infra: `caddy:alpine`, `alpine:latest`, `vandot/alpine-bash`. Monograph bakes `NOTESNOOK_APP_URL` so Publish links point at your app, not official SaaS.
9. Every service has `restart: unless-stopped` and JSON log rotation (`10m` × `3`). Applied through a merged `x-svc` anchor so they hold by construction. `willfarrell/autoheal` was **removed**: it mounted `/var/run/docker.sock` (root on the host) on `:latest`, and existed only to compensate for missing restart policies.
9. `scripts/create-minio-app-user.sh` fails fast if `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are missing, and creates the `attachments` bucket, the scoped policy and the service account.
10. Caddy internal reverse proxy routes all traffic through a single port (8080).
11. MinIO runs custom `dvalin21/minio-notesnook:latest` (console on :9090). The MinIO client is `dvalin21/mc:latest`, compiled from a pinned upstream commit (see `mc/Dockerfile`) because MinIO deleted `minio/mc` from Docker Hub in October 2025.
12. MongoDB is `8.0.30` (single-node rs0) from the official `mongo` image; .NET driver 3.2.1 is Server-8.x-ready (see Verified status). There is no `dvalin21/notesnook-db` image — it was an unused duplicate of the official Mongo image and has been removed.
13. `cors-proxy` is gated: images only (content-type allowlist), a per-client rate limit, and a domain allowlist. It is an internet-facing fetch proxy, so an open one is a liability. See [CORS proxy](#cors-proxy-corsdomain).
14. Uploads are bounded at the edge — `request_body max_size 100MB` on the sync and attach routes, so no client can buffer an unbounded body into the server.
15. The `validate` gate fails the boot if any required variable is missing, including `SELF_HOSTED`, `MINIO_ROOT_*` and `SSE_SERVER_PUBLIC_URL`.

---

## Verified status (2026-09-08, images `:latest`)

Live stack: all services healthy. Proven end to end with Android
clients on two devices: signup (seconds) → confirmation email → email
confirm → MFA-code login on both devices (mail in seconds) →
cross-device note sync → image attachments (upload, render, across
relogin) → monograph publish/view. 14/14 infrastructure checks green.

### Works
- Fresh clone → `.env` → `up -d`: boots healthy, signup works (wipe-tested Sep 9)
- Account lifecycle: signup, confirm link, email-MFA login, profile, tokens
- Notes sync both directions across devices; attachment blobs in MinIO
- Attachments >5MB in a single note (Sep 9)
- Real-mailbox delivery (confirmation + 2FA via prod SMTP)
- Rate limiting (6 MFA sends/min/user, fails fast over limit)
- Password change + reset via recovery mail; session revocation
- MFA recovery codes (`/mfa/codes`, user-verified Sep 8)
- Inbox end to end: key auth → encrypt → store → received in app (Sep 8;
  no mail involved — the relay is pure HTTP, no MX routing needed)
- Monograph viewer links point at your app domain (placeholder image +
  per-request rewrite from `NOTESNOOK_APP_HOST`)
- Volume backups: `--profile backup` round-trip tested (mongo fsyncLock
  tar + all `dpdata-*` + keystore)
- Self-host entitlements (BELIEVER); no request can hang on dead WAMP
  endpoints (retries bounded) and confirm never fails on notify errors

### Known gaps (code)
- SSE live push degraded (inter-service WAMP removed from SSE; clients poll)
- Web themes browser still queries official `themes-api.notesnook.com`
  (upstream default; cosmetic, no account data leaves)

### Not yet tested
Email change, authenticator-app MFA enrollment,
quota, refresh past 1h.

### MongoDB
This stack runs `mongo:8.0.30` (single-node rs0, FCV 8.0). App images
use MongoDB .NET driver 3.2.1, which supports Server 8.x: the prod write
path (user-row create) is proven against Server 8.0.29, and a separate
8.0.29 stack has soaked healthy for days. Upgraded from 7.0.12 in Sep 2026 (consecutive-major upgrade 7.0→8.0,
FCV stepped 7.0→8.0 post-boot). Note: 8.0.29 and older refuse to boot on
Linux kernels 6.19–7.0.13 (vendored-TCMalloc guard, SERVER-121912);
8.0.30 lifts the guard on fixed kernels (≥7.0.14).
### Ops notes
- `SELF_HOSTED` must be `1` in `.env`. At `0` the signup path calls
  cloud subscription endpoints that cannot work here and the request
  hangs until the proxy times out.
- Never `down -v` a live stack: it wipes Mongo, keystore (GPG + signing
  keys), and MinIO. Use `up -d` / `restart`; data lives in named volumes.

---
## Prerequisites

| What | Why |
|---|---|
| **Docker + Docker Compose V2** | The whole stack runs in containers. `docker compose` (with a space, not `docker-compose`). |
| **A domain you control** | All routing is by `Host:` header. You need `example.com` (replace with your real domain). |
|| **DNS** | Each subdomain below must resolve to your server's public IP. **Use a wildcard `*.example.com` A/AAAA record** — one record covers all 10. |
| **A TLS-terminating reverse proxy** | Caddy, nginx, Nginx Proxy Manager, Apache, Traefik, HAProxy, or any cloud LB. This stack exposes port 8080 with plain HTTP; your proxy adds TLS. |
| **Port 8080 open** | The stack publishes **one port**: `8080` on the host. Your TLS proxy connects here. |

### DNS records

Create **one wildcard record** pointing to your server IP:

```
*.example.com.  IN  A  203.0.113.10
```

This single record covers all subdomains the stack needs:

| Subdomain | Purpose |
|---|---|
| `sync.example.com` | Notesnook Sync API (used by Android/web clients) |
| `auth.example.com` | Identity / OAuth server |
| `sse.example.com` | Server-Sent Events / SignalR real-time sync |
| `notes.example.com` | Monograph web client |
| `example.com` | Monograph web client (apex/root) |
| `app.example.com` | Full Notesnook web client |
| `attach.example.com` | S3-compatible attachment storage (MinIO) |
|| `cors.example.com` | CORS proxy for external image embeds |
|| `inbox.example.com` | Inbox API — accepts encrypted inbox notifications POSTed by the Notesnook app (optional) |
|| `themes.example.com` | Themes server — serves theme metadata the Notesnook app fetches to render themed notes (optional) |

**Optional:** `minio.example.com` → MinIO admin console (port 9090 internal, routed via Caddy).

No wildcard support? Create individual A records — all pointing to the same IP.

---

## Architecture

### Single port model

By design, this stack publishes **one port** externally: host `:8080`.

```
Host :8080  →  Caddy :80  →  routes by Host header to correct backend
```

Internal ports `5264` / `8264` / `7264` / `3000` / `9000` / `9090` / `5181` are **NOT**
exposed to the host or to clients. They're only reachable inside the Docker
network. This is a security hardening over the upstream stack.

### .env / subdomain mapping table

| Variable | Client-facing | Caddy `Host:` | Internal target |
|---|---|---|---|
| `NOTESNOOK_APP_PUBLIC_URL` | **Yes** — Sync URL (Android + web) | `sync.example.com` | `notesnook-server:5264` |
| `AUTH_SERVER_PUBLIC_URL` | **Yes** — Auth URL (Android + web) | `auth.example.com` | `identity-server:8264` |
| `MONOGRAPH_PUBLIC_URL` | **Yes** — Web URL (web client only) | `notes.example.com` / `example.com` | `monograph-server:3000` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | **No** — server-side only | `attach.example.com` | `notesnook-s3:9000` |

The Android client has **four** URL fields in Settings → Custom server:
Sync URL, Auth URL, Events (SSE) URL, and Monograph URL.
`ATTACHMENTS_SERVER_PUBLIC_URL` is **not** entered in the client — it is used
server-side to generate S3 presigned URLs.

### MinIO / S3

MinIO provides S3-compatible object storage for note attachments. It runs
internally on port 9000. Caddy routes `attach.example.com` to it.

The MinIO admin console runs on port 9090 internally. Caddy can route
`minio.example.com` to it for admin access — this is optional.

`scripts/create-minio-app-user.sh` creates the `attachments` bucket, enables versioning on it, and provisions the bucket-scoped service account. Run it once before the first `docker compose up` — compose will not start without the `S3_ACCESS_KEY` / `S3_ACCESS_KEY_ID` values it prints.

#### ⚠️ MinIO is archived and has unpatched CVEs

**Read this before exposing `attach.<domain>` to the internet.**

`minio/minio` was **archived on 2026-04-25** and is read-only. This stack runs
the last open-source release, `RELEASE.2025-09-07T16-13-09Z`, and the advisories
state plainly:

> Affected Versions: All MinIO releases through the final release of the
> minio/minio open-source project.
> Patched versions: **None**

The fix ships only in commercial **MinIO AIStor**. There is no upstream patch to
apply to the open-source code, so this stack mitigates at the edge instead.

**CVE-2026-40344 / GHSA-9c4q-hq6p-c237** (CVSS 8.8) and
**CVE-2026-41145 / GHSA-hv4r-mvr4-25vw** — authentication bypass. Anyone holding
**just a valid access key** can write arbitrary objects to any bucket, with no
secret key and a fabricated signature. Confirmed present in this build's source:

- `cmd/object-handlers.go` — `newUnsignedV4ChunkedReader(r, true, r.Header.Get(xhttp.Authorization) != "")`
  gates signature verification on the *presence* of an `Authorization` header,
  while `isPutActionAllowed` trusts credentials taken from the
  `X-Amz-Credential` **query parameter**.
- `PutObjectExtractHandler`'s switch has no `case authTypeStreamingUnsignedTrailer`,
  so it falls through with zero signature verification.

Both advisories name a reverse-proxy block as *the* mitigation, which is what
the `Caddyfile` does:

```
@unsigned_trailer header X-Amz-Content-Sha256 STREAMING-UNSIGNED-PAYLOAD-TRAILER
respond @unsigned_trailer 403
```

Clients using the **signed** trailer variant
(`STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER`) are unaffected and still work.

**Second half of the mitigation — stop leaking the access key.** Presigned S3 URLs
carry `?X-Amz-Credential=<access key>`, and an access key alone is exactly what
CVE-2026-40344 needs. Caddy was logging the full request URI, writing the MinIO
access key to the access log on every attachment transfer. The `log` directive now
redacts `X-Amz-Credential`, `X-Amz-Signature` and `X-Amz-Security-Token` while
keeping every other query parameter, so `uploadId`/`partNumber` debugging survives.

**Residual risk, stated plainly:** this is edge mitigation, not a fix. The
vulnerable code is still in the binary. Anyone who obtains the access key by some
other route is not protected by the `X-Amz-Content-Sha256` check alone. The only
complete remedy is moving off MinIO Community Edition.

**Not affected** (verified against the advisories): CVE-2026-33322 (OIDC — not
enabled), GHSA-xh8f-g2qw-gcm7 (path traversal in `ReadMultiple` — "single-node
standalone deployments do not register the route"), CVE-2023-28432 (cluster-only).

#### Credentials

The sync server authenticates to MinIO as a **bucket-scoped service account**,
not as root. Generate it with:

```bash
bash scripts/create-minio-app-user.sh
```

It creates the `attachments` bucket if missing, enables versioning, writes a
policy, creates the user, smoke-tests put/read/delete, then prints the two
lines to add to `.env`:

```
S3_ACCESS_KEY_ID=<generated>
S3_ACCESS_KEY=<generated>
```

**The policy enumerates the object actions and nothing else.** Do not widen it
to `"s3:*"`: on a bucket resource that also grants `s3:DeleteBucket` and
`s3:PutBucketPolicy`, so the notes API would be able to delete its own bucket
and rewrite its own access policy. The script reads the stored policy back and
**refuses to continue** if it sees `s3:*`, `s3:DeleteBucket` or
`s3:PutBucketPolicy`.

> **Not a vulnerability, but worth knowing.** The .NET services take the whole
> `.env` via `env_file`, so the sync-server process still has
> `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` in its environment even though it
> never reads them. Nothing here is remotely exploitable — environment
> variables are not readable over the network, and reaching them requires code
> execution inside that container first, at which point the attacker already
> holds the Mongo credentials in `MONGODB_CONNECTION_STRING` and therefore
> already has the notes. Scoping limits what the *application code path* can
> do; it is defence in depth, not a fix. Narrowing `env_file` for the .NET
> services is not worth the regression risk: they legitimately read ~20
> variables across flows (signup, MFA, password reset, attachments, monograph)
> that cannot be fully exercised from a shell.
>
> The one place it *was* free: `cors-proxy` has no `env_file` at all. It is
> the only unauthenticated service, and it reads seven variables that compose
> passes explicitly — so it no longer receives the Mongo root password, the
> MinIO root password, the SMTP password or `NOTESNOOK_API_SECRET`.

### How attachments work

The Notesnook server has **two** S3 clients — one internal, one external:

- **Internal client** (`S3_INTERNAL_SERVICE_URL` = `http://notesnook-s3:9000`):
  Used by the server for server-side operations: initiating multipart uploads,
  completing multipart uploads, deleting objects, and server-mediated uploads
  (self-hosted mode). The client never sees this endpoint.

- **External client** (`S3_SERVICE_URL` = `ATTACHMENTS_SERVER_PUBLIC_URL` =
  `https://attach.example.com`): Used by the server to generate presigned URLs
  that the client uses for downloads and multipart upload parts.

**Upload (self-hosted):** Client sends the file to `PUT /s3?name=...` on the
sync server. The server generates an internal presigned URL, PUTs the file to
S3 itself, and returns `200 OK`. The client never talks to S3 directly for
simple uploads.

**Upload (multipart):** Client calls `POST /s3/multipart` to start. The server
initiates the multipart upload internally, then returns presigned URLs for each
part (generated with the external client / `ATTACHMENTS_SERVER_PUBLIC_URL`).
The client uploads each part directly to those presigned S3 URLs.

**Download:** Client calls `GET /s3?name=...`. The server generates a presigned
download URL using the external client (`ATTACHMENTS_SERVER_PUBLIC_URL`) and
returns it. The client downloads directly from that presigned S3 URL.

**Delete:** Client calls `DELETE /s3?name=...`. The server deletes the object
internally using the internal client.

The key point: `ATTACHMENTS_SERVER_PUBLIC_URL` is **not** a client configuration
field. The client enters only Sync, Auth, and Monograph URLs in Settings. The
server uses `ATTACHMENTS_SERVER_PUBLIC_URL` internally to build presigned URLs
that the client then consumes. If this URL is wrong, downloads and multipart
uploads break; simple uploads may still work (server uses internal URL).

### Caddy internal routing

| Host header | Routes to |
|---|---|
| `sync.example.com` | `notesnook-server:5264` |
| `auth.example.com` | `identity-server:8264` |
| `sse.example.com` | `sse-server:7264` |
| `notes.example.com` / `example.com` | `monograph-server:3000` |
| `attach.example.com` | `notesnook-s3:9000` (S3 API) |
| `minio.example.com` | `notesnook-s3:9090` (MinIO console) |
|| `cors.example.com` | `cors-proxy:3000` |
|| `inbox.example.com` | `inbox-api:5181` |
|| `themes.example.com` | `themes-server:9000` |

---

## Setup

### 1. Clone

```bash
git clone https://github.com/Dvalin21/notesnook-sync-server.git
cd notesnook-sync-server
```

### 2. Create `.env` from the template

```bash
cp .env.example .env
nano .env
```

Every `CHANGEME-*` value must be replaced. Here is every field explained:

| Variable | Required in compose? | Notes |
|---|---|---|
| `SERVER_DOMAIN` | Yes — required by `validate` service + Caddy `{$DOMAIN}` templating | Your domain, e.g. `example.com` |
| `INSTANCE_NAME` | Yes — required by `validate` service | Human name for this instance |
| `NOTESNOOK_API_SECRET` | Yes — required by `validate` service + identity server | Generate with `openssl rand -base64 48` |
| `DISABLE_SIGNUPS` | Yes — required by `validate` service | `false` to allow signups, `true` to lock down |
| `NOTESNOOK_APP_PUBLIC_URL` | Yes — required by `validate` service | `https://sync.example.com` |
| `AUTH_SERVER_PUBLIC_URL` | Yes — required by `validate` service | `https://auth.example.com` |
| `MONOGRAPH_PUBLIC_URL` | Yes — required by `validate` service + monograph container | `https://notes.example.com` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Yes — required by `validate` service | `https://attach.example.com` |
| `NOTESNOOK_APP_HOST` | Yes — required by `validate` service | Web client origin for recovery/verified links, `https://app.example.com` (NOT the sync URL) |
| `MINIO_ROOT_USER` | No — but `create-minio-app-user.sh` will fail if empty | Generate with `openssl rand -base64 12`. Not checked by `validate`; the script refuses to run if blank. |
| `MINIO_ROOT_PASSWORD` | No — but `create-minio-app-user.sh` will fail if empty | Generate with `openssl rand -base64 22`. Not checked by `validate`; the script refuses to run if blank. |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | No — optional, warn if missing | Leave blank if not using email features |
| `NOTESNOOK_CORS_ORIGINS` | No — used by `cors-proxy` only | Comma-separated origins, default `*`. Not checked by `validate`; the `cors-proxy` container receives it via env_file. |
|| `TWILIO_*` | No — optional, passed to all services | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_SERVICE_SID` for SMS 2FA via `SMSSender`. Leave empty to disable SMS 2FA. |
|| `INBOX_API_PUBLIC_URL` | No — optional, used by Notesnook app only | Public HTTPS URL for the Inbox API (e.g. `https://inbox.example.com`). The Notesnook app POSTs encrypted inbox notifications here. Set to empty string `""` to disable. |
|| `THEMES_SERVER_PUBLIC_URL` | No — optional, used by Notesnook app only | Public HTTPS URL for the Themes Server (e.g. `https://themes.example.com`). The Notesnook app queries this to fetch available theme metadata. Set to empty string `""` to disable. |
|| `THEMES_REPO_URL` | No — optional, used by themes-server container only | Git clone URL for the themes repository. The themes-server clones this on startup and serves theme metadata from it. Default: upstream `streetwriters/notesnook-themes.git`. Change only if you host your own theme repo. |

**MinIO credentials warning:** If `MINIO_ROOT_USER` or `MINIO_ROOT_PASSWORD` is empty,
`scripts/create-minio-app-user.sh` will refuse to run. Generate strong values.

### 3. Configure your TLS reverse proxy

This stack does **not** handle TLS itself. You need an external proxy that:

1. Terminates TLS for `*.example.com`
2. Forwards all requests to `http://<your-server-ip>:8080`
3. Preserves the original `Host:` header (this is how Caddy routes internally)

**Nginx Proxy Manager (NPM) — recommended:**

1. In NPM, go to **Proxies → Add Proxy Host**
2. Create **one proxy host** with these settings:

   | Field | Value |
   |---|---|
   | Domain Name | `*.example.com` (wildcard) |
   | Forward Hostname / IP | `<your-server-ip>` |
   | Forward Port | `8080` |
   | Scheme | `http` |
   | **Block common exploits** | On |
   | **Websockets Support** | On |
   | **Cache Assets** | Off (unless you know why) |
   | **Force SSL** | On |
   | **HTTP → HTTPS Redirect** | On |
   | **SSL** | Request a new Lets Encrypt certificate (or enter your own) |
   | **Secure** | On |
   | **HSTS** | On (optional) |

3. **Critical:** In the Advanced tab, add this to ensure the Host header is preserved:

   ```
   proxy_set_header Host $host;
   proxy_set_header X-Real-IP $remote_addr;
   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
   proxy_set_header X-Forwarded-Proto $scheme;
   ```

   NPM usually preserves the Host header by default, but if Caddy routing
   breaks (502 errors), add this explicitly.

4. Save. The proxy host will handle **all 10 subdomains** (`sync.`, `auth.`,
   `sse.`, `notes.`, `example.com`, `attach.`, `minio.`, `cors.`, `inbox.`, `themes.`) through a
   single wildcard entry.

5. If you prefer separate proxy hosts (one per subdomain), create 10 of them —
   each pointing to `http://<your-server-ip>:8080`. The wildcard approach is
   simpler and less error-prone.

Caddy already handles the internal routing — NPM's job is just TLS termination
and forwarding to port 8080. The Host header must reach Caddy unmodified.

**Caddy (if using Caddy as your external proxy):**

```caddy
*.example.com {
    reverse_proxy localhost:8080
}
```

**nginx:**

```nginx
server {
    listen 443 ssl;
    server_name *.example.com;
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
    }
}
```

**Cloudflare / AWS / any cloud LB:** Create a target group pointing to
`http://<your-server-ip>:8080` with host header passthrough enabled.

### 4. Start the stack

```bash
docker compose pull
docker compose up -d
```

**Watch the boot:**

```bash
docker compose logs -f
```

What you should see in order:

1. **`validate`** exits with `All required environment variables are set.`
2. **`init-dpdata`** exits with `Setting DataProtection volume permissions... Done.`
3. **`notesnook-db`** starts MongoDB and initiates a replica set
4. **`notesnook-s3`** starts MinIO S3 storage
5. **`identity-server`** starts on port 8264
6. **`notesnook-server`** starts on port 5264
7. **`sse-server`** starts on port 7264
8. **`monograph-server`** starts on port 3000
9. **`cors-proxy`** starts on port 3000
10. **`inbox-api`** starts on port 5181 (optional — set `INBOX_API_PUBLIC_URL` to enable)
11. **`themes-server`** starts on port 9000 (optional — set `THEMES_SERVER_PUBLIC_URL` to enable)
12. **`caddy`** starts routing on port 80 (mapped to host port 8080)

**First boot takes 2-5 minutes.** MongoDB replica set initialization and
.NET DataProtection key generation happen on first startup.

### 5. Verify

Once all services show `(healthy)`, test each subdomain through Caddy on port 8080. Replace `example.com` with your real `SERVER_DOMAIN`.

```bash
curl -fsS -H "Host: auth.example.com"   http://localhost:8080/health
curl -fsS -H "Host: sync.example.com"   http://localhost:8080/health
curl -fsS -H "Host: sse.example.com"    http://localhost:8080/health
curl -fsS -H "Host: notes.example.com"  http://localhost:8080/api/health
curl -fsS -H "Host: example.com"        http://localhost:8080/api/health
curl -fsS -H "Host: attach.example.com" http://localhost:8080/health
curl -fsS -H "Host: minio.example.com"  http://localhost:8080/
curl -fsS -H "Host: cors.example.com"   http://localhost:8080/health
curl -fsS -H "Host: app.example.com"    http://localhost:8080/health
curl -fsS -H "Host: inbox.example.com"  http://localhost:8080/health
curl -fsS -H "Host: themes.example.com" http://localhost:8080/health
```

Each should return `200` (or a valid page/JSON response).
`attach.*` returns `403` without credentials — that's expected (S3 requires auth).
`minio.*` returns the MinIO console HTML.
`inbox.*` and `themes.*` return `200` from their health endpoints.

There is also a smoke test that exercises the routes and the OAuth endpoint
end-to-end. It takes an optional domain argument (default `example.com`):

```bash
bash test_functional.sh
bash test_functional.sh notes.example.com
```

Expected output: every check shows `[PASS]`.

The same structural checks that CI runs — compose validity, restart/logging
invariants, volume declarations, and shell syntax of every one-shot service —
can be run locally:

```bash
./scripts/check-compose-scripts.sh
python3 scripts/check-compose.py
```

If your TLS proxy points at `localhost:8080`, these same commands work from
the host. If from another machine, replace `localhost` with your server's IP.

### 6. Create your first account

Signup can be done through the **Notesnook mobile app, desktop app, or the self-hosted web client** (see below) —
the Monograph web client (`notes.example.com`) has no registration page.

The registration endpoint is `POST /users` on the sync server
(`sync.example.com/users`), NOT the identity server. Internally the sync
server calls the identity server over HTTP (server-to-server, bearer forwarded). Your account is
created in **your MongoDB** on your server — nothing goes to Notesnook's cloud.

1. Edit `.env` and set `DISABLE_SIGNUPS=false`
2. Restart: `docker compose up -d identity-server notesnook-server`
3. **Install the Notesnook app** on your phone or desktop
4. **Configure custom servers** in the app (see below)
5. **Create your account** through the app (Sign Up)
6. **IMPORTANT**: Set `DISABLE_SIGNUPS=true` again and restart

### 7. Connect clients

**Android app — Server URLs:**

Open the Notesnook app → Settings → Sync → "Use custom server" (or similar).
Enter these exact values:

|| Field in app | Value |
|---|---|
| Sync server | `https://sync.example.com` |
| Auth server | `https://auth.example.com` |
| Events server | `https://sse.example.com` |
| Monograph server | `https://notes.example.com` |

The Android client has four URL fields (all required - the Test-connection
check validates each one). `ATTACHMENTS_SERVER_PUBLIC_URL`
is **not** entered in Settings — the server uses it internally to generate S3
presigned URLs that the client receives via the sync server's `/s3` endpoint.

**Desktop app — Server URLs:**

Settings → Servers → Add custom server. Same URLs as above.

**Web browser:**

Navigate to `https://notes.example.com` or `https://example.com` for the
Monograph web client (read-only note sharing — no account management).

**Self-hosted web client (`https://app.example.com`):**

Full Notesnook web app (notes, sync, import/export, backup, monograph
publishing) running from this stack. Server URLs are baked in at image
build time from your public URLs, so login/signup work out of the box;
they can still be changed per-browser in Settings -> Servers. Attachment
upload/download in the browser works via presigned S3 URLs (browser CORS
is answered at the proxy).

> **Your domain, not ours:** the prebuilt `dvalin21/*` images ship
> `example.com` placeholder URLs only. At boot/request they swap in your
> `.env` URLs automatically — no rebuild needed. (`web/entrypoint.sh` swaps
> the web bundle at boot; `monograph-server` rewrites per request from
> `NOTESNOOK_APP_HOST`.)

---

## Test connection from the Android app

After entering the server URLs in the app's custom server settings:

1. Tap **Test connection** or **Verify** (if the app has this button)
2. The app should reach `AUTH_SERVER_PUBLIC_URL` and discover the OIDC metadata
3. Then it should reach `NOTESNOOK_APP_PUBLIC_URL` and confirm the sync endpoint
4. If both succeed, save the configuration
5. Use **Sign up** to create your first account (if `DISABLE_SIGNUPS=false`)

If the test fails:

| Symptom | Likely cause | Fix |
|---|---|---|
| "Cannot reach server" / timeout | URLs are wrong or server not reachable from the device | Verify the URLs resolve from your phone's network. Check that port 8080 is reachable. |
| SSL certificate error | Self-signed cert or wrong domain in URL | Make sure you're using `https://` with a valid certificate for the exact domain. |
| "Invalid server" / "Not a Notesnook server" | The URL points to the wrong service or returns an error | Double-check that `AUTH_SERVER_PUBLIC_URL` points to `auth.example.com` (identity server), not the sync server. |
| Signup fails after successful test | `DISABLE_SIGNUPS=true` or SMTP issue | Set `DISABLE_SIGNUPS=false` temporarily, restart identity-server, try again. |

---

## Optional services

Two optional services are included in the stack: **inbox-api** and **themes-server**. They are not required for basic Notesnook sync functionality — the core stack (sync, auth, SSE, monograph, attachments, CORS) works without them.

### Inbox API (`inbox.<domain>`)

The Inbox API is a small Express service that receives encrypted inbox notifications from the Notesnook app and relays them to the sync server. It is used when one Notesnook user sends an inbox message to another.

**What it does:**
1. Receives a POST request with an encrypted payload and an API key
2. Fetches the recipient's public encryption key from the sync server
3. Re-encrypts the payload with that public key (OpenPGP / AES-256)
4. Posts the encrypted blob back to the sync server's `/inbox/items` endpoint

**How the app uses it:** The Notesnook app is configured with `INBOX_API_PUBLIC_URL` (e.g. `https://inbox.example.com`). When an inbox message is sent, the app POSTs to that URL. You do not browse this service — it has no web UI. The only endpoint is `POST /` (plus `GET /health` for health checks). `GET /` returns 404 by design — there is no GET handler.

**Config:** Set `INBOX_API_PUBLIC_URL=https://inbox.<your-domain>` in `.env`. Leave it empty (`""`) to disable. The service is always started by Docker Compose; disabling is done by not pointing the app at it.

**Internal URL:** The `NOTESNOOK_API_SERVER_URL` env var inside the container is set to `http://notesnook-server:5264` (the internal Docker network address). You do not need to set this in `.env` — it is already configured in `docker-compose.yml`.

### Themes Server (`themes.<domain>`)

The Themes Server is a TRPC service that clones the `notesnook-themes` Git repository and serves theme metadata to the Notesnook app. The app queries it to discover which themes are available for rendering notes.

**What it does:**
1. On startup, clones the Git repo specified by `THEMES_REPO_URL` into the container
2. Generates metadata from the cloned themes
3. Serves theme list/metadata via TRPC procedures over HTTP

**How the app uses it:** The Notesnook app is configured with `THEMES_SERVER_PUBLIC_URL` (e.g. `https://themes.example.com`). The app makes TRPC calls to fetch the theme list. You do not browse this service — it has no web UI. `GET /` returns a TRPC 404 error by design — TRPC handles all requests through its procedure router, and there is no procedure registered for the empty path.

**Config:** Set `THEMES_SERVER_PUBLIC_URL=https://themes.<your-domain>` in `.env`. Leave it empty (`""`) to disable. Set `THEMES_REPO_URL` to a different Git URL only if you host your own theme repository.

**Data persistence:** The themes data (cloned Git repo + generated metadata) lives inside the container at `/app/notesnook-themes/`. It is re-cloned from `THEMES_REPO_URL` on every container start. The `themesdata` Docker volume persists only `installs.json` (usage tracking), which is optional.

### CORS proxy (`cors.<domain>`)

The Notesnook app uses this to render external images in notes. It is an
**internet-facing fetch proxy**, which is a liability if left open, so it is
gated three ways:

1. **Images only.** Responses whose `Content-Type` is not `image/*` get `403`
   before a single byte is forwarded. This is the control that matters — it
   stops the proxy being used to launder arbitrary HTML or phishing pages
   through your domain.
2. **Domain allowlist** — `NOTESNOOK_CORS_DOMAINS`. Unlisted hosts get `400` and
   the URL is logged. Default:
   `imgur.com,wikimedia.org,githubusercontent.com,github.com,github.io,youtube.com,youtube-nocookie.com,redd.it,redditmedia.com`
   Matching is by suffix, so `thumb.wikimedia.org` is covered by `wikimedia.org`.
   **When an image fails to render, add its host here** and restart the service.
3. **Rate limit** — `CORS_RATE_LIMIT` requests per `CORS_RATE_WINDOW_MS` per
   client (default 120/min).

> The YouTube domains must stay in the allowlist. The service validates the URL
> *before* it checks for a YouTube embed, so an allowlist without them silently
> breaks video embeds.

Responses are streamed, not buffered, so a large image cannot exhaust the
container's memory.

### Disabling optional services

To run the stack without inbox-api and themes-server:

1. Set `INBOX_API_PUBLIC_URL=""` and `THEMES_SERVER_PUBLIC_URL=""` in `.env`
2. Remove the `inbox-api` and `themes-server` service blocks from `docker-compose.yml`
3. Remove the `@inbox` and `@themes` handle blocks from `Caddyfile`
4. Remove `inbox.<domain>` and `themes.<domain>` from your DNS

Or leave the services running but unconfigured — they consume minimal resources and only serve requests when the app is pointed at them.

---

## MinIO admin login

- Console URL:  **https://minio.example.com** (optional — routed via Caddy)
- S3 API URL:   **https://attach.example.com** (used by the Notesnook app)
- Username: value of `MINIO_ROOT_USER` in `.env`
- Password: value of `MINIO_ROOT_PASSWORD` in `.env`

---

## Maintenance

### Backups

Three layers; no single one restores everything (see `backup.sh` header for the why):

```bash
# 1. Stack state: Mongo (fsyncLock + tar) + all dpdata-* + keystore + .env snapshot.
#    Dumps land in ./backups/<UTC-stamp>/ (gitignored, mode 0700 — it contains
#    live credentials). Copy off-host, or rely on a whole-VM snapshot for the
#    crash-consistent layer.
docker compose --profile backup run --rm backup

# 2. Attachments (bulk blobs) are ALSO in layer 1 now, as `s3data.tgz`.
#    They used to be excluded on the theory that MinIO versioning plus a PBS
#    snapshot covered them -- neither was true, and a stray account removed the
#    whole bucket with nothing to restore from. A mirror is still worth having
#    for off-host copies:
source .env
docker run --rm --network notesnook-sync-server_notesnook \
  -e MC_HOST_src=http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@notesnook-s3:9000 \
  -v /backup/s3:/dest dvalin21/mc:latest \
  mirror --overwrite src/attachments /dest

# 3. Per-user client exports (web UI → Backup). Ultimate parachute: restores notes
#    into ANY Notesnook, but carries no accounts/shares/keys. Users own this one.
```

Layer 1 archives `s3data` alongside the rest. For a very large `s3data` you may
prefer to drop it from the loop and rely on the mirror plus PBS.

`backup.sh` **fails loudly**. It exits non-zero if any volume fails to archive or
produces an empty archive, and prints `BACKUP_FAILED`. An earlier version printed
`SKIP` per unmounted volume, wrote a 20-byte archive of the missing directory and
still printed `BACKUP_OK` with exit 0 — a monitor wired to that string reported a
healthy backup of nothing. `tar` exit 1 ("changed while reading") is treated as a
**warning**, not a failure: `fsyncLock` blocks client writes but WiredTiger still
advances its own journal, so `dbdata` is never fully static. Only tar exit ≥ 2
(cannot open, out of space) is fatal.

A whole-VM snapshot (Proxmox PBS, vzdump, ZFS) is a valid *crash-consistent*
layer, but it is not application-consistent: a mongod snapshots mid-write needs
WiredTiger recovery on restore. Layer 1 is what removes that risk.

Restore order: `.env` → volumes back in place → `up -d` → users re-login only if
dpdata was lost. Loss matrix: no dpdata = sessions die (data safe); no keystore =
regenerate GPG (old verify links die); no `.env` = rebuilt stack, everyone re-registers.

### Updates

```bash
git pull
docker compose pull
docker compose up -d
```

Review `docker compose config` output before applying — the compose file uses
merge anchors (`x-svc`, `x-app-env`) so that restart policy and log rotation are
applied to every service by construction.

### Disaster recovery: DataProtection keys

The `dpdata-*` volumes store ASP.NET DataProtection keys. These keys
validate authentication cookies and tokens. If you lose these volumes,
all users will be logged out and must sign in again.

There are exactly three: `dpdata-identity`, `dpdata-notesnook`, `dpdata-sse`.
(`dpdata-monograph` was removed — `monograph-server` is a Bun image with no
ASP.NET DataProtection, so that volume was permanently empty.)

Back them up alongside your MongoDB backup, or simply use layer 1 above:
  docker run --rm -v notesnook-sync-server_${vol}:/data -v /backup/dpdata:/backup \
    alpine tar czf /backup/dpdata/${vol}-$(date +%Y%m%d).tar.gz -C /data .
done
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `validate` exits with error | Missing env var | Check `.env` — every `CHANGEME` must be replaced. Run `docker compose run validate`. |
| `UnauthorizedAccessException` in .NET logs | DataProtection volume permissions | `init-dpdata` handles this automatically. If pre-existing volumes are broken: `sudo chown -R 1000:1000 /var/lib/docker/volumes/notesnook-sync-server_dpdata-*/_data` |
| MongoDB won't start / replica set fails | Long first boot | Wait 2-5 minutes. Check with `docker compose logs notesnook-db`. |
| Caddy returns 502 | Backend not ready | Wait for all services to show `(healthy)` in `docker compose ps`. |
| "invalid_grant" on OAuth | No account exists yet | Enable signups (`DISABLE_SIGNUPS=false`), create an account, then disable again. |
[Verify `NOTESNOOK_APP_PUBLIC_URL`, `AUTH_SERVER_PUBLIC_URL` in `.env` exactly
match what you put in the app. `ATTACHMENTS_SERVER_PUBLIC_URL` is server-side
only — the client receives presigned URLs from the sync server, never enters
it in Settings.]
| `cors.example.com` shows JSON usage page | That's normal | The CORS proxy is an **API**, not a web page. `GET /` returns instructions. Use `GET /health` to check it's alive. |
| Web client shows blank page | Monograph needs API_HOST | Check `docker compose logs monograph-server`. It should connect to `notesnook-server:5264`. |
| Port conflict on 8080 | Another service uses that port | Change the host port in `docker-compose.yml` (e.g., `8080:80` → `8081:80`) and update your TLS proxy. |
| SMTP warning in logs | SMTP not configured | This is normal if you don't need email 2FA. Configure SMTP_* in `.env` if you want email-based 2FA or password reset. |

---

## Secrets hygiene

- `.env` is gitignored. If `.env` is present in the working tree, it may
  contain live credentials and should not be committed.
- `.env.example` IS committed and contains placeholders only — `example.com`
  and `CHANGEME-*` values.
- Sanitize before committing any docs or scripts: strip real domains and
  credentials.

---

## License

AGPLv3. See upstream LICENSE file.
