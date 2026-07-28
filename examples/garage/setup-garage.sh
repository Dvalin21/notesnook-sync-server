#!/bin/bash
set -euo pipefail

# Setup a new Garage S3 instance with a bucket for Notesnook attachments.
# Run once after the garage container starts.
#
# Garage supports standard S3 API. Bucket creation uses AWS SigV4 signing.
# This script uses curl with a minimal SigV4 implementation.
#
# Required env vars:
#   GARAGE_ACCESS_KEY_ID     - S3 access key (set in .env)
#   GARAGE_ACCESS_KEY_SECRET - S3 secret key (set in .env)
#
# Optional env vars:
#   GARAGE_HOST             - default: localhost
#   GARAGE_S3_PORT          - default: 3900
#   BUCKET_NAME             - default: attachments

GARAGE_HOST="${GARAGE_HOST:-localhost}"
GARAGE_S3_PORT="${GARAGE_S3_PORT:-3900}"
BUCKET_NAME="${BUCKET_NAME:-attachments}"
ACCESS_KEY="${GARAGE_ACCESS_KEY_ID:-}"
SECRET_KEY="${GARAGE_ACCESS_KEY_SECRET:-}"

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo "ERROR: GARAGE_ACCESS_KEY_ID and GARAGE_ACCESS_KEY_SECRET must be set."
  echo "Set them in .env before running this script."
  exit 1
fi

echo "===> Setting up Garage S3 for Notesnook"
echo "    Host: ${GARAGE_HOST}:${GARAGE_S3_PORT}"
echo "    Bucket: ${BUCKET_NAME}"

# Wait for Garage S3 API to be ready
echo "===> Waiting for Garage to be ready..."
until curl -fsS "http://${GARAGE_HOST}:${GARAGE_S3_PORT}/health" >/dev/null 2>&1; do
  sleep 2
done
echo "    Garage is ready."

# Create the bucket using S3 API with AWS SigV4
# Garage accepts standard S3 PUT bucket requests
echo "===> Creating bucket '${BUCKET_NAME}'..."

# Build AWS SigV4 signature for S3 PUT bucket
AWS_REGION="us-east-1"
AWS_SERVICE="s3"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
DATE_PREFIX=$(date -u +"%Y%m%d")

CANONICAL_URI="/${BUCKET_NAME}"
CANONICAL_QUERY=""
CANONICAL_HEADERS="host:${GARAGE_HOST}:${GARAGE_S3_PORT}\n"
SIGNED_HEADERS="host"
CANONICAL_REQUEST="PUT\n${CANONICAL_URI}\n${CANONICAL_QUERY}\n${CANONICAL_HEADERS}\n${SIGNED_HEADERS}\nUNSIGNED-PAYLOAD"

CREDENTIAL_SCOPE="${DATE_PREFIX}/${AWS_REGION}/${AWS_SERVICE}/aws4_request"
STRING_TO_SIGN="AWS4-HMAC-SHA256\n${TIMESTAMP}\n${CREDENTIAL_SCOPE}\n$(printf "${CANONICAL_REQUEST}" | openssl dgst -sha256 -binary | xxd -p -c 256)"

# Derive signing key
SIGNING_KEY=$(printf "${DATE_PREFIX}" | openssl dgst -sha256 -hmac "${SECRET_KEY}" -binary | xxd -p -c 256)
SIGNING_KEY=$(printf "${SIGNING_KEY}" | xxd -r -p | openssl dgst -sha256 -hmac "aws4${AWS_REGION}" -binary | xxd -p -c 256)
SIGNING_KEY=$(printf "${SIGNING_KEY}" | xxd -r -p | openssl dgst -sha256 -hmac "${AWS_SERVICE}" -binary | xxd -p -c 256)
SIGNING_KEY=$(printf "${SIGNING_KEY}" | xxd -r -p | openssl dgst -sha256 -hmac "aws4_request" -binary | xxd -p -c 256)

SIGNATURE=$(printf "${STRING_TO_SIGN}" | openssl dgst -sha256 -hmac "$(printf "${SIGNING_KEY}" | xxd -r -p)" -binary | xxd -p -c 256)

AUTH_HEADER="AWS4-HMAC-SHA256 Credential=${ACCESS_KEY}/${CREDENTIAL_SCOPE}, SignedHeaders=${SIGNED_HEADERS}, Signature=${SIGNATURE}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT "http://${GARAGE_HOST}:${GARAGE_S3_PORT}/${BUCKET_NAME}" \
  -H "Host: ${GARAGE_HOST}:${GARAGE_S3_PORT}" \
  -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
  -H "x-amz-date: ${TIMESTAMP}" \
  -H "Authorization: ${AUTH_HEADER}")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "409" ]; then
  echo "    Bucket '${BUCKET_NAME}' ready (HTTP ${HTTP_CODE})."
else
  echo "    WARNING: Bucket creation returned HTTP ${HTTP_CODE}."
  echo "    The bucket may already exist or there may be a configuration issue."
fi

echo ""
echo "===> Garage setup complete."
echo "    Bucket: ${BUCKET_NAME}"
echo "    S3 endpoint: http://${GARAGE_HOST}:${GARAGE_S3_PORT}"
echo ""
echo "Configure your .env with:"
echo "    ATTACHMENTS_SERVER_PUBLIC_URL=http://<your-domain>:<port>"
echo "    GARAGE_ACCESS_KEY_ID=${ACCESS_KEY}"
echo "    GARAGE_ACCESS_KEY_SECRET=<your-secret>"
