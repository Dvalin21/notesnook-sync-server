#!/usr/bin/env bash
# ponytail: health‑only smoke test (add per‑API assertions when routes stabilise)
set -euo pipefail

usage() {
  echo "Usage: $0 [--build] [--install] [--skip-cleanup] [--wait N]"
  exit 1
}

BUILD=0
INSTALL=0
SKIP_CLEANUP=0
WAIT=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1 ;;
    --install) INSTALL=1 ;;
    --skip-cleanup) SKIP_CLEANUP=1 ;;
    --wait) WAIT="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

cleanup() {
  [[ $SKIP_CLEANUP -eq 1 ]] && return
  echo "── Teardown ───────────────────────────────────────────────"
  docker compose down --remove-orphans --volumes 2>/dev/null || true
}
trap cleanup EXIT

echo "══ smoke‑test (port‑direct architecture) ════════════════════"

if [[ $BUILD -eq 1 ]]; then
  echo "── Build ──────────────────────────────────────────────────"
  docker compose build --pull cors-proxy
fi

if [[ $INSTALL -eq 1 ]]; then
  echo "── Start ──────────────────────────────────────────────────"
  docker compose up -d --wait --wait-timeout "$WAIT"
fi

echo "── Health ───────────────────────────────────────────────────"

pass=0
fail=0

# Map service → host URL (no Caddy in this branch)
declare -A SERVICES
SERVICES[identity]="http://localhost:8264/healthz"
SERVICES[notesnook]="http://localhost:5264"
SERVICES[sse]="http://localhost:7264"
SERVICES[monograph]="http://localhost:6264"
SERVICES[cors-proxy]="http://localhost:3000/health"

for svc in "${!SERVICES[@]}"; do
  url="${SERVICES[$svc]}"
  if curl -sf -o /dev/null "$url" 2>/dev/null; then
    echo "  ✓ $svc  →  $url"
    ((pass++))
  else
    echo "  ✗ $svc  →  $url"
    ((fail++))
  fi
done

echo "─────────────────────────────────────────────────────────────"
echo "  pass=$pass  fail=$fail"

if [[ $fail -gt 0 ]]; then
  echo "── tail logs (errors) ─────────────────────────────────────"
  docker compose logs --tail=30 2>/dev/null || true
fi

[[ $fail -eq 0 ]] && echo "OK (smoke)"  || echo "FAIL (smoke)"
exit $fail
