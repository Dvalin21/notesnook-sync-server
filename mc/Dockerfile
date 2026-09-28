# MinIO Client (mc), compiled from source.
#
# Why not the upstream image: MinIO deleted minio/mc from Docker Hub in October
# 2025 (hub.docker.com/v2/repositories/minio/mc/ returns "object not found") and
# dl.min.io returns HTTP 410 for the release binaries. Upstream's own README
# states the project is no longer maintained, so there is no image left to pull
# and no release coming.
#
# The commit is pinned to the one behind minio/mc:RELEASE.2025-08-13T08-35-41Z,
# which is the version this project depends on. That pin is load-bearing: in
# this revision `mb` defines -p as an alias for --ignore-existing, which
# create-minio-app-user.sh relies on. In current mc master, -p was repurposed to
# mean "create a path", so the same command silently creates nothing.
#
# Do not "upgrade" MC_COMMIT without re-reading that script.

ARG GO_VERSION=1.24

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build
ARG TARGETARCH
ARG MC_COMMIT=7394ce0dd2a80935aded936b09fa12cbb3cb8096
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --quiet https://github.com/minio/mc.git . \
 && git checkout --quiet "${MC_COMMIT}" \
 && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
      go build -buildvcs=false -trimpath -ldflags "-s -w" -o /out/mc . \
 && test -x /out/mc

FROM alpine:3.21
COPY --from=build /out/mc /usr/local/bin/mc
RUN apk add --no-cache ca-certificates
ENTRYPOINT ["/usr/local/bin/mc"]
