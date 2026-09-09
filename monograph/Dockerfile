# Build Stage - pinned upstream commit, same pin as web/ image
FROM node:22-bookworm-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/streetwriters/notesnook.git . \
 && git checkout 143892e260532cbe80d194fbbedd8955b70ef025
RUN npm ci --ignore-scripts --prefer-offline --no-audit
RUN CI=true npm run bootstrap -- --scope=monograph
# Self-host: published images must contain NO real domain. Bake the
# placeholder; server.ts rewrites it to $NOTESNOOK_APP_HOST per request.
# (monograph/ is build context, so the patch ships with the repo.)
COPY server-app-url.patch /tmp/server-app-url.patch
RUN grep -rl 'https://app.notesnook.com' apps/monograph/app \
  | xargs sed -i "s|https://app.notesnook.com|https://app.example.com|g" \
  && git apply /tmp/server-app-url.patch
RUN npm run tx @notesnook/monograph:build
# Production Stage - same runtime as upstream image
FROM oven/bun:1.3.14-slim
RUN mkdir -p /home/bun/app && chown -R bun:bun /home/bun/app
WORKDIR /home/bun/app
USER bun
COPY --chown=bun:bun --from=builder /app/apps/monograph/output ./
RUN bun install
CMD [ "bun", "run", "start" ]
