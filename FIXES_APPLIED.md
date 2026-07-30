# Notesnook Sync Stack (MinIO) — Changes from upstream

Upstream: streetwriters/notesnook-sync-server (no Caddy, `:latest` tags).

## Stack differences

| Area | Upstream (master) | This fork |
|---|---|---|
| S3 backend | MinIO (`notesnook-s3:9000`) | MinIO (same, but not exposed to host in upstream) |
| Proxy | None | Caddy internal reverse proxy (port 8080) |
| CORS proxy | None | Built from `./cors-proxy` source |
| Health monitor | None | `restart: unless-stopped` on all services |
| S3 exposure | Port 9000 exposed | Port 9000 exposed (remove for strict Caddy-only) |
| Image tags | `:latest` for all | Pinned to specific versions |

## Changes from upstream source code

- `Streetwriters.Common/Constants.cs`: CORS env-var reads `NOTESNOOK_CORS_ORIGINS`
  (upstream read wrong key `NOTESNOOK_CORS`).
- `Notesnook.API/Startup.cs`: All 13 collections use `MONGODB_DATABASE_NAME` env var
  (upstream hardcoded "notesnook" for 7 of them).
- `Streetwriters.Identity/Config.cs`: Added `profile` scope required by Notesnook 3.x
  OIDC flow.

## Operational changes

- All services have `restart: unless-stopped` (upstream had none — crash = permanent down).
- `dpdata` volume persists DataProtection keys across container recreates
  (token invalidation fixed).
- Monograph binds `HOST: "0.0.0.0"` (upstream used `localhost` → IPv6 → Docker can't map).
- Healthchecks use `wget` for .NET images and `bun` for Node/Bun images.
- Resource limits (CPU/memory) set on all services.
- One-shot services (`validate`, `setup-s3`) explicitly `restart: "no"`.
- `setup-s3` bucket creation is idempotent (`|| true`).

## Image pins

| Image | Tag | Reason |
|---|---|---|
| mongo | 8.0.28 | Upgraded from 7.0.12 (FCV migration required) |
| minio/minio | `RELEASE.2025-09-07T16-13-09Z` | Immutable timestamp tag |
| minio/mc | `RELEASE.2025-08-13T08-35-41Z` | Bucket setup tool (one-shot) |
| streetwriters/identity | v1.0-beta.32 | Immutable tag (was `:latest`) |
| streetwriters/notesnook-sync | v1.0-beta.32 | Same |
| streetwriters/sse | v1.0-beta.32 | Same |
| streetwriters/monograph | 1.3.1 | Stable version tag |
| caddy | alpine | Small image, internal routing only |
| cors-proxy | *(build from source)* | Custom CORS proxy |
| vandot/alpine-bash | `:latest` | One-shot validate service (low risk) |

### autoheal

`willfarrell/autoheal` restarts any container Docker marks as `unhealthy`.
Docker's `restart: unless-stopped` only handles container exits (crashes),
not healthcheck failures. autoheal covers that gap.

## Known issues (not fixed here)

- Client/server version skew: app 3.3 broke self-hosted sync. Pin client to 3.2.4 if hit.
- DataProtection keys in a Docker named volume — back up `dpdata` or lose tokens on volume loss.
- Monograph PDF viewing has pre-existing issues unrelated to the S3 backend.
