# Notesnook Sync Server

Self-hosted Notesnook sync backend in Docker. No .NET build required.
This fork adds operational hardening, fixed CORS wiring, and per-service
ASP.NET DataProtection key persistence.

Big picture: one port, all traffic.

    YOUR TLS PROXY :443 -> this host :8080 -> Caddy :80 -> by Host header:
      sync.example.com    -> notesnook-server:5264
      auth.example.com    -> identity-server:8264
      sse.example.com     -> sse-server:7264
      notes.example.com   -> monograph-server:3000
      example.com         -> monograph-server:3000
      attach.example.com  -> notesnook-s3:9000
      minio.example.com   -> notesnook-s3:9090
      cors.example.com    -> cors-proxy:3000

Clients never touch internal ports. Everything behind 8080 is plain HTTP.
Your external proxy terminates TLS.

## How to clone and reproduce on another machine

1. Clone.

       git clone https://github.com/Dvalin21/notesnook-sync-server.git ~/host/notesnook-sync-server
       cd ~/host/notesnook-sync-server

2. Create `.env` from the committed template and edit every CHANGEME.

       cp .env.example .env
       nano .env

   Required inputs:
   - `SERVER_DOMAIN=example.com`
   - public URLs all use `https://<sub>.example.com`, matching `SERVER_DOMAIN`
   - `NOTESNOOK_API_SECRET=<generate via: openssl rand -base64 48`
   - `DISABLE_SIGNUPS=true` until finished testing
   - `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` + strong new passwords

3. Create DNS `A` records that point to this host:

       sync.example.com     -> this host
       auth.example.com     -> this host
       sse.example.com      -> this host
       notes.example.com    -> this host
       example.com          -> this host
       attach.example.com   -> this host
       minio.example.com    -> this host
       cors.example.com     -> this host

4. Configure your TLS proxy / reverse proxy to forward **all** of these
   `Host:` headers to `http://<this-host-ip>:8080`.

5. Start the stack.

       docker compose pull
       docker compose up -d
       docker compose logs -f

   Watch `validate` print:

       All required environment variables are set.

   First boot is the slowest.

## .env public URL / subdomain mapping

| Variable | Android/Web field | Caddy `Host:` header | Internal target |
|---|---|---|---|
| `NOTESNOOK_APP_PUBLIC_URL` | Sync URL | `sync.example.com` | `notesnook-server:5264` |
| `AUTH_SERVER_PUBLIC_URL` | Auth URL | `auth.example.com` | `identity-server:8264` |
| `MONOGRAPH_PUBLIC_URL` | Web URL | `notes.example.com` / `example.com` | `monograph-server:3000` |
| `ATTACHMENTS_SERVER_PUBLIC_URL` | Attachments URL | `attach.example.com` | `notesnook-s3:9000` |

Never mix these up. The Android client uses the first three exactly as
shown above. Web client uses `MONOGRAPH_PUBLIC_URL`.

## Single port model

By design this stack publishes ONE port externally: port 8080.

- Host `:8080` -> Caddy `:80` -> routes by Host header
- Every subdomain is a `Host:` header match.
- Internal ports 5264/7264/8264/6264/9000/9090/3000 are NOT exposed to
  clients. They are only reachable inside the Docker network.

## Step-by-step verification

After `docker compose up -d` and `logs -f`, verify every path:

    curl -fsS http://localhost:5264/health && echo ' sync OK'
    curl -fsS http://localhost:8264/health && echo ' auth OK'
    curl -fsS http://localhost:7264/health && echo ' sse OK'
    curl -fsS http://localhost:6264/api/health && echo ' monograph OK'
    curl -fsS http://localhost:9000/health && echo ' S3 API OK'
    curl -fsS http://localhost:9090/api/health && echo ' MinIO console OK'
    curl -fsS http://localhost:3000/health && echo ' CORS proxy OK'

Public path through Caddy using host headers:

    curl -fsS -H "Host: sync.example.com"   http://localhost:8080/health
    curl -fsS -H "Host: auth.example.com"   http://localhost:8080/health
    curl -fsS -H "Host: sse.example.com"    http://localhost:8080/health
    curl -fsS -H "Host: notes.example.com"  http://localhost:8080/api/health
    curl -fsS -H "Host: example.com"        http://localhost:8080/api/health
    curl -fsS -H "Host: attach.example.com" http://localhost:8080/health
    curl -fsS -H "Host: minio.example.com"  http://localhost:8080/
    curl -fsS -H "Host: cors.example.com"   http://localhost:8080/health

If your TLS proxy points at 8080, use its own IP/hostname in place of
`localhost` above.

## Connecting clients

### Android client

Settings -> Sync -> Use custom server:

  Auth URL:      https://auth.example.com
  Sync URL:      https://sync.example.com
  Attachments:   https://attach.example.com

### Web client

https://notes.example.com or https://example.com

## MinIO admin login

- Console URL:  https://minio.example.com
- S3 API URL:   https://attach.example.com
- Username: value of `MINIO_ROOT_USER` in `.env`
- Password: value of `MINIO_ROOT_PASSWORD` in `.env`

`setup-s3` creates the `attachments` bucket automatically on first boot.

## Secrets hygiene

- `.env` is gitignored. If `.env` is present in the working tree, it may
  contain live credentials and should not be committed.
- `.env.example` IS committed and contains placeholders only.
- Sanitize before committing any docs or scripts: strip real domains and
  credentials.

## Maintenance

Backups:

    docker compose exec notesnook-db mongodump \
      --uri="mongodb://notesnook-db:27017/${MONGODB_DATABASE_NAME:-notesnook}" \
      --archive=/backup/notesnook-$(date +%Y%m%d).archive

    docker compose exec notesnook-s3 mc mirror /data/s3 /backup/s3

Updates:

    git pull origin master
    docker compose pull
    docker compose up -d

## What this fork changed upstream

1. `MONGODB_DATABASE_NAME` is honored by all repositories.
2. `NOTESNOOK_CORS_ORIGINS` env var is wired correctly.
3. Missing OAuth `profile` scope added in identity config.
4. Per-service ASP.NET DataProtection key volumes instead of one shared `dpdata`.
5. MongoDB is NOT exposed on a host port.
6. Healthchecks use `nc` / `node` / `bun` instead of `wget`.
7. Image tags are pinned to immutable versions.
8. `setup-s3` fails fast if `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` are missing.
