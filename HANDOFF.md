# Notesnook Sync Server — Handoff

Current branch: `master`
Docker compose project: `notesnook-sync-server`
Host port to Caddy: `<HOST_IP>:8080` → Caddy `:80`

## How to restart

```bash
cd /home/keith/host/notesnook-sync-server

# Graceful restart (preserves volumes)
docker compose -f docker-compose.yml --env-file .env down
docker compose -f docker-compose.yml --env-file .env up -d

# Watch boot
docker compose logs -f
```

`validate` and `setup-s3` are one-shot containers. `setup-s3` creates the MinIO
`attachments` bucket on first run and then exits. `validate` checks required env
vars and exits 1 if anything is missing.

## Health checks

```bash
# Internal direct
curl -fsS http://localhost:5264/health   # notesnook-server
curl -fsS http://localhost:8264/health   # identity-server
curl -fsS http://localhost:7264/health   # sse-server
curl -fsS http://localhost:6264/api/health # monograph-server

# Through Caddy Host headers
curl -fsS -H "Host: sync.<SERVER_DOMAIN>"    http://<HOST_IP>:8080/health
curl -fsS -H "Host: auth.<SERVER_DOMAIN>"    http://<HOST_IP>:8080/health
curl -fsS -H "Host: sse.<SERVER_DOMAIN>"     http://<HOST_IP>:8080/health
curl -fsS -H "Host: notes.<SERVER_DOMAIN>"   http://<HOST_IP>:8080/health
```

## Functional test

```bash
bash /home/keith/host/notesnook-sync-server/test_functional.sh
```

Expected: all checks pass.

## What every `.env` variable does

No secrets are stored in this file. Replace placeholders before first boot.

| Variable | Purpose |
|---|---|
| `SERVER_DOMAIN` | Base domain for Caddy Host-header routing |
| `INSTANCE_NAME` | Display name for this instance |
| `NOTESNOOK_API_SECRET` | Internal API signing secret |
| `DISABLE_SIGNUPS` | `true` = closed registration |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `SMTP_FROM_NAME` | Outgoing mail |
| `AUTH_SERVER_PUBLIC_URL` | Android client auth base URL |
| `NOTESNOOK_APP_PUBLIC_URL` | Android client sync API base URL |
| `MONOGRAPH_PUBLIC_URL` | Web client base URL |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Attachment upload/download base URL |
| `MINIO_ROOT_USER` | MinIO admin user + internal S3 credential |
| `MINIO_ROOT_PASSWORD` | MinIO admin password + internal S3 secret |
| `SELF_HOSTED` | `1` = enable self-hosted behavior |
| `MONGODB_DATABASE_NAME` | MongoDB database name |
| `MONGODB_CONNECTION_STRING` | Internal MongoDB URI, leave default |
| `NOTESNOOK_CORS_ORIGINS` | Extra CORS origins, empty is fine behind TLS proxy |
| `SIGNALR_REDIS_CONNECTION_STRING` | Backplane for multi-instance SignalR, leave empty for single box |

Generated secrets:
```bash
openssl rand -base64 48   # NOTESNOOK_API_SECRET
openssl rand -base64 12   # MINIO_ROOT_USER (min 3 chars)
openssl rand -base64 22   # MINIO_ROOT_PASSWORD (min 8 chars)
```

## Client connection URLs

Android app → Settings → Sync → "Use custom server":

| Field | Value |
|---|---|
| Auth URL | `https://auth.<SERVER_DOMAIN>` |
| Sync URL | `https://sync.<SERVER_DOMAIN>` |
| Attachments URL | `https://attach.<SERVER_DOMAIN>` |

Real-time sync uses SignalR at `/hubs/sync/v2`. There is no legacy HTTP `/sync`
endpoint.

Web client (Monograph): `https://notes.<SERVER_DOMAIN>` or `https://<SERVER_DOMAIN>`

## MinIO admin login

Console: `https://minio.<SERVER_DOMAIN>` (MinIO web UI on port 9090)
S3 API: `https://attach.<SERVER_DOMAIN>` (MinIO S3 on port 9000)

Login with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` from `.env`.

## Caddy internal routing

| Host header | Backend |
|---|---|
| `sync.<SERVER_DOMAIN>` | notesnook-server:5264 |
| `auth.<SERVER_DOMAIN>` | identity-server:8264 |
| `sse.<SERVER_DOMAIN>` | sse-server:7264 |
| `notes.<SERVER_DOMAIN>` / `<SERVER_DOMAIN>` | monograph-server:3000 |
| `attach.<SERVER_DOMAIN>` | notesnook-s3:9000 S3 API |
| `minio.<SERVER_DOMAIN>` | notesnook-s3:9090 MinIO console |
| `cors.<SERVER_DOMAIN>` | cors-proxy:3000 |
| `/attachments/*`, `/minio/*` path fallback | notesnook-s3:9000 |
| anything else | monograph-server:3000 |

## After restart verification checklist

1. `docker compose ps` — all app containers `Up` / healthy
2. `docker compose logs notesnook-server identity-server sse-server` — no
   DataProtection `UnauthorizedAccessException` on `.tmp` key writes
3. `curl -fsS http://localhost:5264/health` → 200
4. `curl -fsS http://localhost:8264/health` → 200
5. `curl -fsS http://localhost:7264/health` → 200
6. `curl -fsS http://localhost:6264/api/health` → 200
7. `curl -fsS http://localhost:8080/attachments/` → 403 or 200 (bucket exists)
8. curl token endpoint with bad password → `invalid_grant` (auth stack alive)
9. `bash test_functional.sh` → ALL CHECKS PASSED
10. MinIO console reachable at `https://minio.<SERVER_DOMAIN>` with
    `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`
11. MongoDB not exposed on host: `docker compose ps notesnook-db` shows no
    `0.0.0.0:27017` mapping

## Known issues / gotchas

- DataProtection key ownership: volumes must be UID 1000 (`dotnetuser`).
  Fix: `docker run --rm -v <volume>:/mnt alpine chown -R 1000:1000 /mnt`
- Restart policies: app services have none; autoheal is the only restart authority.
- MongoDB host port: not mapped in current compose; do not add `ports:` back.
- Healthcheck tools: .NET services use `nc`; cors-proxy uses `node`; monograph uses `bun`.
- `/inbox/public-encryption-key` requires `Authorization: ApiKey <key>` header.
  Unauthenticated requests return 401 — this is correct.
- `/sync` does not exist as HTTP endpoint; sync is SignalR `/hubs/sync/v2`.

## Backup

```bash
# MongoDB
docker compose exec notesnook-db mongodump \
  --uri="mongodb://notesnook-db:27017/${MONGODB_DATABASE_NAME:-notesnook}" \
  --archive=/backup/notesnook-$(date +%Y%m%d).archive

# MinIO attachments
docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3
```

Restore is the reverse. There is no automatic backup.

## Git workflow

All fixes go to `master` directly. No PRs, no merge steps.

```bash
git add <files>
git commit -m "describe fix"
git push origin master
```
