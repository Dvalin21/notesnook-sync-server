# Build Stage - pinned upstream commit + runtimes for reproducibility
FROM node:22-bookworm-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/streetwriters/notesnook.git . \
 && git checkout 143892e260532cbe80d194fbbedd8955b70ef025
RUN npm ci
# Self-host patches: connectivity check hits our API (not official SaaS);
# og metas point at the placeholder, never a real domain.
RUN sed -i 's|fetch("https://api.notesnook.com/health")|fetch(`${import.meta.env.NN_API_HOST}/health`)|' apps/web/src/utils/network-check.worker.ts \
 && sed -i 's|https://app.notesnook.com|https://app.example.com|g' apps/web/src/index.html
# Self-host wiring: upstream web reads NN_<HOST> at build time
# (vite envPrefix) - without these it defaults to official infra.
ARG NN_API_HOST NN_AUTH_HOST NN_SSE_HOST NN_MONOGRAPH_HOST
ENV NN_API_HOST=${NN_API_HOST} NN_AUTH_HOST=${NN_AUTH_HOST} NN_SSE_HOST=${NN_SSE_HOST} NN_MONOGRAPH_HOST=${NN_MONOGRAPH_HOST}
RUN npm run build:web && find /app/apps/web/build -name '*.map' -delete
# The NN_* args above are left EMPTY on purpose and nothing passes them.
# Vite inlines import.meta.env.NN_* at build time, so an arg here would compile
# the operator's domain into the image and force a rebuild to change it.
# With them empty the bundle keeps upstream's own defaults, and entrypoint.sh
# substitutes the operator's URLs at boot from the environment instead.
# Production Stage - ships upstream Notesnook hosts only.
FROM nginx:1.28-alpine
RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /app/apps/web/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
