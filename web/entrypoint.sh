#!/bin/sh
# Self-host: this image ships UPSTREAM Notesnook hosts only (api.notesnook.com,
# auth.streetwriters.co, ...). Nothing operator-specific is compiled in at build
# time, so the published image carries no real domain and no .env edit requires
# a rebuild.
#
# At boot we rewrite each upstream default to the operator's public URL from the
# environment. That covers BOTH default sets the app can fall back to:
#   - packages/core/src/utils/constants.ts  (the `hosts` object)
#   - apps/web/src/common/db.ts             (getHostUrl fallbacks)
# plus the og:url / canonical origin in index.html, which nothing upstream bakes.
#
# ponytail: one sed per host over hashed assets; reruns are no-ops once replaced,
# and a var left blank leaves that upstream default untouched rather than blanking it.

set -eu
HTML=/usr/share/nginx/html

replace() {
  # replace <from> <to>  -- rewrite <to> in every asset that contains <from>
  from="$1"
  to="${2:-}"
  [ -n "$to" ] || return 0
  grep -rl "$from" "$HTML" 2>/dev/null | xargs -r sed -i "s|$from|$to|g"
}

# Sync / API. db.ts and constants.ts both default to api.notesnook.com.
replace "https://api.notesnook.com" "${NOTESNOOK_APP_PUBLIC_URL:-}"

# Auth (OIDC / identity).
replace "https://auth.streetwriters.co" "${AUTH_SERVER_PUBLIC_URL:-}"
replace "https://auth.notesnook.com"    "${AUTH_SERVER_PUBLIC_URL:-}"

# Server-sent events.
replace "https://events.streetwriters.co" "${SSE_SERVER_PUBLIC_URL:-}"

# Monograph (public note publishing).
replace "https://monogr.ph"          "${MONOGRAPH_PUBLIC_URL:-}"
replace "https://monograph.notesnook.com" "${MONOGRAPH_PUBLIC_URL:-}"

# Themes API. This is a distinct host from api.notesnook.com and it is served
# by the themes-server service in this stack, so point it at that.
replace "https://themes-api.notesnook.com" "${THEMES_SERVER_PUBLIC_URL:-}"

# Subscription + issue reporting. These have no dedicated env var; a self-hoster
# has no equivalent, so point them at the app origin rather than leaving live
# Streetwriters endpoints in a self-hosted bundle. Only rewritten when the app
# origin is known.
if [ -n "${NOTESNOOK_APP_HOST:-}" ]; then
  replace "https://subscriptions.streetwriters.co" "${NOTESNOOK_APP_HOST}"
  replace "https://issues.streetwriters.co"         "${NOTESNOOK_APP_HOST}"
  # The web client's OWN origin, used for OpenGraph tags (og:url, og:image).
  replace "https://app.notesnook.com" "${NOTESNOOK_APP_HOST}"
  replace "https://app.example.com"   "${NOTESNOOK_APP_HOST}"
fi

exec nginx -g 'daemon off;'
