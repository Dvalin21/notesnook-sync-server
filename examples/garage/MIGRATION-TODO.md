# Garage S3 Migration for notesnook-sync-server (Dvalin21 fork)

Branched from master after MinIO (RELEASE.2025-09-07T16-13-09Z) and MongoDB 8.0.28 updates.

## Status

Complete. The Garage overlay is a working Docker Compose overlay that replaces MinIO
with Garage S3-compatible object storage.

## What is Garage

Garage is a self-hosted S3-compatible object storage engine written in Go, designed for
small geo-distributed deployments. It is a community fork / alternative to MinIO which
is ending active community development for the self-hosted edition.

- Image: `dxflrs/garage:v2.1.0`
- S3 API: port 3900 (internal)
- RPC: port 3901
- Web (S3 browser): port 3902
- Admin: port 3903

## Files in this branch

- `examples/garage/garage.toml` — Garage configuration (S3 API on 3900, RPC on 3901)
- `examples/garage/setup-garage.sh` — One-shot bucket creation script with proper AWS SigV4 signing
- `examples/garage/docker-compose.garage.yml` — Docker Compose overlay replacing MinIO with Garage
- `MONGO_UPGRADE.md` — MongoDB 7.0 → 8.0 FCV migration procedure (was missing from repo)

## How to use

```bash
# Add Garage env vars to .env.local
GARAGE_RPC_SECRET=$(openssl rand -base64 32)
GARAGE_ACCESS_KEY_ID=$(openssl rand -base64 12)
GARAGE_ACCESS_KEY_SECRET=$(openssl rand -base64 24)

# Start with Garage overlay
docker compose -f docker-compose.yml -f examples/garage/docker-compose.garage.yml up -d

# Create the bucket (run once)
GARAGE_ACCESS_KEY_ID=<your-key> GARAGE_ACCESS_KEY_SECRET=<your-secret> \
  bash examples/garage/setup-garage.sh
```

## What was fixed

1. **docker-compose.garage.yml** — Created working overlay. Replaces `notesnook-s3` (MinIO)
   with `garage` service, replaces `setup-s3` (mc) with `setup-garage` (curl + SigV4),
   overrides `notesnook-server` S3 env vars to point at `http://garage:3900`.

2. **setup-garage.sh** — Replaced broken fake Authorization header with proper AWS SigV4
   signing implementation using openssl. The original had `Signature=dummy` which would
   never authenticate.

3. **README.md** — Fixed all table formatting (`||` → `|`), added "Migrating from MinIO
   to Garage S3" section, added Garage backup instructions, updated image pin rationale.

4. **MONGO_UPGRADE.md** — Created full FCV migration procedure (was referenced in README
   but missing from repo).

## Compatibility notes

- Garage uses S3 API v4 signatures — compatible with the .NET AWS SDK used by the sync server.
- `forcePathStyle=true` (set in the sync server) works with Garage.
- Garage does not ship an `mc`-equivalent CLI — bucket creation uses the S3 PUT API.
- Monograph PDF viewing has pre-existing issues unrelated to the S3 backend.

## Challenges noted from PR #79 and community reports

- User `@jordanhandy`: Garage infinite restart loop when Docker Desktop GUI mounted
  `garage.toml` as a directory instead of a file. Fix: run `docker compose up` from CLI.
- User `@nicmart-dev` (Synology NAS): Garage works for attachments and image uploads.
  Monograph PDF viewing has pre-existing issues unrelated to S3 backend.

## Reference PRs and issues

- PR #79 (streetwriters/notesnook-sync-server): Replace MinIO with GarageHQ S3; Upgrade MongoDB to v8
- Issue #73: MinIO losing active development
- Issue #79 comments: community reports of working Garage deployments
