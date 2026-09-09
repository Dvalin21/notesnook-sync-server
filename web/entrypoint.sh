#!/bin/sh
# Self-host: the bundle bakes example.com hosts (no real domain ships in the
# image). Swap them for the operator's public URLs at boot, then serve.
# ponytail: one sed over hashed assets; reruns are no-ops once replaced.
set -eu
HTML=/usr/share/nginx/html
if [ -n "${NOTESNOOK_APP_PUBLIC_URL:-}" ]; then
  grep -rl 'https://sync.example.com' "$HTML" 2>/dev/null \
    | xargs -r sed -i "s|https://sync.example.com|${NOTESNOOK_APP_PUBLIC_URL}|g"
fi
if [ -n "${AUTH_SERVER_PUBLIC_URL:-}" ]; then
  grep -rl 'https://auth.example.com' "$HTML" 2>/dev/null \
    | xargs -r sed -i "s|https://auth.example.com|${AUTH_SERVER_PUBLIC_URL}|g"
fi
if [ -n "${SSE_SERVER_PUBLIC_URL:-}" ]; then
  grep -rl 'https://sse.example.com' "$HTML" 2>/dev/null \
    | xargs -r sed -i "s|https://sse.example.com|${SSE_SERVER_PUBLIC_URL}|g"
fi
if [ -n "${MONOGRAPH_PUBLIC_URL:-}" ]; then
  grep -rl 'https://notes.example.com' "$HTML" 2>/dev/null \
    | xargs -r sed -i "s|https://notes.example.com|${MONOGRAPH_PUBLIC_URL}|g"
fi
exec nginx -g 'daemon off;'
