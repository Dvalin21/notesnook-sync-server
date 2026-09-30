# MinIO (Notesnook edition), compiled from a pinned upstream tag plus patches.
#
# WHY THIS EXISTS
# docker-compose.yml runs `dvalin21/minio-notesnook:latest` and this directory
# is the recipe for it. The image was previously built on one machine from a
# local checkout and pushed; nothing in this repository referenced that
# checkout, so the image was NOT reproducible from the repo. Someone cloning
# this project could run the stack but could not rebuild the storage layer.
# This file closes that gap, and follows the same convention as ./mc,
# ./monograph and ./web: pin an external source, build, no vendored source.
#
# WHY PATCHES AT ALL
# MinIO was archived in April 2026 with no further security patches, and the
# open-source line has no patched release for CVE-2026-40344 / CVE-2026-41145
# (the advisories name a load-balancer block as the mitigation, which is what
# Caddyfile does). The base tag below predates four upstream security fixes,
# so they are carried as portable files in ./patches and applied at build time.
#
#   01-25179bcfe-21642  IAM sub-policy validation bypass -> a service account
#                       can exceed the policy it was given. THIS ONE MATTERS:
#                       the stack creates a bucket-scoped MinIO account and
#                       relies on that policy being enforced.
#   02-44951eba3-21612  S3 POST policy trailing-slash bypass
#   03-8f5489205e-21582 LDAP TLS handshake with StartTLS (LDAP unused here)
#   04-0654eb5533-21615 data-scanner timeN closure leak (scanner unused here)
#
# THE PIN IS LOAD-BEARING. Do not move MINIO_BASE_TAG without re-reading.
#   RELEASE.2025-09-07T16-13-09Z peels to 07c3a429bfed433e49018cb0f78a52145d4bedeb
#   Upstream minio/minio is archived and read-only, so this tag is permanent.
#
# NOTHING IS VENDORED. The build clones upstream and applies ./patches. Verified
# to reproduce the previously published binary: base + 4 patches yields a .go
# tree byte-identical to the old fork branch (0 differing files).
#
#   Verifying a build matches what is published:
#     docker run --rm dvalin21/minio-notesnook:latest minio --version
#   Expect the commit named to be the UPSTREAM base commit, not DEVELOPMENT.GOGET.
#   A source build reports `DEVELOPMENT.GOGET` only if the stamp is missing.
#
# The stamp comes from MinIO's own buildscripts/gen-ldflags.go, so the -X
# targets cannot drift from what cmd/build-constants.go actually reads. It is
# generated BEFORE `git am` on purpose: that generator derives commit-id from
# `git log -n1`, and running it after the patches would stamp a local commit
# that exists nowhere else and cannot be fetched. MINIO_RELEASE=notesnook tags
# the output as a local build rather than a MinIO release. The trailing
# `grep -q "${BASE_COMMIT}"` fails the build if that sha is not embedded, so a
# stripped -ldflags cannot silently ship again.
#
# Separately: CVE-2026-40344 / CVE-2026-41145 are NOT fixed by the patches.
# MinIO was archived and the open-source line has no patched release; both
# advisories name a load-balancer block as the mitigation, which is what
# Caddyfile does at the @attach route. Do not read the four patches above as
# covering those.

ARG GO_VERSION=1.24

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETARCH
ARG MINIO_REPO=https://github.com/minio/minio.git
ARG MINIO_BASE_TAG=RELEASE.2025-09-07T16-13-09Z
COPY patches /patches
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --quiet --depth 1 --branch "${MINIO_BASE_TAG}" "${MINIO_REPO}" . \
 && BASE_COMMIT="$(git rev-parse HEAD)" \
 && LDFLAGS="$(MINIO_RELEASE=notesnook go run buildscripts/gen-ldflags.go)" \
 && git -c user.name=minio-notesnook -c user.email=minio-notesnook@invalid \
      am /patches/*.patch \
 && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
      go build -buildvcs=false -trimpath -ldflags "$LDFLAGS" -o /out/minio . \
 && test -x /out/minio \
 && grep -q "${BASE_COMMIT}" /out/minio

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=build /out/minio /usr/local/bin/minio
RUN chmod +x /usr/local/bin/minio
# Matches the fork's own Dockerfile and docker-compose.yml's
# `command: server /data --console-address :9090`. Compose supplies the command,
# so this is only the default.
ENTRYPOINT ["minio"]
CMD ["server", "/data", "--console-address", ":9090"]
