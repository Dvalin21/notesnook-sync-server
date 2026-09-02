# HANDOFF — notesnook-sync-server (MinIO edition)

## Current state (2026-08-31)
- **Domain**: `example.com`
- **Stack**: 12 services running from pre-built Docker Hub images
- **Repo**: `/home/keith/host/notesnook-sync-server`
- **Branch**: `master`, up to date with `origin/master`
- **Last commit**: `476803f` (fix: require email confirmation before sync)

## What's running
| Service | Image | Status |
|---------|-------|--------|
| caddy | caddy:alpine | OK (port 8080) |
| notesnook-db | mongo:8.0.28 | OK |
| notesnook-s3 (MinIO) | minio/minio:RELEASE.2025-09-07T16-13-09Z | OK |
| identity-server | streetwriters/identity:v1.0-beta.32 | Running (pre-built) |
| notesnook-server | streetwriters/notesnook-sync:v1.0-beta.32 | Running (pre-built) |
| sse-server | streetwriters/sse:v1.0-beta.32 | Running |
| monograph-server | streetwriters/monograph:1.3.1 | Running |
| inbox-api | streetwriters/notesnook-inbox:latest | Running |
| themes-server | streetwriters/themes-server:latest | Running |
| cors-proxy | custom build | Running |
| autoheal | willfarrell/autoheal:latest | Running |

## Known issues (ACTIVE)

### ISSUE 1 — Email confirmation not sent for self-hosted
**Status:** Root cause identified, fix requires image rebuild
**Problem:** Pre-built `streetwriters/identity:v1.0-beta.32` image skips sending confirmation emails when `SELF_HOSTED=1`. The original code only sends emails for SaaS (`SELF_HOSTED=0`).
**Evidence:** User receives 2FA emails (works) but not signup confirmation emails. Setting `SELF_HOSTED=0` makes confirmation emails work.
**Fix options:**
1. Set `SELF_HOSTED=0` in `.env` (simplest, but changes other behavior)
2. Rebuild identity-server from source with fix always sending email
**Workaround:** Use `SELF_HOSTED=0` for now

### ISSUE 2 — Confirm link goes to wrong domain
**Status:** Under investigation
**Problem:** Email confirm button redirects to `auth.streetwriters.co` instead of `auth.example.com`
**Expected:** `IDENTITY_SERVER_URL=https://auth.example.com` is set correctly in container env
**Possible cause:** The pre-built image may have a hardcoded fallback or the `TokenLink` method has a bug when `IDENTITY_SERVER_URL` has a path

### ISSUE 3 — Attachments not syncing to MinIO
**Status:** Root cause identified, fix pending
**Problem:** Attachments saved locally on tablet but never appear in MinIO `attachments` bucket
**Root cause:** `notesnook-s3` service in `docker-compose.yml` is missing `env_file` and explicit `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` environment variables. MinIO starts with random/default credentials instead of `.env` values.
**Evidence:** Container env shows `MINIO_ROOT_USER=MinioKeith` but `.env` has different value. `setup-s3` creates bucket with `.env` creds but MinIO runs with different creds.
**Fix:** Add to `notesnook-s3` service in `docker-compose.yml`:
```yaml
environment:
  MINIO_BROWSER: "on"
  MINIO_ROOT_USER: "${MINIO_ROOT_USER:-minioadmin}"
  MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD:-minioadmin}"
```
Then: `docker compose down`, remove `s3data` volume, `docker compose up -d`

### ISSUE 4 — MongoDB shows no data but login works
**Status:** Unsolved mystery
**Problem:** `identity` database has no users/roles collections, `notesnook` database has zero collections. Yet user can log in, receive 2FA codes, and app shows "Synced".
**Evidence:**
- `db.users.countDocuments()` returns 0
- `db.notes.countDocuments()` returns 0
- No SQLite files found in identity-server container
- MongoDB connection string points to `notesnook-db:27017`
**Possible explanations:**
1. Data was lost during container restart (WiredTiger may have rolled back)
2. There's a second MongoDB instance not yet found
3. Identity-server is using a different storage mechanism
4. Data exists but mongosh query is hitting wrong database/collection

### ISSUE 5 — Sync shows "Synced" but no server data
**Status:** Related to ISSUE 4
**Problem:** App reports sync successful but no notes/attachments appear in MongoDB
**Possible cause:** Sync engine may be failing silently, or data is being written to a different store

## Recent commits (chronological)
| Commit | Description |
|--------|-------------|
| `476803f` | fix: require email confirmation before sync (reverted auto-confirm, restored email verification gate in SyncRequirement) |
| `0bbe623` | fix: add keystore-data to init-dpdata chown |
| `e22ea44` | fix: remove email verification gate from SyncRequirement |
| `53e09d7` | fix: skip email verification gate for self-hosted in SyncRequirement |
| `71bb054` | fix: self-hosted users always report verified=true during introspection |
| `daf36b5` | fix: auto-confirm email for self-hosted to allow sync |
| `3233b1e` | fix: always send signup email, fix verify 400, persist keystore |

## Environment (.env)
```
SELF_HOSTED=1 (set to 0 for email confirmation to work)
AUTH_SERVER_PUBLIC_URL=https://auth.example.com
NOTESNOOK_APP_PUBLIC_URL=https://sync.example.com
MONOGRAPH_PUBLIC_URL=https://notes.example.com
ATTACHMENTS_SERVER_PUBLIC_URL=https://attach.example.com
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=alerts@example.com
MINIO_ROOT_USER=MinioKeith
```

## To bring the stack up
```bash
cd /home/keith/host/notesnook-sync-server
docker compose up -d
# If Caddy fails to bind port 8080:
docker rm -f notesnook-sync-server-caddy-1
docker compose up -d caddy
```

## DNS required (10 subdomains)
`*.example.com` wildcard A record → server IP covers: sync, auth, sse, notes, attach, minio, cors, inbox, themes, plus apex.

## Key files
- `docker-compose.yml` — 12 services, MinIO S3 backend
- `Caddyfile` — routes 10 subdomains by Host header on port 80 (mapped to host 8080)
- `.env` — local only, untracked, contains real URLs and secrets. Do not commit.
- `README.md` — setup guide and troubleshooting
- `test_functional.sh` — smoke test script

## Secrets (do not commit)
- `NOTESNOOK_API_SECRET`
- `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`
- SMTP credentials

## Architecture notes
- All services use pre-built Docker Hub images (not built from source)
- Source code changes in this repo do NOT affect running containers unless rebuilt
- MongoDB: single-node replica set (`rs0`)
- S3: MinIO at `notesnook-s3:9000` (internal), exposed via Caddy at `attach.example.com`
- Identity: IdentityServer4 with PGP signing keys in `keystore-data` volume
