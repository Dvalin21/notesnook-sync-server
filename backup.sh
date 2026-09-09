#!/bin/sh
# Volume backup for the whole stack state (no mongodump binary needed).
# Run: docker compose --profile backup run --rm backup
# Dumps land in ./backups/<stamp>/ on the host (gitignored). Copy off-host; cron it.
#
# WHY each piece (restore matrix):
#   dbdata           Mongo: users, grants, sync items, monograph/inbox records.
#                    fsyncLock makes the tar crash-consistent; trap guarantees unlock.
#   dpdata-*         ASP.NET DataProtection keys. Lose them = everyone logged out (data intact).
#   keystore-data    GPG signing keys. Lose them = regenerate; old verify links die.
#   .env             Secrets + URLs. Without it the dump is unrestorable as THIS stack.
#   s3data           NOT here (bulk blobs). Mirror it instead, see README Backups.
# ponytail: tar beats mongodump (no tools image, catches dpdata/keystore in one pass).
set -eu
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
OUT=${OUT:-/backups/$STAMP}
MONGO=${MONGO:-mongodb://notesnook-db:27017}
mkdir -p "$OUT"
if [ -f /envfile ]; then cp /envfile "$OUT/.env"; echo "saved .env"; fi
# ponytail: fsyncLock makes the dbdata tar crash-consistent; trap guarantees unlock.
mongosh "$MONGO" --quiet --eval 'db.fsyncLock()' >/dev/null
trap 'mongosh "$MONGO" --quiet --eval "db.fsyncUnlock()" >/dev/null' EXIT INT TERM
for v in dbdata dpdata-identity dpdata-notesnook dpdata-sse dpdata-monograph keystore-data; do
  tar -czf "$OUT/$v.tgz" -C "/vol/$v" . 2>/dev/null || echo "SKIP $v (not mounted)"
done
ls -la "$OUT"
echo "BACKUP_OK $STAMP"
