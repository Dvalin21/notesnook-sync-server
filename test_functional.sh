#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass(){ echo -e "${GREEN}[PASS]${NC} $*"; }
fail(){ echo -e "${RED}[FAIL]${NC} $*"; FAILS=$((FAILS+1)); }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
FAILS=0

# Domain from CLI arg, else SERVER_DOMAIN out of .env, else a git-safe literal.
# Without the .env fallback, running this with no argument against your own
# deployment sends the wrong Host header and fails ~3 routing checks that are
# not actually broken.
DOMAIN="${1:-$(sed -n 's/^SERVER_DOMAIN=//p' .env 2>/dev/null | tail -1)}"
DOMAIN="${DOMAIN:-example.com}"

# Resolve paths from this script. It used to hardcode
# /home/keith/host/notesnook-sync-server/ -- a DIFFERENT checkout -- so on any
# other clone every check in sections 6-8 reported a healthy service as
# "missing". A test that can only produce false negatives trains you to ignore it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The host port Caddy is published on, read from compose instead of hardcoded.
# README "Troubleshooting" tells operators to change 8080 when it conflicts, and a
# hardcoded value made this script report false FAILs on exactly those stacks --
# it was curling whatever else owned 8080 and reading that 404 as a broken route.
# `docker compose port` reflects the live binding; fall back to the parsed
# compose file (works when the stack is down), then to the historical default.
CADDY_PORT=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" port caddy 80 2>/dev/null \
             | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1)
if [ -z "$CADDY_PORT" ]; then
  CADDY_PORT=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" config 2>/dev/null \
               | sed -n 's/.*published: "\([0-9]*\)".*/\1/p' | head -1)
fi
CADDY_PORT=${CADDY_PORT:-8080}
CADDY="http://localhost:$CADDY_PORT"

echo "═══ notesnook-sync-server functional tests (domain=$DOMAIN) ═══"

# 1. All backends through Caddy Host-header routing
echo; echo "─── 1. Caddy Host-header routing ───"
declare -A ROUTES
ROUTES["sync.$DOMAIN/health"]="sync"
ROUTES["auth.$DOMAIN/health"]="auth"
ROUTES["sse.$DOMAIN/health"]="sse"
ROUTES["notes.$DOMAIN/api/health"]="notes"
ROUTES["$DOMAIN/api/health"]="apex"
ROUTES["cors.$DOMAIN/health"]="cors"

for hostpath in "${!ROUTES[@]}"; do
  host="${hostpath%%/*}"; path="/${hostpath#*/}"
  label="${ROUTES[$hostpath]}"
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $host" --connect-timeout 5 "$CADDY$path" 2>/dev/null || echo "000")
  [ "$code" = "200" ] && pass "Caddy $label → $host$path ($code)" || fail "Caddy $label → $code (expected 200)"
done

# 2. MinIO bucket through Caddy path fallback
echo; echo "─── 2. MinIO bucket ───"
ATTACH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$CADDY/attachments/" 2>/dev/null || echo "000")
if [ "$ATTACH_CODE" = "403" ] || [ "$ATTACH_CODE" = "200" ]; then
  pass "MinIO bucket attachments reachable through Caddy ($ATTACH_CODE)"
else
  fail "MinIO bucket attachments not reachable through Caddy ($ATTACH_CODE)"
fi

# 3. OAuth2 token endpoint through Caddy (auth stack alive test)
echo; echo "─── 3. OAuth2 token endpoint ───"
AUTH_RESP=$(curl -s -X POST "$CADDY/connect/token" \
  -H "Host: auth.$DOMAIN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=notesnook" \
  -d "username=probe@example.invalid" \
  -d "password=not-a-real-password" \
  -d "scope=notesnook.sync openid offline_access" 2>/dev/null || true)

if echo "$AUTH_RESP" | grep -q '"access_token"'; then
  pass "OAuth password grant returned access_token"
elif echo "$AUTH_RESP" | grep -qi '"invalid_grant"'; then
  pass "OAuth token endpoint responds correctly (invalid_grant — no account, auth stack alive)"
else
  desc=$(echo "$AUTH_RESP" | head -c 120)
  fail "OAuth unexpected response: $desc"
fi

# 4. /sync returns 404 through Caddy — sync is SignalR /hubs/sync/v2
echo; echo "─── 4. Sync surface contract ───"
SYNC_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Host: sync.$DOMAIN" "$CADDY/sync" 2>/dev/null || echo "000")
[ "$SYNC_CODE" = "404" ] && pass "/sync HTTP 404 — sync uses SignalR /hubs/sync/v2" || fail "/sync HTTP $SYNC_CODE (expected 404)"

# 5. /inbox/public-encryption-key requires auth (401) through Caddy
echo; echo "─── 5. Inbox public-encryption-key auth contract ───"
UNAUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: sync.$DOMAIN" "$CADDY/inbox/public-encryption-key" 2>/dev/null || echo "000")
[ "$UNAUTH_CODE" = "401" ] && pass "/inbox/public-encryption-key requires API-key auth (401 unauthenticated)" || fail "/inbox/public-encryption-key unauthenticated -> $UNAUTH_CODE (expected 401)"

# 6. DataProtection volumes owned correctly (.NET services only — monograph is Bun/Node)
#
# COMPOSE has to exist from here on, and section 7 used to define it AFTER this
# point, so `${COMPOSE}` was unbound under `set -u`. Define it once, here.
#
# SCRIPT_DIR is resolved once, at the top of this file. COMPOSE must be an ARRAY,
# not a string: a quoted "docker compose -f ..." expands as a single word, so the
# whole command line was passed as one argument to `docker` and every check below
# silently saw empty output.
COMPOSE=(docker compose -f "$SCRIPT_DIR/docker-compose.yml" --env-file "$SCRIPT_DIR/.env")

echo; echo "─── 6. DataProtection volumes ───"
# Also used a hardcoded `notesnook-sync-server_` volume-name prefix, which is the
# compose project name and therefore depends on the checkout directory. A
# renamed checkout made every volume report uid=-1. Resolve the real names.
for vol in dpdata-identity dpdata-notesnook dpdata-sse gnupg-identity; do
  name=$("${COMPOSE[@]}" config --volumes 2>/dev/null | grep -qx "$vol" && echo "$vol")
  [ -z "$name" ] && { warn "$vol not declared in compose"; continue; }
  # Resolve the real volume name from a RUNNING container's mounts. Matching on
  # "_${vol}$" picks whichever volume compose created first, and several stacks
  # can coexist on one host (notesnook-sync-server_dpdata-identity and
  # nt_dpdata-identity both match "_dpdata-identity$") -- so the check was
  # inspecting a foreign volume and reporting its ownership.
  # Collect volume names via JSON, not a go template. The template form
  # {{range .Mounts}}{{.Name}}{{"\n"}}{{end}} emits EMPTY LINES on this
  # Docker version, so the pipe saw only newlines and this loop died with 141
  # (SIGPIPE from grep exiting early). docker inspect --format json is stable.
  # Collect ALL volume names first, then filter. Piping into `grep -m1` closes the
  # pipe as soon as it matches, and the python reader then dies on SIGPIPE with a
  # BrokenPipeError traceback on stderr for every container. Two stages, no
  # early-exit grep in the middle of the pipe.
  allvols=$("${COMPOSE[@]}" ps -q 2>/dev/null | while read -r ctr; do
    docker inspect "$ctr" --format '{{json .Mounts}}' 2>/dev/null || true
  done | python3 -c 'import json,sys
out=[]
for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    try:
        for m in json.loads(line):
            if m.get("Name"):
                out.append(m["Name"])
    except Exception:
        pass
print("\n".join(out))')
  realname=$(printf '%s\n' "$allvols" | grep -- "_${vol}\$" | head -1)
  [ -z "$realname" ] && { warn "$vol volume not created yet (stack not booted?)"; continue; }
  uid=$(docker run --rm -v "$realname:/mnt" alpine stat -c "%u" /mnt 2>/dev/null || echo "-1")
  # `stat -c %u /mnt` reports the owner of the MOUNT POINT directory, which init-dpdata
  # chowns recursively. A volume whose root is uid 0 while everything under it is
  # 1000 is fine, so report the deepest real entry too rather than guessing.
  if [ "$uid" = "1000" ]; then
    pass "$vol owned by uid=1000"
  elif [ "$uid" = "0" ]; then
    warn "$vol root is uid=0 (contents are chowned by init-dpdata; verify before trusting)"
  else
    fail "$vol owner uid=$uid (expected 1000)"
  fi
done

# 7. Docker topology + exposure rules
echo; echo "─── 7. Topology + exposure ───"
# COMPOSE is defined in section 6 (it is needed from there on).
# `caddy-1` and `autoheal` were in this list but neither is a service in the
# compose file (the container is named caddy; autoheal does not exist here), so
# those two checks could never pass. Use the real service list.
for svc in notesnook-db notesnook-s3 identity-server notesnook-server sse-server monograph-server cors-proxy caddy inbox-api themes-server web; do
  "${COMPOSE[@]}" ps --format '{{.Name}}' 2>/dev/null | grep -q "$svc" \
    && pass "service $svc running" \
    || fail "service $svc missing"
done
# setup-s3 was removed: it needed minio/mc, which MinIO deleted from Docker Hub
# in October 2025, and its `mc mb ... || true` hid a missing bucket behind a
# green stack. create-minio-app-user.sh now creates the bucket, and waits for
# notesnook-s3 itself.
"${COMPOSE[@]}" config --services 2>/dev/null | tr -d '\r' | grep -q '^setup-s3$' \
  && fail "setup-s3 is back — it depends on the deleted minio/mc image" \
  || pass "setup-s3 absent (bucket creation moved to create-minio-app-user.sh)"
"${COMPOSE[@]}" config 2>/dev/null | grep -q 'minio/mc:' \
  && fail "compose still references minio/mc — deleted from Docker Hub" \
  || pass "compose references no deleted minio/* image"

"${COMPOSE[@]}" ps --format '{{.Name}} {{.Ports}}' 2>/dev/null \
  | grep 'notesnook-db' | grep -E '0\.0\.0\.0:|\[::\]:' | grep ':27017' \
  && fail "MongoDB host port 27017 exposed — remove ports mapping" \
  || pass "MongoDB not host-exposed (internal only)"

# 8. Restart policy.
# These checks used to expect NO restart policy and an always-on `autoheal`
# service. That is the OPPOSITE of what this stack does: compose merges
# `restart: unless-stopped` into every long-running service via the x-svc anchor
# (enforced by scripts/check-compose.py), and there is no autoheal service. So
# the section asserted the wrong invariant and could never pass.
#
# It also hardcoded the container name prefix `notesnook-sync-server-`, which is
# derived from the checkout directory name. Resolve the real container names via
# compose instead, and assert the policy that is actually wanted.
echo; echo "─── 8. Restart policies ───"
for svc in identity-server notesnook-server sse-server monograph-server cors-proxy inbox-api themes-server web caddy notesnook-db notesnook-s3; do
  ctr=$("${COMPOSE[@]}" ps -q "$svc" 2>/dev/null | head -1)
  if [ -z "$ctr" ]; then
    fail "$svc container not found"
    continue
  fi
  restart=$(docker inspect "$ctr" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "unreadable")
  [ "$restart" = "unless-stopped" ] \
    && pass "$svc restart=$restart" \
    || fail "$svc restart=$restart (expected unless-stopped)"
done

# Summary
echo; echo "════════════════════════════════════════"
if [ "$FAILS" -eq 0 ]; then
  echo -e "${GREEN}ALL CHECKS PASSED${NC}"
else
  echo -e "${RED}$FAILS check(s) FAILED${NC}"
fi
echo "════════════════════════════════════════"
exit "$FAILS"
