# Vantroxia Labs — VPS Setup

Home on the VPS: **/opt/vantroxia** (git repo `vantroxia-vps`).

```
/opt/vantroxia
├── traefik/                      # Stack 1: edge proxy (ports 80/443)
│   ├── docker-compose.yml        # traefik:v3.6, memory 128M
│   ├── traefik.yml               # static config: entrypoints, ACME (HTTP-01), docker+file providers
│   ├── dynamic/middlewares.yml   # admin-allowlist (CF edge IPs), secure-headers, api-ratelimit
│   └── .env                      # BASE_DOMAIN, TRAEFIK_DASHBOARD_AUTH
├── infra/                        # Stack 2: shared services (neutral names)
│   ├── docker-compose.yml        # postgres, redis, rabbitmq, minio, openobserve, otel-collector
│   ├── .env
│   ├── postgres/create-app-db.sh
│   ├── rabbitmq/create-app-vhost.sh
│   └── otel/config.yaml          # OTLP receiver → OpenObserve exporter
├── apps/
│   ├── aegisremit/               # portal-api + erp-api (.NET)
│   ├── gymmate/                  # api (Spring Boot / Java 21)
│   └── templates/springboot.docker-compose.yml   # copy-me template (e.g. AegisTrader)
└── scripts/fresh-install.sh      # destructive clean rebuild (provisions AegisRemit)
```

## Stacks & images

| Stack   | Service         | Image                                           | Mem limit | Exposed host                     |
|---------|-----------------|-------------------------------------------------|-----------|----------------------------------|
| traefik | traefik         | `traefik:v3.6`                                  | 128M      | `traefik.${BASE_DOMAIN}` (admin) |
| infra   | postgres        | `postgres:18-alpine`                            | 1G        | internal only                    |
| infra   | redis           | `redis:7-alpine` (`--maxmemory 200mb`, LRU)     | 256M      | internal only                    |
| infra   | rabbitmq        | `rabbitmq:4-management-alpine`                   | 512M      | `mq.${BASE_DOMAIN}` (admin)      |
| infra   | minio           | `minio/minio:latest`                            | 512M      | `minio.` (admin) + `s3.` (public)|
| infra   | openobserve     | `public.ecr.aws/zinclabs/openobserve:latest`    | 768M      | `logs.${BASE_DOMAIN}` (admin)    |
| infra   | otel-collector  | `otel/opentelemetry-collector-contrib:0.111.0`  | 256M      | internal only                    |

## Observability (self-hosted, NOT SigNoz)

Telemetry is fully self-hosted — there is **no SigNoz Cloud dependency**.

- Apps export OTLP to `http://otel-collector:4317` (gRPC) / `:4318` (HTTP) on the `backend` network.
  - .NET apps read `OTEL_EXPORTER_OTLP_ENDPOINT` **and** `SigNoz__Endpoint` (the app's config key is
    literally named `SigNoz:Endpoint`, but it points at the local collector).
- The OTEL Collector (`infra/otel/config.yaml`) receives traces/metrics/logs, adds `hostmetrics`,
  batches, and exports to **OpenObserve** at `http://openobserve:5080/api/default` using
  `Authorization: Basic ${OPENOBSERVE_OTLP_AUTH}`.
- OpenObserve stores everything on the `openobserve-data` volume with **15-day retention**
  (`ZO_COMPACT_DATA_RETENTION_DAYS=15`) to protect the shared NVMe. UI at `logs.${BASE_DOMAIN}`
  (IP-restricted via `admin-allowlist@file`).

## Isolation model

| App          | Postgres DB      | Redis DB | RabbitMQ vhost | Container prefix | Status              |
|--------------|------------------|----------|----------------|------------------|---------------------|
| aegisremit   | `aegisremit_db`  | 0        | `/aegisremit`  | `aegisremit-`    | deployed            |
| gymmate      | `gymmate_db`     | 1        | *(not used)*   | `gymmate-`       | deployed            |
| aegistrader  | `aegistrader_db` | 2        | `/aegistrader` | `aegistrader-`   | template only       |

Shared services: postgres / redis / rabbitmq / minio / openobserve / otel-collector / traefik,
plus the external `proxy` and `backend` Docker networks.
Infra containers use **neutral names** (`postgres`, not `aegisremit-postgres`) — they belong to
Vantroxia, not to any single product.

> GymMate does not use RabbitMQ. It owns its schema via Flyway (`FLYWAY_ENABLED=true`,
> `JPA_DDL_AUTO=update`) and requires a bootstrap admin (`GYMMATE_ADMIN_EMAIL` /
> `GYMMATE_ADMIN_PASSWORD`) or it aborts on startup.

## Deployed app services

- **AegisRemit** (`apps/aegisremit`): `portal-api` → `api.aegisremit.ng`, `erp-api` → `erp.aegisremit.ng`.
  Both are .NET (512M each), TLS terminated at Traefik. Images from
  `ghcr.io/vantroxia-labs/remit-portal-api` and `…/remit-erp-api`.
  (No `sftp-api` or `admin` service is built or deployed.)
- **GymMate** (`apps/gymmate`): `api` → `api.gymmate.${BASE_DOMAIN}` (1G). Spring Boot / Java 21,
  frontend expected at `gymmate.${BASE_DOMAIN}`.

## Fresh install steps

```bash
# 1. Clone/copy this tree to the VPS
sudo mkdir -p /opt/vantroxia && sudo chown deploy:deploy /opt/vantroxia
# ... copy files ...
cd /opt/vantroxia

# 2. Fill in configs
cp traefik/.env.example traefik/.env && nano traefik/.env
cp infra/.env.example   infra/.env   && nano infra/.env      # includes OPENOBSERVE_* + OPENOBSERVE_OTLP_AUTH
cp apps/aegisremit/.env.example apps/aegisremit/.env && nano apps/aegisremit/.env
nano traefik/dynamic/middlewares.yml     # confirm CF edge ranges / your real IP
chmod 600 traefik/.env infra/.env apps/aegisremit/.env

# 3. Run the rebuild (destroys old aegisremit-* containers/volumes)
./scripts/fresh-install.sh
```

`fresh-install.sh` tears down any legacy `/opt/aegisremit` stacks, creates the `proxy` + `backend`
networks, starts Traefik and infra, waits for Postgres + RabbitMQ to be healthy, then provisions
**AegisRemit only** (`create-app-db.sh aegisremit`, `create-app-vhost.sh aegisremit`) and starts it.
Other apps (e.g. GymMate) are brought up manually — see below.

## `OPENOBSERVE_OTLP_AUTH`

The collector authenticates to OpenObserve with HTTP Basic. Generate the value once and put it in
`infra/.env`:

```bash
printf '%s' 'you@example.com:your-openobserve-password' | base64
# → set OPENOBSERVE_OTLP_AUTH=<that base64 string> in infra/.env
```

## Onboarding a NEW product later

```bash
cd /opt/vantroxia/infra
./postgres/create-app-db.sh gymmate '<db-pass>'
# only if the app uses RabbitMQ:
./rabbitmq/create-app-vhost.sh gymmate '<mq-pass>'
cd ../apps/gymmate && cp .env.example .env && nano .env && docker compose up -d
```

`create-app-db.sh` creates a login role + `${app}_db`, revokes PUBLIC, and hands the role ownership
of `public` (needed for EF Core / Flyway on PG15+). `create-app-vhost.sh` creates `/${app}` and a
scoped user. Both are idempotent.

## DNS (Cloudflare) → VPS IP

- **Admin (IP-restricted via `admin-allowlist@file`)** on `vantroxialabs.com`:
  `traefik.`, `mq.`, `minio.`, `s3.` (S3 API is public), `logs.`
- **AegisRemit:** `api.aegisremit.ng`, `erp.aegisremit.ng`
- **GymMate:** `api.gymmate.vantroxialabs.com` (API) + `gymmate.vantroxialabs.com` (frontend)
- Per-product subdomains as you add apps

> `s3.${BASE_DOMAIN}` is intentionally **public** (presigned URLs must be reachable); the MinIO
> console `minio.` is admin-restricted.

## Memory budget (8 GB box)

| Service                          | Limit  |
|----------------------------------|--------|
| Traefik                          | 128M   |
| Postgres                         | 1G     |
| Redis                            | 256M   |
| RabbitMQ                         | 512M   |
| MinIO                            | 512M   |
| OpenObserve                      | 768M   |
| OTEL Collector                   | 256M   |
| AegisRemit (portal-api + erp-api)| 1G     |
| GymMate (api)                    | 1G     |
| **Subtotal (current fleet)**     | **~5.4G** |
| Spring Boot template (each)      | +768M  |

~2.5 GB headroom for OS + page cache with the current fleet. Observability stays on-box via
OpenObserve; move to a dedicated telemetry VPS only when traffic justifies it.

## CI/CD (repository_dispatch pattern)

Product repos build → push to GHCR → `repository_dispatch` to this repo → GitHub Action SSHes in →
`cd /opt/vantroxia/apps/<product> && docker compose pull && docker compose up -d`.
Deploy paths use `/opt/vantroxia/apps/<product>` (migrated from the old `/opt/aegisremit`).

## Notes

- TLS is terminated at Traefik (HTTP→HTTPS redirect + HSTS via `secure-headers@file`); app
  containers speak plain HTTP on `backend`, so they set `Security__EnforceHttps=false`.
- ACME uses the **HTTP-01 challenge** (`traefik.yml`), storing certs in the `traefik-certs` volume
  (`acme.json`). A fresh volume means Let's Encrypt re-issues on first start — watch rate limits if
  you rebuild repeatedly (5 duplicate certs/week per domain set).
- Postgres 18 moved `PGDATA` to `/var/lib/postgresql/18/docker`; the volume mounts the parent
  `/var/lib/postgresql` so data persists across upgrades.
- The `admin-allowlist` middleware only blocks direct-to-origin bypass behind Cloudflare — it is
  **not authentication**. Put Cloudflare Access (Zero Trust) in front of admin hosts for the real gate.
