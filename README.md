# Notesnook Sync Server (fork of streetwriters/notesnook-sync-server)

Full source for the Notesnook sync backend (Notesnook / Streetwriters). AGPLv3 licensed.

This fork contains operational hardening fixes (CORS env-var, MONGODB_DATABASE_NAME, restart policies, DataProtection key persistence, image pinning, Caddy reverse proxy, autoheal, cors-proxy). The original upstream README and INSTALL are superseded by this file.

**This branch uses MinIO** as the default object storage backend. If you want the Garage S3 backend, see the `garage-migration` branch.

## What this stack runs (all in Docker)

| Service | Port | Description |
|---|---|---|
| caddy | 8080→80 | Internal reverse proxy — routes by Host header to all services |
| identity-server | 8264 | Authentication & signup |
| notesnook-server | 5264 | Sync engine |
| sse-server | 7264 | Server-sent events for real-time sync |
| monograph-server | 6264→3000 | Web client (published notes viewer) |
| cors-proxy | — | CORS proxy for web app (fetches external resources) |
| notesnook-db | — | MongoDB 8.0.28 replica set |
| notesnook-s3 | 9000 / 9090 | MinIO S3 storage + web console (internal only, reached through Caddy) |
| setup-s3 | — | One-shot bucket creator (runs once, then stops) |
| autoheal | — | Restarts any container Docker marks unhealthy |

MinIO ports are NOT exposed to the host. The S3 API (`attach.*`) and web console (`minio.*`) are accessible only through the internal Caddy proxy. Direct API ports (5264, 8264, 7264, 6264) remain exposed for debugging.

## Quick start (the caveman version)

```bash
# 1. Clone the repo (fork with reliability fixes applied)
git clone https://github.com/streetwriters/notesnook-sync-server.git
cd notesnook-sync-server

# 2. Copy the template env file and set real values
cp .env .env.local
nano .env.local   # edit ALL the values — see settings below

# 3. Start everything
docker compose up -d

# 4. Watch it boot
docker compose logs -f
# wait for "All required environment variables are set." from validate service

# 5. Check health
curl -fsS http://localhost:5264/health && echo " sync OK"
curl -fsS http://localhost:8264/health && echo " auth OK"
curl -fsS http://localhost:7264/health && echo " sse OK"
curl -fsS http://localhost:6264/api/health && echo " monograph OK"
curl -fsS http://localhost:8080/health && echo " caddy OK"

# 6. Verify all containers healthy
docker compose ps

# 7. Open monograph in browser (behind YOUR TLS proxy)
#    http://monogr.ph  (or whatever MONOGRAPH_PUBLIC_URL you set)
```

That's it. If anything fails, `docker compose logs <service name>` shows why.

## Settings — what every env var does

Copy `.env` to `.env.local`, never commit `.env.local` to git.

### Required

| Variable | What it does | Example |
|---|---|---|
| `INSTANCE_NAME` | Human name for this server | `my-notesnook` |
| `NOTESNOOK_API_SECRET` | API auth secret (must differ from upstream). Generate with `openssl rand -base64 48`. | `a1b2c3...` |
| `DISABLE_SIGNUPS` | `true` = nobody can register new accounts (recommended). `false` = open registration. | `true` |
| `SMTP_HOST` | Outgoing mail server hostname | `smtp.example.com` |
| `SMTP_PORT` | Outgoing mail server port | `587` |
| `SMTP_USERNAME` | SMTP login user | `alerts@example.com` |
| `SMTP_PASSWORD` | SMTP login password | `***` |
| `SMTP_FROM_NAME` | Sender name in emails | `My Notesnook` |
| `AUTH_SERVER_PUBLIC_URL` | Base URL the Notesnook app uses to reach identity-server | `https://auth.mydomain.com` |
| `NOTESNOOK_APP_PUBLIC_URL` | Base URL the app uses to reach sync server | `https://sync.mydomain.com` |
| `MONOGRAPH_PUBLIC_URL` | Base URL for the web client | `https://mydomain.com` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Base URL where S3 attachments are reachable (via your TLS proxy → Caddy → MinIO) | `https://attach.mydomain.com` |

### Optional (defaults work for most)

| Variable | Default | What |
|---|---|---|
| `SERVER_DOMAIN` | `localhost` | Domain for Caddy hostname-based routing. Match this to your external TLS proxy's routing domain. |
| `MONGODB_DATABASE_NAME` | `notesnook` | MongoDB database name. Changing it now honors the env var (was hardcoded before). |
| `NOTESNOOK_CORS_ORIGINS` | *(empty)* | Comma-separated list of allowed browser CORS origins. Leave empty = any origin allowed (fine behind your TLS proxy). |
| `MINIO_ROOT_USER` | `minioadmin` | MinIO admin user. `minioadmin` default is well-known — change it. |
| `MINIO_ROOT_PASSWORD` | `minioadmin` | MinIO admin password. Same warning. |
| `IS_SELF_HOSTED` | *(auto)* | Set automatically based on `AUTH_SERVER_PUBLIC_URL` format. Don't touch unless you know why. |

## How to install — full step by step

### Prerequisites

- Docker and Docker Compose v2 on a Linux host.
- A domain or LAN IP you control. Notesnook clients need fixed URLs.
- Ports you'll use (the stack exposes these to the host; your TLS proxy connects to them):
  - **8080** — Caddy (internal reverse proxy, unified entry point). **Recommended for all external traffic.**
  - 5264 — sync (direct, for debugging)
  - 8264 — auth (direct, for debugging)
  - 7264 — SSE (direct, for debugging)
  - 6264 — web client (direct, for debugging)
  - MinIO ports (9000, 9090) are **internal only** — never exposed to the host.
- Minimum 2 GB RAM, a few GB disk for notes + attachments.

### Step 1 — get the code

```bash
cd ~/host
git clone https://github.com/streetwriters/notesnook-sync-server.git
cd notesnook-sync-server
```

### Step 2 — generate strong secrets

```bash
# API secret (use this for NOTESNOOK_API_SECRET)
openssl rand -base64 48

# MinIO admin credentials
openssl rand -base64 12   # username (min 3 chars)
openssl rand -base64 22   # password (min 8 chars)
```

### Step 3 — configure the env file

```bash
cp .env .env.local
nano .env.local
```

Set the Required variables from the table above. The `.env` template has placeholder values — replace every one of them.

Set `SERVER_DOMAIN` to your domain (e.g., `example.com`). This controls Caddy's hostname routing.

### Step 4 — set up TLS / external reverse proxy

This stack has Caddy running inside it for internal routing, but it speaks plain HTTP. Put a TLS-terminating proxy in front (Caddy, nginx, Traefik, Cloudflare Tunnel, etc.).

The internal Caddy routes by Host header:

| External URL | Host header | Route to |
|---|---|---|
| `https://sync.mydomain.com` | `sync.mydomain.com` | `notesnook-server:5264` |
| `https://auth.mydomain.com` | `auth.mydomain.com` | `identity-server:8264` |
| `https://sse.mydomain.com` | `sse.mydomain.com` | `sse-server:7264` |
| `https://notes.mydomain.com` | `notes.mydomain.com` | `monograph-server:3000` |
| `https://attach.mydomain.com` | `attach.mydomain.com` | `notesnook-s3:9000` (S3 API) |
| `https://minio.mydomain.com` | `minio.mydomain.com` | `notesnook-s3:9090` (MinIO console) |
| `https://cors.mydomain.com` | `cors.mydomain.com` | `cors-proxy:3000` |
| Any unmatched host | — | `monograph-server:3000` (default) |

Configure your external TLS proxy to forward all these subdomains to `http://<host>:8080` (Caddy's port). Example nginx snippet:

```nginx
server {
    listen 443 ssl;
    server_name sync.mydomain.com auth.mydomain.com sse.mydomain.com
                notes.mydomain.com attach.mydomain.com minio.mydomain.com
                cors.mydomain.com;
    ssl_certificate /etc/ssl/certs/mydomain.pem;
    ssl_certificate_key /etc/ssl/private/mydomain.key;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}
```

Set `AUTH_SERVER_PUBLIC_URL`, `NOTESNOOK_APP_PUBLIC_URL`, `MONOGRAPH_PUBLIC_URL`, `ATTACHMENTS_SERVER_PUBLIC_URL` to the HTTPS URLs above.

**Backward-compatible alternative:** If you prefer, you can still point your TLS proxy directly at the individual service ports (5264, 8264, 7264, 6264) — they are still exposed for debugging. MinIO ports (9000, 9090) must go through Caddy.

### Step 5 — run

```bash
docker compose up -d
docker compose logs -f
```

Wait for the validate service to print "All required environment variables are set." Then check health endpoints (see Quick start above).

### Step 6 — create your first account

Go to your Notesnook client (app or web) → Settings → Sync → "Use custom server". Enter the URLs from `AUTH_SERVER_PUBLIC_URL`, `NOTESNOOK_APP_PUBLIC_URL`, etc. The first account you create becomes the admin — with `DISABLE_SIGNUPS=true` you must use that one account for everything unless you set it to false temporarily.

## What's different in this fork vs upstream

1. **Caddy reverse proxy** — internal hostname-based routing. Routes all services through a single port (8080). MinIO S3 API and web console are accessible through Caddy without exposing their ports.
2. **cors-proxy integrated** — built from source, routed through Caddy at `cors.*`.
3. **autoheal** — restarts any container Docker marks unhealthy. Upstream had it, we removed it, we put it back.
4. **CORS env var** `NOTESNOOK_CORS_ORIGINS` actually works (upstream read the wrong env key).
5. `MONGODB_DATABASE_NAME` env var is honored for all 13 collections (was hardcoded to "notesnook" for 7 of them).
6. All app services have `restart: unless-stopped` (upstream had none — a crash left services permanently down).
7. `dpdata` volume persists DataProtection keys so container restarts don't invalidate all auth tokens.
8. MinIO port 9000 not exposed to host (internal only, reached through Caddy).
9. MinIO web console (port 9090) accessible through Caddy at `minio.*`.
10. All streetwriters images pinned to specific version tags (was `:latest` everywhere).
11. Healthchecks use `wget` for .NET images (notesnook, sse, identity) and `bun` for monograph (these images don't have curl/wget). `[::1]` fixed to `127.0.0.1` for monograph (IPv6-only healthcheck silently failed).
12. `setup-s3` bucket creation is idempotent (`|| true`).
13. Resource limits (CPU/memory) on all services.
14. Monograph `HOST: "0.0.0.0"` — Bun resolves `localhost` to IPv6 `::1`, which Docker port mapping can't reach; fixed to bind all interfaces.
15. Network isolation — `notesnook-s3` is on the `notesnook` network (was on default, unreachable from setup-s3).

## Switching to Garage S3

See the `garage-migration` branch for Garage S3 as the object storage backend.
Garage replaces MinIO with a lighter, distroless S3 engine, inlined into the
base compose with automated first-run setup via admin API. The `garage-migration`
branch has full documentation and a verified test suite (59/59 tests passing).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `validate` service exits 1 | Missing required env var | Check `.env.local`, `docker compose logs validate` |
| Signup fails with "scope validation error" | MinIO admin not changed from default | Set `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` to strong values |
| Sync works but web client blank | `MONOGRAPH_PUBLIC_URL` wrong or CORS blocking | Set `MONOGRAPH_PUBLIC_URL` to match your browser URL exactly |
| Attachments 404 | `ATTACHMENTS_SERVER_PUBLIC_URL` wrong | Must point at the same host the presigned URL uses |
| Tokens invalidated after restart | DataProtection keys not persisted | `dpdata` volume missing or wrong mount path |
| Container stays "unhealthy" | Healthcheck misconfigured | Check `docker compose logs <service>` — likely `curl` vs `wget` mismatch |
| Container "unhealthy" but never restarts | autoheal not running | Check `docker compose ps autoheal` — should show "(healthy)" |
| Caddy returns "Healthy" but routes fail | Caddyfile issue | Check `Caddyfile` syntax and `SERVER_DOMAIN` env var |
| Notes disappearing | Sync conflict, not server bug | Export your notes regularly (see backup below) |

## Backup (you need this or you will lose data)

```bash
# MongoDB backup
docker compose exec notesnook-db mongodump --uri="mongodb://localhost:27017/notesnook" --archive=/backup/notesnook-$(date +%Y%m%d).archive

# MinIO attachments backup
docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3
```

Restore from backup needs the reverse process. There is no automatic backup — you run it or you lose notes.

## Update policy

This stack pins images to specific version tags (streetwriters images at a specific
v1.0-beta.x release, monograph at 1.3.1, MinIO at immutable RELEASE timestamps,
MongoDB at 8.0.28). To update deliberately:

1. `git pull origin master` in this repo
2. Check which tags changed (see pin rationale below)
3. `docker compose pull` to fetch new layers
4. `docker compose up -d`

### MongoDB 7.0 → 8.0 migration

MongoDB 8.0 requires a Feature Compatibility Version (FCV) migration:
1. Before upgrading, set FCV to 7.0: `db.adminCommand({ setFeatureCompatibilityVersion: "7.0" })`
2. Stop the stack: `docker compose down`
3. Update the image tag in compose to `mongo:8.0.28`
4. Start the stack: `docker compose up -d`
5. Set FCV to 8.0: `db.adminCommand({ setFeatureCompatibilityVersion: "8.0" })`

See `MONGO_UPGRADE.md` for the full procedure.

### MinIO update

MinIO release tags are immutable timestamps. Updating to `RELEASE.2025-09-07T16-13-09Z` replaces the binary at the same pinned digest. No breaking changes expected.

Pinning means updates are deliberate, not accidental. Each image has a documented
reason for its pin — see "Image pin rationale" below.

## Image pin rationale

| Image | Current Tag | Pin Reason |
|---|---|---|
| `mongo` | `8.0.28` | **Upgraded from 7.0.12.** MongoDB 7.0→8.0 FCV migration required (see `MONGO_UPGRADE.md`). Silver 4114 has AVX2, satisfies Mongo 8.0 requirement. MongoDB 8.0 is backward-compatible with the 3.6+ wire protocol used by the .NET driver. |
| `minio/minio` | `RELEASE.2025-09-07T16-13-09Z` | **Default S3 backend.** Immutable timestamp tag — same binary, same SHA256 digest forever. |
| `minio/mc` | `RELEASE.2025-08-13T08-35-41Z` | **Default bucket setup tool.** Only used by `setup-s3` one-shot service. |
| `streetwriters/identity` | `v1.0-beta.32` | **Our pin, replacing `:latest`.** Versioned tag is immutable — `:latest` would drift. Docker Hub API confirmed `v1.0-beta.32` digest == `:latest` digest at pin time. |
| `streetwriters/notesnook-sync` | `v1.0-beta.32` | Same rationale as identity. |
| `streetwriters/sse` | `v1.0-beta.32` | Same rationale as identity. |
| `streetwriters/monograph` | `1.3.1` | **Our pin, replacing `:latest`.** Monograph uses explicit version tags; `1.3.1` is stable and will not mutate. Docker Hub API confirmed same digest as `:latest` at pin time. |
| `caddy` | `alpine` | Official Caddy image. Alpine-based, ~35 MB. Internal routing only (TLS at external proxy). |
| `cors-proxy` | *(build from source)* | Built from `./cors-proxy/Dockerfile`. SSRF-protected, size-limited CORS proxy for the web app. |
| `willfarrell/autoheal` | `latest` | Watches Docker events, restarts unhealthy containers. Needed because `restart: unless-stopped` only handles crashes, not health failures. |
| `vandot/alpine-bash` | *(none — `:latest` implied)* | **Intentional, low risk.** One-shot utility image (`restart: "no"`) used only by the `validate` service to check env vars before the stack starts. Runs once and exits; no persistent state. `:latest` drift here has zero operational impact. |

## Known issues (upstream, not fixed in this fork)

- #105 signup scope validation error: fixed in this fork by adding missing `profile` scope to `Config.cs`. If you still hit signup failures, grab a log and confirm the `profile` scope is reaching the identity server.
- Client/server version skew (client #8698): app 3.3 broke self-hosted sync; fix was to pin the client to 3.2.4. Not fixable in this repo — pin the client version.
- DataProtection keys still in a docker named volume. Back up `dpdata` or you lose tokens on volume loss.

## License

AGPLv3. See upstream LICENSE file.
