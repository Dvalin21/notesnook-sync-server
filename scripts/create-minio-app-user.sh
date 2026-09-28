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
# Requires: the stack's .env (for MINIO_ROOT_USER / MINIO_ROOT_PASSWORD) and
#           a running notesnook-s3.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "no .env -- run: cp .env.example .env" >&2; exit 1; }
set -a; . ./.env; set +a
: "${MINIO_ROOT_USER:?not in .env}" "${MINIO_ROOT_PASSWORD:?not in .env}"

NET=$(docker inspect notesnook-sync-server-notesnook-s3-1 \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null || true)
[ -n "$NET" ] || { echo "notesnook-s3 is not running" >&2; exit 1; }
MC_IMG=${MC_IMG:-minio/mc:RELEASE.2025-08-13T08-35-41Z}
BUCKET=${S3_BUCKET_NAME:-attachments}
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
# `mc mb --ignore-existing` in mc RELEASE.2025-08-13 prints a spurious
# "Bucket name cannot be empty" to stderr AND exits non-zero even when it
# creates the bucket, which trips `set -e`. Same `|| true` shape setup-s3 uses.
mc mb -p s "$BUCKET" >/dev/null 2>&1 || true
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
