#!/bin/bash
# Delete accounts that were never confirmed by email.
#
# WHY
# POST /users creates the identity row, sends a confirmation mail, and hands
# back a token -- all before anyone proves they own the address. The account is
# inert (MFAService refuses until the email is confirmed, and the sync API
# returns 401 for the token), so this is not an access-control hole. It is
# unbounded STORAGE: every anonymous attempt that reaches the mailer leaves a
# user row plus two persisted-grant rows, and nothing ever removed them. On a
# public instance that is a slow-fill disk attack and, with a signing relay, an
# email relay. The signup rate limit bounds the rate; this bounds the residue.
#
# USAGE
#   bash scripts/prune-unconfirmed.sh              # delete older than 7 days
#   RETENTION_DAYS=30 bash scripts/prune-unconfirmed.sh
#   DRY_RUN=1 bash scripts/prune-unconfirmed.sh    # report only, delete nothing
#
# CRON (daily, 04:17 -- an off-the-minute time so it does not collide with
# every other job on the box)
#   17 4 * * * cd /path/to/notesnook && RETENTION_DAYS=7 bash scripts/prune-unconfirmed.sh >> /var/log/notesnook-prune.log 2>&1
#
# ponytail: a shell script and one cron line. This runs once a day; it does not
# justify a permanent container in the compose file. If you would rather have it
# in-band, wrap this in a loop and add it as a profile-gated service.
set -euo pipefail
cd "$(dirname "$0")/.."

RETENTION_DAYS="${RETENTION_DAYS:-7}"
DRY_RUN="${DRY_RUN:-0}"

# using eval word-splits the multi-line JS and executes fragments as shell.
# Credentials come from .env, the same place the stack reads them from.
[ -f .env ] || { echo "no .env -- run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MONGO_USER:?not in .env}" "${MONGO_PASS:?not in .env}"

echo "pruning accounts unconfirmed for more than ${RETENTION_DAYS}d (dry_run=${DRY_RUN})"

# EmailConfirmed is a bool and ASP.NET Identity stamps no created-at on the row,
# so the only age signal available is the ObjectId: its first 4 bytes are a Unix
# timestamp. In mongosh getTimestamp() returns a DATE, not seconds -- verified:
# typeof _id.getTimestamp() === 'object'. Multiplying it by 1000 as if it were a
# number is the bug this script was first written with, and it silently prunes
# nothing.
SCRIPT_FILE=$(mktemp)
trap 'rm -f "$SCRIPT_FILE"' EXIT
cat > "$SCRIPT_FILE" <<JSEOF
const days = ${RETENTION_DAYS};
const cutoff = Date.now() - days * 86400000;
const db = db.getSiblingDB('identity');
const stale = db.users.find({ EmailConfirmed: false }).toArray().filter(function (u) {
  return u._id.getTimestamp().getTime() < cutoff;
});
print('  unconfirmed total : ' + db.users.countDocuments({ EmailConfirmed: false }));
print('  older than ' + days + 'd  : ' + stale.length);
if (${DRY_RUN}) { print('  DRY RUN - nothing deleted'); }
else {
  let n = 0;
  stale.forEach(function (u) { n += db.users.deleteOne({ _id: u._id }).deletedCount; });
  // Grant rows are keyed by subject; without this the survivors keep valid
  // refresh tokens for accounts that no longer exist.
  const ids = stale.map(function (u) { return u._id.toString(); });
  const g = db.PersistedGrants.deleteMany({ SubjectId: { \$in: ids } });
  const c = db.PersistedGrants.deleteMany({ ClientId: { \$in: ids } });
  print('  deleted users     : ' + n);
  print('  deleted grants    : ' + (g.deletedCount + c.deletedCount));
}
JSEOF


docker run --rm --network "${COMPOSE_PROJECT_NAME:-notesnook}_notesnook" \
  --env MONGO_USER --env MONGO_PASS mongo:8.0.30 \
  mongosh "mongodb://$MONGO_USER:$MONGO_PASS@notesnook-db:27017/admin?authSource=admin" \
  --quiet --eval "$(cat "$SCRIPT_FILE")"
