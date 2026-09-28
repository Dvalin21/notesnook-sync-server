#!/bin/bash
# Create the bucket-scoped MinIO service account the Notesnook sync server uses,
# and print the two lines to paste into .env.
#
# Why not just use the MinIO root credentials? Because a compromise of the
# notes API would then be a compromise of object-storage administration.
#
# The policy enumerates the object actions the server actually needs. Do NOT
# widen it to "s3:*": on a bucket resource that also grants s3:DeleteBucket
# and s3:PutBucketPolicy, so the notes API could delete its own bucket.
# (That is not hypothetical -- an s3:* policy here let a test account remove
# the attachments bucket, and it was not recoverable from any backup.)
#
# Usage:  bash scripts/create-minio-app-user.sh
# Requires: the stack's .env (for MINIO_ROOT_USER / MINIO_ROOT_PASSWORD).
#           Starts notesnook-s3 if it is not already up, and waits for it.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "no .env -- run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MINIO_ROOT_USER:?not in .env}" "${MINIO_ROOT_PASSWORD:?not in .env}"

# MinIO deleted minio/mc from Docker Hub in October 2025, so this image is
# compiled from a pinned upstream commit by mc/Dockerfile via the `mc` entry in
# publish.yml. The pin that matters is MC_COMMIT in that Dockerfile: this mc
# revision defines `mb -p` as --ignore-existing, which the line below needs.
MC_IMG=${MC_IMG:-dvalin21/mc:latest}
BUCKET=${S3_BUCKET_NAME:-attachments}

# Ask compose which container it is rather than reconstructing the name.
# Compose prefixes container names with the project name, which it derives from
# the working directory unless COMPOSE_PROJECT_NAME is set -- so a checkout in
# ~/notesnook is "notesnook-notesnook-s3-1", not "...-notesnook-sync-server-...".
# Guessing that string breaks every install outside the original directory name.
S3_CTR=$(docker compose ps -q notesnook-s3 2>/dev/null | head -1)
[ -n "$S3_CTR" ] || S3_CTR="${COMPOSE_PROJECT_NAME:-notesnook-sync-server}-notesnook-s3-1"

# Wait for MinIO instead of failing instantly. This script used to be preceded
# by a `setup-s3` compose service that had an `until mc alias set` retry loop;
# that service is gone (it needed minio/mc, deleted from Docker Hub in October
# 2025), so the wait moves here where the bucket is actually created.
printf 'waiting for %s to become healthy' "$S3_CTR"
for _ in $(seq 1 60); do
  state=$(docker inspect "$S3_CTR" --format '{{.State.Status}}' 2>/dev/null || echo missing)
  if [ "$state" = "running" ]; then
    health=$(docker inspect "$S3_CTR" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo none)
    case "$health" in
      healthy|none) echo " ok"; break ;;
    esac
  fi
  printf '.'
  sleep 2
done
echo

NET=$(docker inspect "$S3_CTR" \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)
[ -n "$NET" ] || { echo "notesnook-s3 is not running: $S3_CTR" >&2; exit 1; }
mc(){ docker run --rm --network "$NET" -v "$POLICY:/policy.json:ro" \
        -e MC_HOST_s="http://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@notesnook-s3:9000" \
        "$MC_IMG" "$@"; }

POLICY=$(mktemp)
cat > "$POLICY" <<POL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:ListBucketMultipartUploads",
        "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ]
    }
  ]
}
POL
trap 'rm -f "$POLICY"' EXIT

  echo "==> ensuring the bucket exists and is versioned"
  # The target is a path and -p is --ignore-existing, so the flag goes last.
  # This mc prints to stderr and can exit non-zero; `set -e` would abort the
  # script there, so the exit code is discarded and the `mc ls` check below is
  # what actually decides whether the bucket exists.
  # `mc mb` takes the target as a PATH, and the flag goes after it. Writing
  # `mc mb -p "$BUCKET"` instead looks equivalent and is not: with the flag
  # first, this mc revision reports "Bucket name cannot be empty" and creates
  # nothing. That is why the `|| true` below is load-bearing -- but on its own
  # it also hid the failure until the `mc ls` check one line later.
  mc mb "s/$BUCKET" -p >/dev/null 2>&1 || true
mc ls "s/$BUCKET" >/dev/null 2>&1 || { echo "bucket $BUCKET is not there" >&2; exit 1; }
mc version enable "s/$BUCKET" >/dev/null 2>&1 || true

echo "==> creating the policy (overwrites any earlier one, including a lax s3:*)"
mc admin policy create s notesnook-attachments /policy.json >/dev/null

# Read it back and refuse to continue if it is too broad. Verifying by
# inspection rather than by attempting a delete -- a probe test against the
# real bucket is how the bucket got deleted in the first place.
STORED=$(mc admin policy info s notesnook-attachments)
case "$STORED" in
  *'"s3:*"'*|*s3:DeleteBucket*|*s3:PutBucketPolicy*)
    echo "REFUSING: stored policy is too broad:" >&2; echo "$STORED" >&2; exit 1 ;;
esac
echo "    policy verified: enumerated object actions only"

echo "==> creating the user"
AK="nnapp$(openssl rand -hex 5)"
SK=$(openssl rand -hex 20)
mc admin user add s "$AK" "$SK" >/dev/null
mc admin policy attach s notesnook-attachments --user "$AK" >/dev/null
mc admin user info s "$AK" | grep -q AccessKey || { echo "user not retrievable" >&2; exit 1; }

echo "==> smoke test: put / read / delete one object"
PROBE=$(mktemp); echo probe > "$PROBE"
docker run --rm --network "$NET" -v "$PROBE:/probe.txt:ro" \
  -e MC_HOST_a="http://$AK:$SK@notesnook-s3:9000" "$MC_IMG" cp /probe.txt "a/$BUCKET/.probe" >/dev/null
docker run --rm --network "$NET" -e MC_HOST_a="http://$AK:$SK@notesnook-s3:9000" "$MC_IMG" cat "a/$BUCKET/.probe" >/dev/null
docker run --rm --network "$NET" -e MC_HOST_a="http://$AK:$SK@notesnook-s3:9000" "$MC_IMG" rm "a/$BUCKET/.probe" >/dev/null
rm -f "$PROBE"
echo "    put/read/delete OK"

cat <<OUT

Add these to .env, then: docker compose up -d notesnook-server

S3_ACCESS_KEY_ID=$AK
S3_ACCESS_KEY=$SK
OUT
