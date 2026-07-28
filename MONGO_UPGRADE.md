# MongoDB 7.0 → 8.0 Upgrade Guide

This fork pins MongoDB at `8.0.28` (upgraded from `7.0.12`). MongoDB 8.0 requires a
Feature Compatibility Version (FCV) migration — you cannot jump directly from 7.0 to 8.0
without setting the FCV at each stage.

## Prerequisites

- Docker and docker compose v2
- A backup of your MongoDB data (see [Backup](#backup) below)
- The Silver 4114 CPU supports AVX2, which MongoDB 8.0 requires

## Step-by-step procedure

### 1. Back up your data

```bash
# Stop the stack
docker compose down

# Back up the MongoDB volume
docker run --rm -v notesnook-sync-server_dbdata:/src -v /backup/mongo:/dst \
  alpine sh -c "cp -a /src/. /dst/"

# Back up the DataProtection keys volume
docker run --rm -v notesnook-sync-server_dpdata:/src -v /backup/dpdata:/dst \
  alpine sh -c "cp -a /src/. /dst/"

# Restart the stack
docker compose up -d
```

### 2. Set FCV to 7.0 (before upgrading)

Connect to the running MongoDB 7.0 instance and set the FCV to `7.0`:

```bash
docker compose exec notesnook-db mongosh mongodb://localhost:27017/notesnook \
  --eval 'db.adminCommand({ setFeatureCompatibilityVersion: "7.0" })'
```

Verify:

```bash
docker compose exec notesnook-db mongosh mongodb://localhost:27017/notesnook \
  --eval 'db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 })'
```

Expected output: `{ "featureCompatibilityVersion" : { "version" : "7.0" } }`

### 3. Stop the stack

```bash
docker compose down
```

### 4. Update the image tag

Edit `docker-compose.yml` and change:

```yaml
image: mongo:7.0.12
```

to:

```yaml
image: mongo:8.0.28
```

### 5. Start the stack with MongoDB 8.0

```bash
docker compose up -d
```

Wait for the MongoDB healthcheck to pass:

```bash
docker compose ps notesnook-db
# STATUS should show "healthy"
```

### 6. Set FCV to 8.0

```bash
docker compose exec notesnook-db mongosh mongodb://localhost:27017/notesnook \
  --eval 'db.adminCommand({ setFeatureCompatibilityVersion: "8.0" })'
```

Verify:

```bash
docker compose exec notesnook-db mongosh mongodb://localhost:27017/notesnook \
  --eval 'db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 })'
```

Expected output: `{ "featureCompatibilityVersion" : { "version" : "8.0" } }`

### 7. Verify the application

```bash
curl -fsS http://localhost:5264/health && echo " sync OK"
curl -fsS http://localhost:8264/health && echo " auth OK"
curl -fsS http://localhost:7264/health && echo " sse OK"
curl -fsS http://localhost:3000/api/health && echo " monograph OK"
```

## Rollback procedure

If you need to roll back to MongoDB 7.0:

1. Stop the stack: `docker compose down`
2. Revert the image tag in `docker-compose.yml` to `mongo:7.0.12`
3. Restore the `dbdata` volume from your backup (MongoDB 8.0 data files are not
   backward-compatible with 7.0)
4. Start the stack: `docker compose up -d`
5. Set FCV to 7.0: `db.adminCommand({ setFeatureCompatibilityVersion: "7.0" })`

## Notes

- The .NET MongoDB driver used by the sync server is compatible with MongoDB 8.0's
  wire protocol (backward-compatible with 3.6+).
- The replica set (`rs0`) configuration is preserved across the upgrade.
- If the healthcheck fails after upgrade, check `docker compose logs notesnook-db`
  for FCV-related errors.
