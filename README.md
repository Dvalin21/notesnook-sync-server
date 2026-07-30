# Notesnook Sync Server (fork of streetwriters/notesnook-sync-server)

Full source for the Notesnook sync backend (Notesnook / Streetwriters). AGPLv3 licensed.

This fork contains operational hardening fixes (CORS env-var, MONGODB_DATABASE_NAME,
restart policies, DataProtection key persistence via per-service volumes, image pinning).
The original upstream README and INSTALL are superseded by this file.

## What this stack runs (all in Docker)

| Service | Compose name | Internal port | Published via Caddy Host header |
|---|---|---|---|
| identity-server | `identity-server` | 8264 | `https://auth.<SERVER_DOMAIN>` |
| notesnook-server | `notesnook-server` | 5264 | `https://sync.<SERVER_DOMAIN>` |
| sse-server | `sse-server` | 7264 | `https://sse.<SERVER_DOMAIN>` |
| monograph-server | `monograph-server` | 6264 | `https://notes.<SERVER_DOMAIN>` / `https://<SERVER_DOMAIN>` |
| notesnook-db | `notesnook-db` | 27017 internal only | not exposed |
| notesnook-s3 | `notesnook-s3` | 9000 + 9090 internal | `https://attach.<SERVER_DOMAIN>` (S3) / `https://minio.<SERVER_DOMAIN>` (console) |
| cors-proxy | `cors-proxy` | 3000 internal | `https://cors.<SERVER_DOMAIN>` |
| caddy | `caddy` | 8080 internal / your TLS front | Host-header router |
| autoheal | `autoheal` | — | Container monitor |

Caddy listens on `:80` inside the stack. The host maps one port to Caddy:
- `<HOST_IP>:8080` → Caddy `:80` → routes by Host header to all backends.

TLS termination is in front of Caddy on 8080. The stack itself is plain HTTP.

## Prerequisites

- Docker and Docker Compose v2 on a Linux host.
- A domain or LAN IP you control. Notesnook clients need fixed URLs.
- A TLS proxy in front. The stack exposes only internal plus one mapping:
  - `localhost:5264` — sync API
  - `localhost:8264` — auth/identity
  - `localhost:7264` — SSE
  - `localhost:6264` — monograph web client
- `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` — used for both MinIO admin login
  and as the S3 service credentials the sync server uses internally.

## Quick start

```bash
cd ~/host/notesnook-sync-server

cp .env .env.local
nano .env.local   # edit ALL values — see settings below

docker compose up -d
docker compose logs -f   # wait for validate: "All required environment variables are set."

curl -fsS http://localhost:5264/health && echo " sync OK"
curl -fsS http://localhost:8264/health && echo " auth OK"
curl -fsS http://localhost:7264/health && echo " sse OK"
curl -fsS http://localhost:6264/api/health && echo " monograph OK"
```

If anything fails, `docker compose logs <service>` shows why.

## .env variables — what goes where

Copy `.env` to `.env.local`. Never commit `.env.local`. Placeholders marked
`CHANGE_ME` must be replaced.

### Required

| Variable | Where it goes / what it drives | Example |
|---|---|---|
| `INSTANCE_NAME` | Display name for this server instance | `my-notesnook` |
| `SERVER_DOMAIN` | Base domain used by Caddyfile routing | `example.com` |
| `NOTESNOOK_API_SECRET` | Internal API signing secret | openssl rand -base64 48 |
| `DISABLE_SIGNUPS` | `true` = closed registration; `false` = open | `true` |
| `SMTP_HOST` | Outgoing mail host | `smtp.example.com` |
| `SMTP_PORT` | Outgoing mail port | `587` |
| `SMTP_USERNAME` | SMTP login | `alerts@example.com` |
| `SMTP_PASSWORD` | SMTP password | strong-random-secret |
| `SMTP_FROM_NAME` | Sender name in messages | `Notesnook` |
| `AUTH_SERVER_PUBLIC_URL` | Android client auth URL → `https://auth.<SERVER_DOMAIN>` | `https://auth.example.com` |
| `NOTESNOOK_APP_PUBLIC_URL` | Android client sync URL → `https://sync.<SERVER_DOMAIN>` | `https://sync.example.com` |
| `MONOGRAPH_PUBLIC_URL` | Web client URL → `https://notes.<SERVER_DOMAIN>` | `https://notes.example.com` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Attachment URL → `https://attach.<SERVER_DOMAIN>` | `https://attach.example.com` |
| `MINIO_ROOT_USER` | MinIO admin login _and_ internal S3 credential username | strong-random-user |
| `MINIO_ROOT_PASSWORD` | MinIO admin password _and_ internal S3 credential secret | openssl rand -base64 22 |
| `SELF_HOSTED` | Set to `1` to enable self-hosted behavior | `1` |

### Optional

| Variable | Default | What |
|---|---|---|
| `MONGODB_DATABASE_NAME` | `notesnook` | MongoDB database name. Honored by all repositories in this fork. |
| `MONGODB_CONNECTION_STRING` | `mongodb://notesnook-db:27017` | Internal MongoDB URI. Leave it. |
| `NOTESNOOK_CORS_ORIGINS` | empty | Extra CORS origins. Empty + your TLS proxy is fine. |
| `SIGNALR_REDIS_CONNECTION_STRING` | empty | Backplane for multi-instance SignalR. Leave empty for single box. |

## Connecting clients

### Android client

In the Notesnook Android app → Settings → Sync → "Use custom server":

| Field | Value |
|---|---|
| Auth URL | `https://auth.<SERVER_DOMAIN>` |
| Sync URL | `https://sync.<SERVER_DOMAIN>` |
| Attachments URL | `https://attach.<SERVER_DOMAIN>` |

These match the `AUTH_SERVER_PUBLIC_URL`, `NOTESNOOK_APP_PUBLIC_URL`, and
`ATTACHMENTS_SERVER_PUBLIC_URL` values in `.env`.

The app uses OAuth2 password grant against the identity server, then authenticates
all API and SignalR sync requests with the returned bearer token.

SignalR sync hub path: `/hubs/sync/v2`.

There is no legacy HTTP `/sync` endpoint.

### Web client (Monograph)

Open `https://notes.<SERVER_DOMAIN>` or `https://<SERVER_DOMAIN>` in a browser.
Served by `monograph-server` and routed via `MONOGRAPH_PUBLIC_URL` in `.env`.

## MinIO admin login

MinIO is the object store for attachments. Credentials are separate from Notesnook
user accounts.

- Console URL: `https://minio.<SERVER_DOMAIN>` → Caddy routes this to
  `notesnook-s3:9090` inside the stack.
- S3 API URL: `https://attach.<SERVER_DOMAIN>` → Caddy routes this to
  `notesnook-s3:9000` inside the stack.

Username: the value of `MINIO_ROOT_USER` in `.env`.
Password: the value of `MINIO_ROOT_PASSWORD` in `.env`.

`setup-s3` creates the `attachments` bucket automatically on first boot.

## Caddy internal routing

Caddy listens on `:80` inside the stack. The host publishes one mapping:
- `10.0.0.241:8080` → Caddy `:80`

Routes are by Host header, with `{$DOMAIN}` replaced by `SERVER_DOMAIN` from `.env`:

| Host header | Backend |
|---|---|
| Host header | Backend |
|---|---|
| `sync.<SERVER_DOMAIN>` | notesnook-server:5264 |
| `auth.<SERVER_DOMAIN>` | identity-server:8264 |
| `sse.<SERVER_DOMAIN>` | sse-server:7264 |
| `notes.<SERVER_DOMAIN>` / `<SERVER_DOMAIN>` | monograph-server:3000 |
| `attach.<SERVER_DOMAIN>` | notesnook-s3:9000 S3 API |
| `minio.<SERVER_DOMAIN>` | notesnook-s3:9090 MinIO web console |
| `cors.<SERVER_DOMAIN>` | cors-proxy:3000 |
| `/attachments/*`, `/minio/*` path fallback | notesnook-s3:9000 |
| anything else | monograph-server:3000 |

If you add new subdomains, add matching `host` matchers in `Caddyfile`.

## DataProtection key persistence

Each .NET service uses its own Docker named volume for ASP.NET DataProtection keys.

| Service | Volume |
|---|---|
| identity-server | `dpdata-identity` |
| notesnook-server | `dpdata-notesnook` |
| sse-server | `dpdata-sse` |
| monograph-server | `dpdata-monograph` |

Volumes are owned by UID `1000` (`dotnetuser`). Mismatched ownership produces
`UnauthorizedAccessException` on `.tmp` key writes. Fix: `chown -R 1000:1000` on
the volume, or wipe contents and restart to regenerate keys.

Token validity survives container restarts because keys are persisted. Back up
these volumes or you lose auth on volume loss.

## Restart policy

Autoheal is the only process allowed to restart containers. Application containers
have no restart policy. One-shot services (`validate`, `setup-s3`) use `restart: "no"`.

## What is different in this fork

1. `MONGODB_DATABASE_NAME` is honored by all repositories (was hardcoded for some).
2. `NOTESNOOK_CORS_ORIGINS` env var is wired correctly (upstream read the wrong key).
3. Missing OAuth `profile` scope added in Identity Config to fix signup validation errors.
4. DataProtection uses per-service volumes instead of one shared `dpdata` volume.
5. MongoDB is not exposed on a host port; reachable only inside the Docker network.
6. Healthchecks use `nc`/`node`/`bun` rather than `wget`.
7. All streetwriters images pinned to `v1.0-beta.32`; monograph to `1.3.1`;
   MinIO to immutable timestamp tags; MongoDB at `8.0.28`.

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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `validate` exits 1 | Missing required env var | Check `.env.local`, `docker compose logs validate` |
| Signup fails with scope validation | Identity missing profile scope | Confirm `Streetwriters.Identity/Config.cs` registers `profile` scope |
| Sync works but web client blank | `MONOGRAPH_PUBLIC_URL` mismatched | Set it to the browser URL exactly |
| Attachments 404 | `ATTACHMENTS_SERVER_PUBLIC_URL` wrong | Must match presigned URL host |
| Tokens invalidated after restart | DataProtection volume ownership wrong | `chown -R 1000:1000` on the dpdata volume, restart |
| DataProtection UnauthorizedAccessException | Shared volume or wrong owner | Per-service volumes + uid 1000 ownership |
| Notes disappearing | Sync conflict, not server bug | Export notes regularly |

## Update policy

This stack pins images to specific version tags. Updates are deliberate:

1. `git pull origin master`
2. Check which tags changed in `docker-compose.yml`
3. `docker compose pull`
4. `docker compose up -d`

### MongoDB 7.0 → 8.0

MongoDB 8.0 requires FCV migration before the image change:
1. `db.adminCommand({ setFeatureCompatibilityVersion: "7.0" })`
2. `docker compose down`
3. Update image tag to `mongo:8.0.28`
4. `docker compose up -d`
5. `db.adminCommand({ setFeatureCompatibilityVersion: "8.0" })`

### MinIO

MinIO release tags are immutable timestamps. No breaking changes expected when
advancing the pinned timestamp.

## Image pin rationale

| Image | Current Tag | Pin Reason |
|---|---|---|
| `mongo` | `8.0.28` | Host CPU AVX2 required; immutable tag avoids silent major upgrade. |
| `minio/minio` | `RELEASE.2025-09-07T16-13-09Z` | Immutable timestamp; identical SHA256 on every pull. |
| `minio/mc` | `RELEASE.2025-08-13T08-35-41Z` | One-shot bucket setup tool; immutable timestamp. |
| `streetwriters/identity` | `v1.0-beta.32` | Immutable semver; `:latest` would drift silently. |
| `streetwriters/notesnook-sync` | `v1.0-beta.32` | Same. |
| `streetwriters/sse` | `v1.0-beta.32` | Same. |
| `streetwriters/monograph` | `1.3.1` | Stable semver; `:latest` was moving target. |
| `vandot/alpine-bash` | `:latest` | One-shot `validate` image; `restart: "no"`, state is ephemeral. |
