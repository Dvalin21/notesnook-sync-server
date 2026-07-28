# Notesnook Sync Server (fork of streetwriters/notesnook-sync-server)

Full source for the Notesnook sync backend (Notesnook / Streetwriters). AGPLv3 licensed.

This fork contains operational hardening fixes (CORS env-var, MONGODB_DATABASE_NAME, restart policies, DataProtection key persistence, image pinning). The original upstream README and INSTALL are superseded by this file.

## What this stack runs (all in Docker)

| Service | Port | Description |
|---|---|---|
| identity-server | 8264 | Authentication & signup |
| notesnook-server | 5264 | Sync engine |
| sse-server | 7264 | Server-sent events for real-time sync |
| monograph-server | 6264 | Web client |
| notesnook-db | — | MongoDB 8.0.28 replica set |
| notesnook-s3 | — | MinIO S3 storage for attachments (internal only) |
| setup-s3 | — | One-shot bucket creator (runs once, then stops) |

You still need your own TLS termination in front (Caddy, nginx, Traefik, Cloudflare Tunnel, etc.). The stack speaks plain HTTP internally.

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
curl -fsS http://localhost:3000/api/health && echo " monograph OK"

# 6. Open monograph in browser (behind YOUR TLS proxy)
#    http://monogr.ph  (or whatever MONOGRAPH_PUBLIC_URL you set)
```

That it. If anything fails, `docker compose logs <service name>` shows why.

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
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Base URL where S3 attachments are reachable (via your TLS proxy) | `https://attach.mydomain.com` |

### Optional (defaults work for most)

| Variable | Default | What |
|---|---|---|
| `MONGODB_DATABASE_NAME` | `notesnook` | MongoDB database name. Changing it now honors the env var (was hardcoded before). |
| `NOTESNOOK_CORS_ORIGINS` | *(empty)* | Comma-separated list of allowed browser CORS origins. Leave empty = any origin allowed (fine behind your TLS proxy). |
| `MINIO_ROOT_USER` | `minioadmin` | MinIO admin user. `minioadmin` default is well-known — change it. |
| `MINIO_ROOT_PASSWORD` | `minioadmin` | MinIO admin password. Same warning. |
| `GARAGE_ACCESS_KEY_ID` | *(empty)* | Garage S3 access key (required only when using Garage overlay). |
| `GARAGE_ACCESS_KEY_SECRET` | *(empty)* | Garage S3 secret key (required only when using Garage overlay). |
| `GARAGE_RPC_SECRET` | *(empty)* | Garage RPC secret for inter-node communication (required for multi-node). |
| `IS_SELF_HOSTED` | *(auto)* | Set automatically based on `AUTH_SERVER_PUBLIC_URL` format. Don't touch unless you know why. |

## How to install — full step by step

### Prerequisites

- Docker and Docker Compose v2 on a Linux host.
- A domain or LAN IP you control. Notesnook clients need fixed URLs.
- Ports you'll use (you only need to expose these through your TLS proxy, not directly to the internet):
  - 5264 — sync
  - 8264 — auth
  - 7264 — SSE
  - 6264 — web client
  - 9000 — MinIO (INTERNAL ONLY, never expose publicly)
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

Don't expose MinIO port 9000 to the internet. Your TLS proxy reaches it internally via docker network.

### Step 4 — set up TLS / reverse proxy

This stack has no built-in TLS. Put something in front. Example Caddy (simplest):

```
auth.mydomain.com {
  reverse_proxy localhost:8264
}
sync.mydomain.com {
  reverse_proxy localhost:5264
}
sse.mydomain.com {
  reverse_proxy localhost:7264
}
monogr.ph {
  reverse_proxy localhost:6264
}
attach.mydomain.com {
  reverse_proxy localhost:9000
}
```

Set `AUTH_SERVER_PUBLIC_URL`, `NOTESNOOK_APP_PUBLIC_URL`, `MONOGRAPH_PUBLIC_URL`, `ATTACHMENTS_SERVER_PUBLIC_URL` to match these HTTPS names.

### Step 5 — run

```bash
docker compose up -d
docker compose logs -f
```

Wait for the validate service to print "All required environment variables are set." Then check health endpoints (see Quick start above).

### Step 6 — create your first account

Go to your Notesnook client (app or web) → Settings → Sync → "Use custom server". Enter the URLs from `AUTH_SERVER_PUBLIC_URL`, `NOTESNOOK_APP_PUBLIC_URL`, etc. The first account you create becomes the admin — with `DISABLE_SIGNUPS=true` you must use that one account for everything unless you set it to false temporarily.

## What's different in this fork vs upstream

1. CORS env var `NOTESNOOK_CORS_ORIGINS` actually works (upstream read the wrong env key).
2. `MONGODB_DATABASE_NAME` env var is honored for all 13 collections (was hardcoded to "notesnook" for 7 of them).
3. All app services have `restart: unless-stopped` (upstream had none — a crash left services permanently down).
4. `dpdata` volume persists DataProtection keys so container restarts don't invalidate all auth tokens.
5. `autoheal` removed (unnecessary socket mount, replaced by native restart policies).
6. MinIO port 9000 not exposed to host (internal only).
7. All streetwriters images pinned to specific version tags (was `:latest` everywhere).
8. Monograph / sync / SSE / identity healthchecks use `curl` instead of `wget` (wget missing in monograph image).
9. `setup-s3` bucket creation is idempotent (`|| true`).

## Migrating from MinIO to Garage S3

MinIO is ending active community development for the self-hosted edition. Garage is a
self-hosted S3-compatible object storage engine (written in Go) that is a drop-in
replacement for attachment storage.

### What changes

| Component | MinIO (default) | Garage (overlay) |
|---|---|---|
| Image | `minio/minio:RELEASE.2025-09-07T16-13-09Z` | `dxflrs/garage:v2.1.0` |
| S3 API port | 9000 | 3900 |
| Admin API port | 9090 (console) | 3903 |
| Bucket setup | `mc mb` (MinIO client) | `setup-garage.sh` (S3 PUT with SigV4) |
| `S3_INTERNAL_SERVICE_URL` | `http://notesnook-s3:9000` | `http://garage:3900` |
| `S3_ACCESS_KEY_ID` / `S3_ACCESS_KEY` | `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | `GARAGE_ACCESS_KEY_ID` / `GARAGE_ACCESS_KEY_SECRET` |

### How to migrate

1. **Add Garage env vars to `.env.local`:**

   ```bash
   GARAGE_RPC_SECRET=$(openssl rand -base64 32)
   GARAGE_ACCESS_KEY_ID=$(openssl rand -base64 12)
   GARAGE_ACCESS_KEY_SECRET=$(openssl rand -base64 24)
   ```

2. **Start the stack with the Garage overlay:**

   ```bash
   docker compose -f docker-compose.yml -f examples/garage/docker-compose.garage.yml up -d
   ```

3. **Run the bucket setup script (once):**

   ```bash
   GARAGE_ACCESS_KEY_ID=<your-key> GARAGE_ACCESS_KEY_SECRET=<your-secret> \
     bash examples/garage/setup-garage.sh
   ```

4. **Migrate existing attachments (if any):**

   ```bash
   # Copy from old MinIO volume to new Garage volume
   docker run --rm -v notesnook-sync-server_s3data:/src -v notesnook-sync-server_garage-data:/dst \
     alpine sh -c "cp -a /src/. /dst/"
   ```

5. **Update `ATTACHMENTS_SERVER_PUBLIC_URL`** to point at your TLS proxy in front of
   Garage (port 3900 internally).

6. **Stop and remove the old MinIO stack:**

   ```bash
   docker compose down
   docker compose -f docker-compose.yml -f examples/garage/docker-compose.garage.yml up -d
   ```

### Garage configuration

The Garage config file lives at `examples/garage/garage.toml`. It binds:
- S3 API on port 3900
- RPC on port 3901
- Web UI on port 3902
- Admin API on port 3903

For single-node deployments, `replication_factor = 1` and `consistency_mode = "consistent"`
are sufficient. For multi-node, increase the replication factor and set `rpc_public_addr`
to the node's reachable address.

### Compatibility notes

- Garage uses S3 API v4 signatures — compatible with the .NET AWS SDK used by the sync server.
- `forcePathStyle=true` (set in the sync server) works with Garage.
- Garage does not ship an `mc`-equivalent CLI — bucket creation uses the S3 PUT API
  (see `setup-garage.sh`).
- Monograph PDF viewing has pre-existing issues unrelated to the S3 backend.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `validate` service exits 1 | Missing required env var | Check `.env.local`, `docker compose logs validate` |
| Signup fails with "scope validation error" | MinIO admin not changed from default | Set `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` to strong values |
| Sync works but web client blank | `MONOGRAPH_PUBLIC_URL` wrong or CORS blocking | Set `MONOGRAPH_PUBLIC_URL` to match your browser URL exactly |
| Attachments 404 | `ATTACHMENTS_SERVER_PUBLIC_URL` wrong | Must point at the same host the presigned URL uses |
| Tokens invalidated after restart | DataProtection keys not persisted | `dpdata` volume missing or wrong mount path |
| Notes disappearing | Sync conflict, not server bug | Export your notes regularly (see backup below) |

## Backup (you need this or you will lose data)

```bash
# MongoDB backup
docker compose exec notesnook-db mongodump --uri="mongodb://localhost:27017/notesnook" --archive=/backup/notesnook-$(date +%Y%m%d).archive

# MinIO attachments backup (default stack)
docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3

# Garage attachments backup (Garage overlay)
# Garage stores data in /var/lib/garage/data — copy the volume
docker run --rm -v notesnook-sync-server_s3data:/src -v /backup/garage:/dst \
  alpine sh -c "cp -a /src/. /dst/"
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
| `minio/minio` | `RELEASE.2025-09-07T16-13-09Z` | **Default S3 backend.** Immutable timestamp tag — same binary, same SHA256 digest forever. Can be replaced by Garage via overlay (see "Migrating from MinIO to Garage S3" above). |
| `minio/mc` | `RELEASE.2025-08-13T08-35-41Z` | **Default bucket setup tool.** Only used by `setup-s3` one-shot service. Replaced by `setup-garage.sh` when using Garage overlay. |
| `dxflrs/garage` | `v2.1.0` | **Alternative S3 backend (overlay only).** Pinned to v2.1.0 for stability. See `examples/garage/docker-compose.garage.yml`. |
| `streetwriters/identity` | `v1.0-beta.32` | **Our pin, replacing `:latest`.** Versioned tag is immutable — `:latest` would drift. Docker Hub API confirmed `v1.0-beta.32` digest == `:latest` digest at pin time. |
| `streetwriters/notesnook-sync` | `v1.0-beta.32` | Same rationale as identity. |
| `streetwriters/sse` | `v1.0-beta.32` | Same rationale as identity. |
| `streetwriters/monograph` | `1.3.1` | **Our pin, replacing `:latest`.** Monograph uses explicit version tags; `1.3.1` is stable and will not mutate. Docker Hub API confirmed same digest as `:latest` at pin time. |
| `vandot/alpine-bash` | *(none — `:latest` implied)* | **Intentional, low risk.** One-shot utility image (`restart: "no"`) used only by the `validate` service to check env vars before the stack starts. Runs once and exits; no persistent state. `:latest` drift here has zero operational impact. |

## Known issues (upstream, not fixed in this fork)

- #105 signup scope validation error: fixed in this fork by adding missing `profile` scope to `Config.cs`. If you still hit signup failures, grab a log and confirm the `profile` scope is reaching the identity server.
- Client/server version skew (client #8698): app 3.3 broke self-hosted sync; fix was to pin the client to 3.2.4. Not fixable in this repo — pin the client version.
- DataProtection keys still in a docker named volume. Back up `dpdata` or you lose tokens on volume loss.

## License

AGPLv3. See upstream LICENSE file.
