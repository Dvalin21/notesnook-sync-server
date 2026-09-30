# MinIO (Notesnook edition), compiled from a pinned source tree.
#
# WHY THIS EXISTS
# docker-compose.yml runs `dvalin21/minio-notesnook:latest` and this directory
# is the recipe for it. The image was previously built on one machine from a
# local checkout and pushed; nothing in this repository referenced that
# checkout, so the image was NOT reproducible from the repo. Someone cloning
# this project could run the stack but could not rebuild the storage layer.
# This file closes that gap, and follows the same convention as ./mc,
# ./monograph and ./web: clone a pinned external commit, build, no vendored
# source.
#
# WHY A FORK AT ALL
# MinIO was archived in April 2026 with no further security patches, and the
# open-source line has no patched release for CVE-2026-40344 / CVE-2026-41145
# (the advisories name a load-balancer block as the mitigation, which is what
# Caddyfile does). The fork exists to carry the few upstream fixes that
# arrived after the fork point and that this stack actually depends on.
#
# THE PIN IS LOAD-BEARING. Do not move MINIO_COMMIT without re-reading.
#   3b2d20324 is the tip of Dvalin21/minio branch `minio-notesnook`
#   (describe: RELEASE.2026-09-02T00-00-00Z). Four upstream security fixes are
#   applied on top of that tag and carried as portable files in patches/:
#     01-25179bcfe-21642  IAM sub-policy validation bypass -> a service account
#                         can exceed the policy it was given. THIS ONE MATTERS:
#                         the stack creates a bucket-scoped MinIO account and
#                         relies on that policy being enforced.
#     02-44951eba3-21612  S3 POST policy trailing-slash bypass
#     03-8f5489205e-21582 LDAP TLS handshake with StartTLS (LDAP unused here)
#     04-0654eb5533-21615 data-scanner timeN closure leak (scanner unused here)
#   The published dvalin21/minio-notesnook:latest was built from the parent of
#   3b2d20324 (fa64b2cda). Those two commits add only patches/*.patch and
#   HANDOFF.md -- no Go source -- so the resulting binary is identical. Pinning
#   the newer tip keeps the recipe aligned with the maintained branch at no
#   behavioural cost. Verified: `git diff --stat fa64b2cda 3b2d20324` touches
#   no .go file.
#
# Verifying a build matches what is published:
#   docker run --rm dvalin21/minio-notesnook:latest minio --version
# A source build reports `DEVELOPMENT.GOGET` rather than a RELEASE tag. That is
# expected, and is how you tell a tree build from a stock release image.
#
# Separately: CVE-2026-40344 / CVE-2026-41145 are NOT fixed in this fork. MinIO
# was archived and the open-source line has no patched release; both advisories
# name a load-balancer block as the mitigation, which is what Caddyfile does at
# the @attach route. Do not read the four patches above as covering those.

ARG GO_VERSION=1.24

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETARCH
ARG MINIO_REPO=https://github.com/Dvalin21/minio.git
ARG MINIO_COMMIT=3b2d2032457ef75ae29cdb171d9e1d5004082c75
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --quiet "${MINIO_REPO}" . \
 && git checkout --quiet "${MINIO_COMMIT}" \
 && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
      go build -buildvcs=false -trimpath -ldflags "-s -w" -o /out/minio . \
 && test -x /out/minio

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=build /out/minio /usr/local/bin/minio
RUN chmod +x /usr/local/bin/minio
# Matches the fork's own Dockerfile and docker-compose.yml's
# `command: server /data --console-address :9090`. Compose supplies the command,
# so this is only the default.
ENTRYPOINT ["minio"]
CMD ["server", "/data", "--console-address", ":9090"]
