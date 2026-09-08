#!/bin/sh
# mongodump-free volume backup: fsyncLock + tar. Run via compose profile:
#   docker compose --profile backup run --rm backup
# Dumps land in ./backups/<stamp>/ on the host. Copy off-host; add cron later.
# ponytail: s3data (blobs) excluded - bulk MinIO mirror, not a tar job.
set -eu
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
OUT=${OUT:-/backups/$STAMP}
MONGO=${MONGO:-mongodb://notesnook-db:27017}
mkdir -p "$OUT"
# ponytail: fsyncLock makes the dbdata tar crash-consistent; trap guarantees unlock.
mongosh "$MONGO" --quiet --eval 'db.fsyncLock()' >/dev/null
trap 'mongosh "$MONGO" --quiet --eval "db.fsyncUnlock()" >/dev/null' EXIT INT TERM
for v in dbdata dpdata-identity dpdata-notesnook dpdata-sse dpdata-monograph keystore-data; do
  tar -czf "$OUT/$v.tgz" -C "/vol/$v" . 2>/dev/null || echo "SKIP $v (not mounted)"
done
ls -la "$OUT"
echo "BACKUP_OK $STAMP"
