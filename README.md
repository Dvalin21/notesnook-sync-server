# Notesnook Sync Server (MinIO)

Full self-hosted backend for [Notesnook](https://notesnook.com/) (AGPLv3).
Based on streetwriters/notesnook-sync-server, with MinIO S3 backend, Caddy
reverse proxy, and reliability hardening.

**This branch uses MinIO** for object storage. For Garage S3, see
the `garage-migration` branch.

## What runs here

| Service | Internal port | Exposed? | Purpose |
|---|---|---|---|
| caddy | 80 | **8080** (host) | Reverse proxy — routes by Host header |
| identity-server | 8264 | 8264 | Authentication & signup |
| notesnook-server | 5264 | 5264 | Sync engine |
| sse-server | 7264 | 7264 | Server-sent events for real-time sync |
| monograph-server | 3000 | **6264** (host) | Web client (published notes) |
| cors-proxy | 3000 | — | CORS proxy for web app |
| notesnook-s3 (MinIO) | 9000 | **9000** (host) | S3-compatible object storage |
| notesnook-s3 console | 9090 | — | MinIO web console (via Caddy at minio.*) |
| notesnook-db | 27017 | — | MongoDB 8.0 replica set |

## Quick start

```bash
# 1. Edit .env — replace every CHANGEME with your values
nano .env

# 2. Generate secrets
openssl rand -base64 48   # NOTESNOOK_API_SECRET
openssl rand -base64 12   # MINIO_ROOT_USER (min 3 chars)
openssl rand -base64 22   # MINIO_ROOT_PASSWORD (min 8 chars)

# 3. Start everything
docker compose up -d

# 4. Watch it boot
docker compose logs -f
# Wait for "All required environment variables are set." from validate

# 5. Check health
curl -fsS http://localhost:5264/health && echo " sync OK"
curl -fsS http://localhost:8264/health && echo " auth OK"
curl -fsS http://localhost:7264/health && echo " sse OK"
curl -fsS http://localhost:6264/api/health && echo " monograph OK"
curl -fsS http://localhost:8080/health && echo " caddy OK"

# 6. Everything healthy?
docker compose ps
```

## Port routing — two ways to connect

Your Notesnook client needs to reach these services. Two options:

### A) Direct ports (simpler — good for localhost testing)

Point the client directly at each service's exposed port.
The `.env` defaults use this mode:

| .env variable | Value | What talks to it |
|---|---|---|
| `NOTESNOOK_APP_PUBLIC_URL` | `http://localhost:5264` | Sync API |
| `AUTH_SERVER_PUBLIC_URL` | `http://localhost:8264` | Auth API |
| `MONOGRAPH_PUBLIC_URL` | `http://localhost:6264` | Web client |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | `http://localhost:9000` | S3 attachments (MinIO) |

MinIO port 9000 is exposed to the host for this reason. Remove the
`ports: - "9000:9000"` block from `notesnook-s3` in docker-compose.yml
if you route attachments through Caddy instead.

### B) Caddy + TLS proxy (recommended for production)

Caddy (port 8080) routes by Host header. Put a TLS-terminating proxy
in front (nginx, Caddy, Traefik, Cloudflare Tunnel, etc.) and forward
subdomains to `http://<host>:8080`.

Caddy routing table:

| Host header | Destination | .env variable |
|---|---|---|
| `sync.your.domain` | notesnook-server:5264 | `NOTESNOOK_APP_PUBLIC_URL` |
| `auth.your.domain` | identity-server:8264 | `AUTH_SERVER_PUBLIC_URL` |
| `sse.your.domain` | sse-server:7264 | — |
| `notes.your.domain` | monograph-server:3000 | `MONOGRAPH_PUBLIC_URL` |
| `attach.your.domain` | notesnook-s3:9000 (S3) | `ATTACHMENTS_SERVER_PUBLIC_URL` |
| `minio.your.domain` | notesnook-s3:9090 (console) | — |
| `cors.your.domain` | cors-proxy:3000 | — |
| *(unmatched)* | monograph-server:3000 (default) | — |

Set the `.env` PUBLIC_URL vars to the HTTPS subdomains, e.g.:
```
NOTESNOOK_APP_PUBLIC_URL=https://sync.example.com
AUTH_SERVER_PUBLIC_URL=https://auth.example.com
MONOGRAPH_PUBLIC_URL=https://notes.example.com
ATTACHMENTS_SERVER_PUBLIC_URL=https://attach.example.com
```

nginx snippet:
```nginx
server {
    listen 443 ssl;
    server_name sync.example.com auth.example.com sse.example.com
                notes.example.com attach.example.com minio.example.com
                cors.example.com;
    ssl_certificate /etc/ssl/certs/example.pem;
    ssl_certificate_key /etc/ssl/private/example.key;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
}
```

## Settings — .env reference

### Required (must set)

| Variable | Description |
|---|---|
| `INSTANCE_NAME` | Human-readable name for this server |
| `NOTESNOOK_API_SECRET` | Auth token secret. Generate: `openssl rand -base64 48` |
| `DISABLE_SIGNUPS` | `true` = no new registrations (recommended) |
| `AUTH_SERVER_PUBLIC_URL` | Base URL for auth server (see routing table above) |
| `NOTESNOOK_APP_PUBLIC_URL` | Base URL for sync server |
| `MONOGRAPH_PUBLIC_URL` | Base URL for web client |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Base URL for S3 attachments |

### Strongly recommended

| Variable | Default | Description |
|---|---|---|
| `SMTP_HOST` | — | SMTP server hostname (needed for email 2FA / password reset) |
| `SMTP_PORT` | 587 | SMTP port |
| `SMTP_USERNAME` | — | SMTP login |
| `SMTP_PASSWORD` | — | SMTP password |
| `MINIO_ROOT_USER` | CHANGEME | MinIO admin username. Generate: `openssl rand -base64 12` |
| `MINIO_ROOT_PASSWORD` | CHANGEME | MinIO admin password. Generate: `openssl rand -base64 22` |

### Optional

| Variable | Default | Description |
|---|---|---|
| `SERVER_DOMAIN` | `localhost` | Domain for Caddy Host-based routing |
| `SMTP_FROM_NAME` | *(none)* | Sender name in outgoing emails |
| `NOTESNOOK_CORS_ORIGINS` | *(all allowed)* | Comma-separated CORS origins |
| `TWILIO_ACCOUNT_SID` | *(none)* | For SMS 2FA |
| `TWILIO_AUTH_TOKEN` | *(none)* | For SMS 2FA |
| `TWILIO_SERVICE_SID` | *(none)* | For SMS 2FA |
| `KNOWN_PROXIES` | *(none)* | Comma-separated reverse proxy IPs |

## Backup

```bash
# MongoDB
docker compose exec notesnook-db mongodump \
  --uri="mongodb://localhost:27017/notesnook" \
  --archive=/backup/notesnook-$(date +%Y%m%d).archive

# MinIO attachments
docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3
```

No automatic backup. You run it or you lose data.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `validate` exits 1 | Missing env var | `docker compose logs validate` shows which |
| Signup "scope validation error" | Missing `profile` scope | Already fixed in this stack — update your images |
| Attachments 404 | `ATTACHMENTS_SERVER_PUBLIC_URL` wrong | Must match the URL the client uses for S3 |
| Tokens invalidated after restart | DataProtection keys lost | `dpdata` volume should persist (check `docker volume ls`) |
| Caddy routes fail | `SERVER_DOMAIN` wrong | Check Caddyfile and `docker compose logs caddy` |

## Security notes

- `.env` contains secrets (API secret, MinIO credentials, SMTP password).
  Keep it out of version control. This repo's `.gitignore` excludes `.env`.
- Images are pinned to version tags (no `:latest` drift).
- For the Garage S3 variant, see the `garage-migration` branch.

## License

AGPLv3. See LICENSE.
