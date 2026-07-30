# Notesnook Sync Server

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
  attach.example.com   →  notesnook-s3:9000
  minio.example.com    →  notesnook-s3:9090
  cors.example.com     →  cors-proxy:3000
```

Clients never touch internal ports. Everything behind 8080 is plain HTTP.
Your external proxy terminates TLS.

---

## Prerequisites

| What | Why |
|---|---|
| **Docker + Docker Compose V2** | The whole stack runs in containers. `docker compose` (with a space, not `docker-compose`). |
| **A domain you control** | All routing is by `Host:` header. You need `example.com` (replace with your real domain). |
| **DNS** | Each subdomain below must resolve to your server's public IP. **Use a wildcard `*.example.com` A/AAAA record** — one record covers all 8. |
| **A TLS-terminating reverse proxy** | Caddy, nginx, Apache, Traefik, HAProxy, or any cloud LB. This stack exposes port 8080 with plain HTTP; your proxy adds TLS. |
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
| `example.com` | Web client (apex/root) |
| `attach.example.com` | S3-compatible attachment storage (MinIO) |
| `minio.example.com` | MinIO admin web console |
| `cors.example.com` | CORS proxy for external image embeds |

No wildcard support? Create 8 individual A records — all pointing to the same IP.

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

| Variable | What to put |
|---|---|
| `SERVER_DOMAIN` | **Your domain** (e.g., `example.com`). Used by Caddy to match Host headers. |
| `INSTANCE_NAME` | Anything you like (e.g., `my-notes`). Shows in the Monograph web client. |
| `NOTESNOOK_API_SECRET` | **Generate**: `openssl rand -base64 48`. Internal signing secret for auth tokens. |
| `DISABLE_SIGNUPS` | `true` = no new registrations. Set to `false` to create your first account, then set back to `true`. |
| `NOTESNOOK_APP_PUBLIC_URL` | `https://sync.example.com` — used by Android app as Sync URL |
| `AUTH_SERVER_PUBLIC_URL` | `https://auth.example.com` — used by Android app as Auth URL |
| `MONOGRAPH_PUBLIC_URL` | `https://notes.example.com` — web client URL |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | `https://attach.example.com` — used by Android app as Attachments URL |
| `MINIO_ROOT_USER` | **Generate**: `openssl rand -base64 12`. MinIO admin login + S3 access key. |
| `MINIO_ROOT_PASSWORD` | **Generate**: `openssl rand -base64 22`. MinIO admin password + S3 secret key. |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | Optional — for email 2FA and password reset. Leave as-is if not needed. |
| `NOTESNOOK_CORS_ORIGINS` | Optional — extra CORS origins. Leave blank if behind your own TLS proxy. |

**MinIO credentials warning:** If `MINIO_ROOT_USER` or `MINIO_ROOT_PASSWORD` is empty,
the `setup-s3` container will refuse to start. Generate strong values.

### 3. Configure your TLS reverse proxy

This stack does **not** handle TLS itself. You need an external proxy that:

1. Terminates TLS for `*.example.com`
2. Forwards all requests to `http://<your-server-ip>:8080`
3. Preserves the original `Host:` header (this is how Caddy routes internally)

**Caddy example** (use Caddyfile or any proxy):

```caddy
*.example.com {
    reverse_proxy localhost:8080
}
```

**nginx example:**

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
5. **`setup-s3`** creates the `attachments` bucket, then exits
6. **`identity-server`** starts on port 8264
7. **`notesnook-server`** starts on port 5264
8. **`sse-server`** starts on port 7264
9. **`monograph-server`** starts on port 3000
10. **`cors-proxy`** starts on port 3000
11. **`caddy`** starts routing on port 80 (mapped to host port 8080)

**First boot takes 2-5 minutes.** MongoDB replica set initialization and
.NET DataProtection key generation happen on first startup.

### 5. Verify

Once all services show `(healthy)`, run the functional test:

```bash
bash test_functional.sh example.com
```

Expected output: **ALL CHECKS PASSED**.

You can also test each subdomain manually through Caddy:

```bash
curl -fsS -H "Host: sync.example.com"   http://localhost:8080/health
curl -fsS -H "Host: auth.example.com"   http://localhost:8080/health
curl -fsS -H "Host: sse.example.com"    http://localhost:8080/health
curl -fsS -H "Host: notes.example.com"  http://localhost:8080/api/health
curl -fsS -H "Host: example.com"        http://localhost:8080/api/health
curl -fsS -H "Host: attach.example.com" http://localhost:8080/health
curl -fsS -H "Host: minio.example.com"  http://localhost:8080/
curl -fsS -H "Host: cors.example.com"   http://localhost:8080/health
```

Each should return `200` (or a valid page/JSON response).

If your TLS proxy points at `localhost:8080`, these same commands work from
the host. If from another machine, replace `localhost` with your server's IP.

### 6. Create your first account

1. Edit `.env` and set `DISABLE_SIGNUPS=false`
2. Restart: `docker compose up -d identity-server notesnook-server`
3. Open **https://notes.example.com** (your Monograph URL) in a browser
4. Click **Sign up** and create your account
5. **IMPORTANT**: Set `DISABLE_SIGNUPS=true` again and restart

### 7. Connect clients

**Android:**

Settings → Sync → Use custom server:

| Field | Value |
|---|---|
| Auth URL | `https://auth.example.com` |
| Sync URL | `https://sync.example.com` |
| Attachments URL | `https://attach.example.com` |

**Web browser:**

Navigate to `https://notes.example.com` or `https://example.com`.

---

## MinIO admin login

- Console URL:  **https://minio.example.com**
- S3 API URL:   **https://attach.example.com**
- Username: value of `MINIO_ROOT_USER` in `.env`
- Password: value of `MINIO_ROOT_PASSWORD` in `.env`

`setup-s3` creates the `attachments` bucket automatically on first boot.

---

## Maintenance

### Backups

```bash
# MongoDB
docker compose exec notesnook-db mongodump \
  --uri="mongodb://notesnook-db:27017/notesnook" \
  --archive=/backup/notesnook-$(date +%Y%m%d).archive

# MinIO attachments
docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3
```

### Updates

```bash
git pull origin master
docker compose pull
docker compose up -d
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
| Can't connect from Android | Wrong URLs in app settings | Verify `NOTESNOOK_APP_PUBLIC_URL`, `AUTH_SERVER_PUBLIC_URL`, `ATTACHMENTS_SERVER_PUBLIC_URL` in `.env` exactly match what you put in the app. |
| Web client shows blank page | Monograph needs API_HOST | Check `docker compose logs monograph-server`. It should connect to `notesnook-server:5264`. |
| Port conflict on 8080 | Another service uses that port | Change the host port in `docker-compose.yml` (e.g., `8080:80` → `8081:80`) and update your TLS proxy. |

---

## Architecture

### Single port model

By design, this stack publishes **one port** externally: host `:8080`.

```
Host :8080  →  Caddy :80  →  routes by Host header to correct backend
```

Internal ports `5264` / `8264` / `7264` / `3000` / `9000` / `9090` are **NOT**
exposed to the host or to clients. They're only reachable inside the Docker
network. This is a security hardening over the upstream stack.

### .env / subdomain mapping table

| Variable | Client field | Caddy `Host:` | Internal target |
|---|---|---|---|
| `NOTESNOOK_APP_PUBLIC_URL` | Sync URL | `sync.example.com` | `notesnook-server:5264` |
| `AUTH_SERVER_PUBLIC_URL` | Auth URL | `auth.example.com` | `identity-server:8264` |
| `MONOGRAPH_PUBLIC_URL` | Web URL | `notes.example.com` / `example.com` | `monograph-server:3000` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Attachments URL | `attach.example.com` | `notesnook-s3:9000` |

Never mix these up. The Android client uses the first three exactly as shown
above. The web client uses `MONOGRAPH_PUBLIC_URL`.

### Caddy internal routing

| Host header | Routes to |
|---|---|
| `sync.example.com` | `notesnook-server:5264` |
| `auth.example.com` | `identity-server:8264` |
| `sse.example.com` | `sse-server:7264` |
| `notes.example.com` / `example.com` | `monograph-server:3000` |
| `attach.example.com` | `notesnook-s3:9000` (S3 API) |
| `minio.example.com` | `notesnook-s3:9090` (MinIO console) |
| `cors.example.com` | `cors-proxy:3000` |
| `/attachments/*` / `/minio/*` (path) | `notesnook-s3:9000` (fallback) |

---

## Secrets hygiene

- `.env` is gitignored. If `.env` is present in the working tree, it may
  contain live credentials and should not be committed.
- `.env.example` IS committed and contains placeholders only — `example.com`
  and `CHANGEME-*` values.
- Sanitize before committing any docs or scripts: strip real domains and
  credentials.

---

## What this fork changed from upstream

1. `MONGODB_DATABASE_NAME` is honored by all repositories (upstream hardcoded "notesnook" for 7 collections).
2. `NOTESNOOK_CORS_ORIGINS` env var is wired correctly (upstream read wrong key `NOTESNOOK_CORS`).
3. Missing OAuth `profile` scope added in identity config (required by Notesnook 3.x OIDC flow).
4. Per-service ASP.NET DataProtection key volumes instead of one shared `dpdata`.
5. `init-dpdata` one-shot container fixes volume permissions automatically on first boot.
6. MongoDB is NOT exposed on a host port.
7. Healthchecks use `nc` / `node` / `bun` instead of `wget`.
8. Image tags are pinned to immutable versions instead of `:latest`.
9. `setup-s3` fails fast if `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are missing.
10. Caddy internal reverse proxy routes all traffic through a single port (8080).
