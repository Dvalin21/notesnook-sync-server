# Build Stage - pinned upstream commit + runtimes for reproducibility
FROM node:22-bookworm-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/streetwriters/notesnook.git . \
 && git checkout 143892e260532cbe80d194fbbedd8955b70ef025
RUN npm ci
# Self-host wiring: upstream web reads NN_<HOST> at build time
# (vite envPrefix) - without these it defaults to official infra.
ARG NN_API_HOST NN_AUTH_HOST NN_SSE_HOST NN_MONOGRAPH_HOST
ENV NN_API_HOST=${NN_API_HOST} NN_AUTH_HOST=${NN_AUTH_HOST} NN_SSE_HOST=${NN_SSE_HOST} NN_MONOGRAPH_HOST=${NN_MONOGRAPH_HOST}
RUN npm run build:web
# Production Stage
FROM nginx:1.28-alpine
RUN rm -rf /usr/share/nginx/html/*
COPY --from=builder /app/apps/web/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
