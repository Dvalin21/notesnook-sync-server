#!/bin/sh
# Volume backup for the whole stack state (no mongodump binary needed).
# Run: docker compose --profile backup run --rm backup
# Dumps land in ./backups/<stamp>/ on the host (gitignored). PBS covers the whole
# LXC; this is the application-consistent layer a crash-consistent snapshot
# cannot give you (mongod mid-write needs WiredTiger recovery after restore).
#
# WHY each piece (restore matrix):
#   dbdata           Mongo: users, grants, sync items, monograph/inbox records.
#                    fsyncLock makes the tar crash-consistent; trap guarantees unlock.
#   dpdata-*         ASP.NET DataProtection keys. Lose them = everyone logged out (data intact).
#   keystore-data    GPG signing keys. Lose them = regenerate; old verify links die.
#   .env             Secrets + URLs. Without it the dump is unrestorable as THIS stack.
#   s3data           NOT here (bulk blobs). MinIO versioning + PBS covers it.
# ponytail: tar beats mongodump (no tools image, catches dpdata/keystore in one pass).
set -eu
STAMP=${STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}
OUT=${OUT:-/backups/$STAMP}
# Auth is enabled on mongod, and Mongo disables the unauthenticated localhost
# exception as soon as the first user exists, so an unauthenticated URI is
# refused outright. Credentials arrive via the two MONGO_* vars the compose
# backup service injects; fail loudly rather than silently skipping.
MONGO=${MONGO:-"mongodb://${MONGO_USER:?MONGO_USER not set}:${MONGO_PASS:?MONGO_PASS not set}@notesnook-db:27017/?authSource=admin"}
# This tree gets .env, DataProtection keys and the GPG keyring. 077 so a failed
# run can never leave world-readable credentials on disk.
umask 077
mkdir -p "$OUT"
if [ -f /envfile ]; then install -m 600 /envfile "$OUT/.env"; echo "saved .env (0600)"; fi
# ponytail: fsyncLock makes the dbdata tar crash-consistent; trap guarantees unlock.
# timeout: fsyncLock blocks ALL writes and has no built-in timeout -- if mongod
# already holds a lock this hangs the backup forever. Fail loudly instead.
timeout 300 mongosh "$MONGO" --quiet --eval 'db.fsyncLock()' >/dev/null
trap 'timeout 60 mongosh "$MONGO" --quiet --eval "db.fsyncUnlock()" >/dev/null 2>&1 || true' EXIT INT TERM
# dpdata-monograph is deliberately absent: monograph-server is a Bun image with no
# ASP.NET DataProtection, so that volume is permanently empty (verified: 0 files).
# Backing up a phantom is how you "restore" a keyring that never existed.
fail=0
for v in dbdata dpdata-identity dpdata-notesnook dpdata-sse keystore-data; do
  # --numeric-owner preserves UID/GID so dpdata/keystore restore with the
  # ownership the .NET host needs. Without it, restores break DataProtection.
  set +e
  tar --numeric-owner -czf "$OUT/$v.tgz" -C "/vol/$v" . 2>"$OUT/$v.err"
  rc=$?
  set -e
  # tar exit codes are NOT all fatal:
  #   0 = clean
  #   1 = warning (file changed while reading). Expected and unavoidable for
  #       dbdata: fsyncLock blocks client writes but WiredTiger still advances
  #       its own journal/checkpoint/diagnostic.data. Failing here would make
  #       this script report BACKUP_FAILED forever and train you to ignore it.
  #   2 = fatal (cannot open, out of space, unreadable volume). A real failure.
  case $rc in
    0) : ;;
    1) echo "WARN $v: changed during read (expected for live mongod under fsyncLock)" ;;
    *) echo "FAIL $v: tar exit $rc"; sed 's/^/      /' "$OUT/$v.err"; fail=1; continue ;;
  esac
  # "Did this archive capture anything?" -- ask tar, not a size floor. A dpdata
  # volume is one DataProtection key (~700 bytes gzipped) and a healthy archive
  # of it is legitimately tiny; an empty dir compresses to ~100 bytes. Counting
  # entries distinguishes them without a magic number that rots as data grows.
  n=$(tar -tzf "$OUT/$v.tgz" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || { echo "FAIL $v: archive contains no files"; fail=1; }
done
# A backup that backed up nothing must never print BACKUP_OK. Ever.
[ "$fail" -eq 0 ] || { echo "BACKUP_FAILED $STAMP"; exit 1; }
echo "--- $OUT ---"
ls -la "$OUT"
echo "BACKUP_OK $STAMP"
