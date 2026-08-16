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
  attach.example.com   →  notesnook-s3:9000
  minio.example.com    →  notesnook-s3:9090  (MinIO console — optional)
  cors.example.com     →  cors-proxy:3000
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
7. Healthchecks use `nc` for .NET services, `node` for cors-proxy, and `bun` for monograph — instead of `wget`.
8. Core service images pinned to immutable versions (`mongo:8.0.28`, MinIO release tags, `streetwriters/*:v1.0-beta.32`, `monograph:1.3.1`); infrastructure images use stable tags (`caddy:alpine`, `alpine:latest`, `willfarrell/autoheal:latest`, `vandot/alpine-bash`).
9. `setup-s3` fails fast if `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are missing.
10. Caddy internal reverse proxy routes all traffic through a single port (8080).
11. MinIO image pinned to `RELEASE.2025-09-07T16-13-09Z`, mc pinned to `RELEASE.2025-08-13T08-35-41Z`.
12. MongoDB is `8.0.28` (upgraded from `7.0.12`).

---

## Prerequisites

| What | Why |
|---|---|
| **Docker + Docker Compose V2** | The whole stack runs in containers. `docker compose` (with a space, not `docker-compose`). |
| **A domain you control** | All routing is by `Host:` header. You need `example.com` (replace with your real domain). |
| **DNS** | Each subdomain below must resolve to your server's public IP. **Use a wildcard `*.example.com` A/AAAA record** — one record covers all 8. |
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
| `example.com` | Web client (apex/root) |
| `attach.example.com` | S3-compatible attachment storage (MinIO) |
|| `cors.example.com` | CORS proxy for external image embeds |
|| `inbox.example.com` | Inbox API (optional) |
|| `themes.example.com` | Themes server (optional) |

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

| Variable | Client field | Caddy `Host:` | Internal target |
|---|---|---|---|
| `NOTESNOOK_APP_PUBLIC_URL` | Sync URL | `sync.example.com` | `notesnook-server:5264` |
| `AUTH_SERVER_PUBLIC_URL` | Auth URL | `auth.example.com` | `identity-server:8264` |
| `MONOGRAPH_PUBLIC_URL` | Web URL | `notes.example.com` / `example.com` | `monograph-server:3000` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Attachments URL | `attach.example.com` | `notesnook-s3:9000` |

Never mix these up. The Android client uses the first three exactly as shown
above. The web client uses `MONOGRAPH_PUBLIC_URL`.

### MinIO / S3

MinIO provides S3-compatible object storage for note attachments. It runs
internally on port 9000. Caddy routes `attach.example.com` to it.

The MinIO admin console runs on port 9090 internally. Caddy can route
`minio.example.com` to it for admin access — this is optional.

`setup-s3` creates the `attachments` bucket automatically on first boot.

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
| `MINIO_ROOT_USER` | No — but `setup-s3` will fail if empty | Generate with `openssl rand -base64 12`. Not checked by `validate`; `setup-s3` refuses to start if blank. |
| `MINIO_ROOT_PASSWORD` | No — but `setup-s3` will fail if empty | Generate with `openssl rand -base64 22`. Not checked by `validate`; `setup-s3` refuses to start if blank. |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` | No — optional, warn if missing | Leave blank if not using email features |
| `NOTESNOOK_CORS_ORIGINS` | No — used by `cors-proxy` only | Comma-separated origins, default `*`. Not checked by `validate`; the `cors-proxy` container receives it via env_file. |
| `TWILIO_*` | No — optional, passed to all services | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_SERVICE_SID` for SMS 2FA via `SMSSender`. Leave empty to disable SMS 2FA. |

**MinIO credentials warning:** If `MINIO_ROOT_USER` or `MINIO_ROOT_PASSWORD` is empty,
the `setup-s3` container will refuse to start. Generate strong values.

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
5. **`setup-s3`** creates the `attachments` bucket, then exits
6. **`identity-server`** starts on port 8264
7. **`notesnook-server`** starts on port 5264
8. **`sse-server`** starts on port 7264
9. **`monograph-server`** starts on port 3000
10. **`cors-proxy`** starts on port 3000
11. **`setup-themes`** initializes themes data volume, then exits
12. **`inbox-api`** starts on port 5181
13. **`themes-server`** starts on port 9000
14. **`caddy`** starts routing on port 80 (mapped to host port 8080)

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
curl -fsS -H "Host: inbox.example.com"  http://localhost:8080/health
curl -fsS -H "Host: themes.example.com" http://localhost:8080/health
```

Each should return `200` (or a valid page/JSON response).
`attach.*` returns `403` without credentials — that's expected (S3 requires auth).
`minio.*` returns the MinIO console HTML.
`inbox.*` and `themes.*` return `200` from their health endpoints.

You can also run the smoke test script which checks health endpoints directly (bypasses Caddy):

```bash
bash test_functional.sh --install
```

Expected output: all services show `✓`.

If your TLS proxy points at `localhost:8080`, these same commands work from
the host. If from another machine, replace `localhost` with your server's IP.

### 6. Create your first account

Signup must be done through the **Notesnook mobile or desktop app** —
the Monograph web client (`notes.example.com`) has no registration page.

The registration endpoint is `POST /users` on the sync server
(`sync.example.com/users`), NOT the identity server. Internally the sync
server calls the identity server via WAMP RPC (not HTTP). Your account is
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

| Field in app | Value |
|---|---|
| Auth URL / Identity server | `https://auth.example.com` |
| Sync URL / Sync server | `https://sync.example.com` |
| Attachments URL / S3 URL | `https://attach.example.com` |
| Monograph URL (web only) | `https://notes.example.com` |

After entering these, tap **Test connection** (if available), then **Save**.
Then use **Sign up** or **Log in** to create your account.

**Desktop app — Server URLs:**

Settings → Servers → Add custom server. Same URLs as above.

**Web browser:**

Navigate to `https://notes.example.com` or `https://example.com` for the
Monograph web client (read-only note sharing — no account management).

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

## MinIO admin login

- Console URL:  **https://minio.example.com** (optional — routed via Caddy)
- S3 API URL:   **https://attach.example.com** (used by the Notesnook app)
- Username: value of `MINIO_ROOT_USER` in `.env`
- Password: value of `MINIO_ROOT_PASSWORD` in `.env`

---

## Maintenance

### Backups

```bash
# MongoDB
docker compose exec notesnook-db mongodump \
  --uri="mongodb://notesnook-db:27017/notesnook" \
  --archive=/backup/notesnook-$(date +%Y%m%d).archive

# MinIO attachments (from host)
docker run --rm -v notesnook-sync-server_s3data:/data -v /backup/s3:/backup \
  alpine tar czf /backup/s3/minio-$(date +%Y%m%d).tar.gz -C /data .
```

### Updates

```bash
git pull
docker compose pull
docker compose up -d
```

### Disaster recovery: DataProtection keys

The `dpdata-*` volumes store ASP.NET DataProtection keys. These keys
validate authentication cookies and tokens. If you lose these volumes,
all users will be logged out and must sign in again.

Back them up alongside your MongoDB backup:

```bash
# Backup all dpdata volumes
for vol in dpdata-identity dpdata-notesnook dpdata-sse dpdata-monograph; do
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
| Can't connect from Android | Wrong URLs in app settings | Verify `NOTESNOOK_APP_PUBLIC_URL`, `AUTH_SERVER_PUBLIC_URL`, `ATTACHMENTS_SERVER_PUBLIC_URL` in `.env` exactly match what you put in the app. |
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
