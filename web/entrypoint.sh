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

# These are top-level, NOT nested inside the SSE block above. The indentation
# used to imply otherwise, and the next person to read it would "fix" the
# apparent nesting -- which would put `exec nginx` inside a conditional, so any
# operator leaving SSE_SERVER_PUBLIC_URL blank would get a container that
# exits immediately instead of serving. The if/fi pairs are balanced: 7/10,
# 11/14, 15/18, 19/22, 29/32.
if [ -n "${MONOGRAPH_PUBLIC_URL:-}" ]; then
  grep -rl 'https://notes.example.com' "$HTML" 2>/dev/null \
    | xargs -r sed -i "s|https://notes.example.com|${MONOGRAPH_PUBLIC_URL}|g"
fi
# The web client's OWN origin, used for the OpenGraph tags in index.html
# (og:url, og:image). Nothing upstream bakes this -- the Dockerfile declares
# no NN_APP arg -- so without this rule the served page advertises
# https://app.example.com as its canonical URL, which the operator does not
# own. NOTESNOOK_APP_HOST is that origin; see .env.example, where
# NOTESNOOK_APP_PUBLIC_URL is the SYNC url and is NOT interchangeable.
if [ -n "${NOTESNOOK_APP_HOST:-}" ]; then
  grep -rl 'https://app.example.com' "$HTML" 2>/dev/null \
    | xargs -r sed -i "s|https://app.example.com|${NOTESNOOK_APP_HOST}|g"
fi
exec nginx -g 'daemon off;'
