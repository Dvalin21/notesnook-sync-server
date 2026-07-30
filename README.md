# Notesnook Sync Server

Self-hosted Notesnook sync backend in Docker. No .NET build required.
This fork adds operational hardening, fixed CORS wiring, and per-service
ASP.NET DataProtection key persistence.

Big picture: one port, all traffic.

    YOUR TLS PROXY :443 -> this host :8080 -> Caddy -> by Host header:
      sync.example.com    -> sync server/notesnook:5264
      auth.example.com    -> identity server/identity:8264
      sse.example.com     -> SSE hub/sse:7264
      notes.example.com   -> Monograph web client/monograph:3000
      example.com         -> Monograph web client/monograph:3000
      attach.example.com  -> MinIO S3 API:9000
      minio.example.com   -> MinIO web console:9090
      cors.example.com    -> CORS proxy/cors-proxy:3000

Clients never touch internal ports. Everything behind 8080 is plain HTTP.
Your external proxy terminates TLS.

## Prerequisites

- Linux host with Docker Compose v2.
- A domain name you control (`example.com`).
- A TLS terminator / reverse proxy with an `A` record pointing to this host.
- Port 8080/TCP reachable from the proxy. Nothing else needs to be public.

## Step-by-step setup (caveman edition)

1. Clone the repo to proper location.

       git clone https://github.com/Dvalin21/notesnook-sync-server.git ~/host/notesnook-sync-server
       cd ~/host/notesnook-sync-server

2. Create `.env` from the template and edit EVERY variable marked CHANGEME.

       cp .env.example .env
       nano .env

   Minimum production safe values:
   - `SERVER_DOMAIN=example.com`
   - `NOTESNOOK_API_SECRET=<generate via: openssl rand -base64 48`
   - `DISABLE_SIGNUPS=true` until finished testing.
   - Public URLs all use `https://<sub>.example.com`, matching `SERVER_DOMAIN`.
   - `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` are strong new passwords.

3. Create TLS records. Minimum DNS (`A`):

       sync.example.com     -> your host
       auth.example.com     -> your host
       sse.example.com      -> your host
       notes.example.com    -> your host
       attach.example.com   -> your host
       minio.example.com    -> your host
       cors.example.com     -> your host
       example.com          -> your host
       attach.example.com   -> your host

   Also configure your TLS proxy to forward all of these `Host:` headers
   to `http://<host-ip>:8080`.

4. Start the stack.

       ./scripts/sanitize-env          # optional: strip local .env into safe repo copy
       docker compose pull
       docker compose up -d
       docker compose logs -f

   Watch for `validate` to print:

       All required environment variables are set.

   The first boot is the slowest.

5. Verify each path is alive.

       curl -fsS http://localhost:5264/health && echo 'sync OK'
       curl -fsS http://localhost:8264/health && echo 'auth OK'
       curl -fsS http://localhost:7264/health && echo 'sse OK'
       curl -fsS http://localhost:6264/api/health && echo 'monograph OK'
       curl -fsS http://localhost:9000/health && echo 'minio S3 OK'
       curl -fsS http://localhost:9090/ && echo 'minio console OK'
       curl -fsS http://localhost:3000/health && echo 'cors OK'

   Those verify internal containers. The public path must also forward
   through your TLS proxy:

       curl -fsS -H "Host: sync.example.com" http://localhost:8080/health

6. Connect your Notesnook Android app.

   Settings -> Sync -> Use custom server:

     Auth URL:    `https://auth.example.com`
     Sync URL:    `https://sync.example.com`
     Attachments: `https://attach.example.com`

   Web client: `https://notes.example.com` or `https://example.com`.

## Single port model

By design this stack publishes ONE port externally: port 8080.

- Host `:8080` -> Caddy `:80` -> routes by Host header
- Every subdomain is a `Host:` header match. IP-based direct ports are NOT meant for clients.
- MinIO, identity, sync, SSE, and monograph do NOT need 6264/7264/8264/5264/9000/9090 exposed outside the host.

## Maintenance

### Backup

    docker compose exec notesnook-db mongodump \
      --uri="mongodb://notesnook-db:27017/${MONGODB_DATABASE_NAME:-notesnook}" \
      --archive=/backup/notesnook-$(date +%Y%m%d).archive

    docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3

## Update

    git pull origin master
    docker compose pull
    docker compose up -d

### MongoDB upgrade rules
If changing `mongo:` tags from 7.0 to 8.x, you need FCV migration
handshake noted in MongoDB documentation. Do not image-pull before
