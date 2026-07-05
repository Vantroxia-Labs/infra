# Vantroxia Labs — VPS Fresh Setup

Layout on the VPS (new home: **/opt/vantroxia**, git repo `vantroxia-infra`):

```
/opt/vantroxia
├── traefik/                 # Stack 1: edge proxy (ports 80/443)
│   ├── docker-compose.yml
│   ├── traefik.yml
│   ├── dynamic/middlewares.yml   # <-- put your IP in admin-allowlist
│   └── .env                      # BASE_DOMAIN, dashboard auth
├── infra/                   # Stack 2: shared services (neutral names)
│   ├── docker-compose.yml        # postgres, redis, rabbitmq, minio, sftpgo, otel
│   ├── .env
│   ├── postgres/create-app-db.sh
│   ├── rabbitmq/create-app-vhost.sh
│   └── otel/config.yaml          # → SigNoz Cloud
├── apps/
│   ├── aegisremit/               # portal-api, erp-api, sftp-api, admin
│   ├── gymmate/                  # api + web
│   └── templates/springboot.docker-compose.yml   # for AegisTrader etc.
└── scripts/fresh-install.sh      # destructive clean rebuild
```

## Isolation model

| App        | Postgres DB    | Redis DB | RabbitMQ vhost | Container prefix |
|------------|----------------|----------|----------------|------------------|
| aegisremit | aegisremit_db  | 0        | /aegisremit    | aegisremit-      |
| gymmate    | gymmate_db     | 1        | /gymmate       | gymmate-         |
| aegistrader| aegistrader_db | 2        | /aegistrader   | aegistrader-     |

Shared: postgres / redis / rabbitmq / minio / sftpgo / otel-collector / traefik,
plus the external `proxy` and `backend` Docker networks.
Infra containers now have **neutral names** (`postgres`, not `aegisremit-postgres`)
— they belong to Vantroxia, not to any product.

## Fresh install steps

```bash
# 1. Clone/copy this tree to the VPS
sudo mkdir -p /opt/vantroxia && sudo chown deploy:deploy /opt/vantroxia
# ... copy files ...
cd /opt/vantroxia

# 2. Fill in configs
cp traefik/.env.example traefik/.env && nano traefik/.env
cp infra/.env.example   infra/.env   && nano infra/.env
cp apps/aegisremit/.env.example apps/aegisremit/.env && nano apps/aegisremit/.env
nano traefik/dynamic/middlewares.yml     # your real IP
chmod 600 traefik/.env infra/.env apps/aegisremit/.env

# 3. Run the rebuild (destroys old aegisremit-* containers/volumes)
./scripts/fresh-install.sh
```

## Onboarding a NEW product later (two commands + one folder)

```bash
cd /opt/vantroxia
./infra/postgres/create-app-db.sh gymmate '<db-pass>'
./infra/rabbitmq/create-app-vhost.sh gymmate '<mq-pass>'
cd apps/gymmate && cp .env.example .env && nano .env && docker compose up -d
```

## DNS (Cloudflare) → VPS IP
- Admin (IP-restricted): `traefik.`, `mq.`, `minio.`, `s3.`, `sftp.` on vantroxialabs.com
- AegisRemit: `api.aegisremit.ng`, `erp.aegisremit.ng`, `admin.aegisremit.ng`
- Per-product subdomains as you add apps

## Memory budget (8 GB)

| Service | Limit |
|---|---|
| Traefik | 128M |
| Postgres | 1G |
| Redis | 256M |
| RabbitMQ | 512M |
| MinIO | 512M |
| SFTPGo | 256M |
| OTEL Collector | 256M |
| AegisRemit (3 APIs + admin) | ~1.6G |
| GymMate (api + web) | ~600M |
| Spring Boot (capped) | 768M |
| **Ceiling** | **~5.9G** |

~2 GB headroom for OS + page cache. SigNoz stays on Cloud free tier;
self-host on a second VPS only when traffic justifies it.

## CI/CD (unchanged pattern)
Product repos build → push to GHCR → repository_dispatch to this repo →
GitHub Action SSHes in → `cd /opt/vantroxia/apps/<product> && docker compose pull && docker compose up -d`.
Update your ci-remit.yml / ci-admin.yml deploy paths from /opt/aegisremit to /opt/vantroxia/apps/aegisremit.

## Notes
- SFTP host port stays **2222** (unchanged from your current setup).
- SFTPGo now uses **PostgreSQL** (`sftpgo_db`) instead of the memory provider.
- RabbitMQ upgraded 3.13 → 4.x (fine on a fresh start; queues are re-declared by apps).
- Traefik certs live in the `traefik_traefik-certs`-equivalent named volume `traefik-certs`;
  fresh volume means Let's Encrypt will re-issue on first start (watch rate limits if you
  rebuild repeatedly — 5 duplicate certs/week per domain set).
