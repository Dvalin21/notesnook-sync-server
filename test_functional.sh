#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass(){ echo -e "${GREEN}[PASS]${NC} $*"; }
fail(){ echo -e "${RED}[FAIL]${NC} $*"; FAILS=$((FAILS+1)); }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
FAILS=0

# Domain from CLI arg (default example.com for git-safe commit)
DOMAIN="${1:-example.com}"
CADDY="http://localhost:8080"

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
  -d "username=keith@example.com" \
  -d "password=changeme" \
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
echo; echo "─── 6. DataProtection volumes ───"
for vol in dpdata-identity dpdata-notesnook dpdata-sse; do
  uid=$(docker run --rm -v "notesnook-sync-server_$vol:/mnt" alpine stat -c "%u" /mnt 2>/dev/null || echo "-1")
  [ "$uid" = "1000" ] && pass "$vol owned by uid=1000" || warn "$vol owner uid=$uid (expected 1000, may need chown)"
done

# 7. Docker topology + exposure rules
echo; echo "─── 7. Topology + exposure ───"
COMPOSE="docker compose -f /home/keith/host/notesnook-sync-server/docker-compose.yml --env-file /home/keith/host/notesnook-sync-server/.env"
for svc in notesnook-db notesnook-s3 identity-server notesnook-server sse-server monograph-server cors-proxy caddy-1 autoheal inbox-api themes-server; do
  $COMPOSE ps --format '{{.Name}}' 2>/dev/null | grep -q "$svc" \
    && pass "service $svc running" \
    || fail "service $svc missing"
done
$COMPOSE config --services 2>/dev/null | tr -d '\r' | grep -q '^setup-s3$' \
  && pass "service setup-s3 present in compose" \
  || fail "service setup-s3 missing from compose config"

$COMPOSE ps --format '{{.Name}} {{.Ports}}' 2>/dev/null \
  | grep 'notesnook-db' | grep -E '0\.0\.0\.0:|\[::\]:' | grep ':27017' \
  && fail "MongoDB host port 27017 exposed — remove ports mapping" \
  || pass "MongoDB not host-exposed (internal only)"

# 8. Restart policy: app services have none (autoheal handles restarts)
echo; echo "─── 8. Restart policies ───"
for svc in identity-server notesnook-server sse-server monograph-server cors-proxy caddy; do
  restart=$(docker inspect "notesnook-sync-server-$svc-1" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "missing")
  [ "$restart" = "no" ] || [ -z "$restart" ] \
    && pass "$svc restart=$restart (none)" \
    || fail "$svc restart=$restart (should be no/empty)"
done
restart=$(docker inspect notesnook-sync-server-autoheal-1 --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo missing)
[ "$restart" = "always" ] && pass "autoheal restart=always" || fail "autoheal restart=$restart (expected always)"

# Summary
echo; echo "════════════════════════════════════════"
if [ "$FAILS" -eq 0 ]; then
  echo -e "${GREEN}ALL CHECKS PASSED${NC}"
else
  echo -e "${RED}$FAILS check(s) FAILED${NC}"
fi
echo "════════════════════════════════════════"
exit "$FAILS"
