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
| Image tags | `:latest` for all | Pinned digests/tags per table below |
| Monograph app links | Hardcoded `https://app.notesnook.com` | `dvalin21/notesnook-monograph` bakes `NOTESNOOK_APP_URL` at build |

## Custom images — what changed vs upstream source

| Image | Base | Source diff |
|---|---|---|
| `dvalin21/notesnook-sync` | upstream sync | MongoDB driver 2.22→3.2.1 (Mongo 8 wire), caller bearer forwarded to identity, missing `await` in users path, WAMP middleware ordering, static `HttpClient` in S3 path, `MongoDbSettings__*` env support |
| `dvalin21/notesnook-identity` | upstream identity | `profile` scope for Notesnook 3.x OIDC, GPG persisted via keystore volume + entrypoint, `X-Forwarded-Host`/template reformat, working password change/reset/delete, fail-closed login (no auto-create), LocalApi auth restored on MFA controller (recovery codes) |
| `dvalin21/notesnook-sse` | upstream sse | WAMP removed (.NET 9 incompatible), session-clear notify best-effort |
| `dvalin21/notesnook-monograph` | upstream monograph 1.3.1 (same monorepo pin as web image) | Placeholder `app.example.com` baked in; `server.ts` rewrites it to `$NOTESNOOK_APP_HOST` per request — no real domain in the image. Image carries no `NOTESNOOK_APP_HOST` default (upstream ignores that env). |
| `dvalin21/notesnook-web` | upstream web @ same pin | `NN_API/AUTH/SSE/MONOGRAPH_HOST` baked as `example.com` placeholders; `web/entrypoint.sh` swaps operator URLs at boot. Connectivity check hits configured API; sourcemaps stripped. |
| `dvalin21/notesnook-cors-proxy` | `./cors-proxy` source | Preflight fix, logging cleanup |
| `dvalin21/minio-notesnook` | minio | Pinned rebuild (no source fork) |

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
| mongo | 8.0.30 | 7.0.12→8.0 (consecutive major; FCV stepped post-boot). 8.0.30 required: ≤8.0.29 refuse kernels 6.19–7.0.13 (SERVER-121912) |
| minio/minio | `RELEASE.2025-09-07T16-13-09Z` | Immutable timestamp tag |
| minio/mc | `RELEASE.2025-08-13T08-35-41Z` | Bucket setup tool (one-shot) |
| dvalin21/notesnook-sync | `latest` + dated | Custom build (see table above) |
| dvalin21/notesnook-identity | `latest` + dated | Custom build (see table above) |
| dvalin21/notesnook-sse | `latest` + dated | Custom build (see table above) |
| dvalin21/notesnook-monograph | `latest` + `20260908` | Custom build (see table above) |
| dvalin21/notesnook-web | `latest` | Custom build (see table above) |
| streetwriters/notesnook-inbox | `latest` | Upstream, unmodified |
| streetwriters/themes-server | `latest` | Upstream, unmodified |
| caddy | alpine | Small image, internal routing only |
| cors-proxy | *(build from source)* | Custom CORS proxy |
| vandot/alpine-bash | `:latest` | One-shot validate service (low risk) |

### autoheal

`willfarrell/autoheal` restarts any container Docker marks as `unhealthy`.
Docker's `restart: unless-stopped` only handles container exits (crashes),
not healthcheck failures. autoheal covers that gap.

## Known issues (not fixed here)

- Client/server version skew: app 3.3 broke self-hosted sync. Pin client to 3.2.4 if hit.
- Backups: use the profile-gated service — `docker compose --profile backup run --rm backup`
  (fsyncLock + tar of dbdata, all `dpdata-*`, keystore; dumps land in `./backups/<stamp>/`,
  tested round-trip 2026-09-08). s3data blobs excluded — mirror MinIO separately.
- Monograph PDF viewing has pre-existing issues unrelated to the S3 backend.
