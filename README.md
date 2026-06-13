# AegisRemit — Infrastructure

Production infrastructure for [aegisremit.ng](https://aegisremit.ng), deployed on a Contabo Cloud VPS (EU region).

## Repository map

```
Vantroxia-Labs/
├── remit          # .NET 10 backend (Portal API, ERP API, SFTP API)
├── admin          # React/TypeScript admin portal
└── infra          # ← you are here (deployment, CI/CD, config)
```

## Directory structure

The infrastructure is physically segregated into three isolated compose stacks.
Updating an API will never inadvertently restart the reverse proxy, and taking
down the proxy won't kill your database connections.

```
/opt/aegisremit/               # VPS deploy directory
├── .env                       # Secrets (never committed)
├── otel-collector-config.yaml # OpenTelemetry config
├── traefik/
│   └── docker-compose.yml     # Traefik reverse proxy (edge router)
├── infra/
│   └── docker-compose.yml     # Redis, RabbitMQ, MinIO, OTEL, SFTPGo
└── apps/
    └── docker-compose.yml     # Portal API, ERP API, SFTP API, Admin
```

Shared resources (Docker networks and volumes) are created externally by
`scripts/bootstrap-vps.sh` before any compose stack is started.

## Architecture

```
Internet
  │
  ├─── aegisremit.ng ──────► Cloudflare (DNS + CDN + DDoS)
  │                                │
  │                          ┌─────▼──────┐
  │                          │   Traefik   │ :80/:443
  │                          │  (reverse   │ auto SSL via
  │                          │   proxy)    │ Let's Encrypt
  │                          └──┬──┬──┬────┘
  │                             │  │  │
  │    api.aegisremit.ng  ──────┘  │  └──── app.aegisremit.ng
  │         │                      │              │
  │    ┌────▼─────┐          erp.aegisremit.ng   ┌────▼─────┐
  │    │ Portal   │          (+ infra            │  React   │
  │    │   API    │           dashboards)         │  Admin   │
  │    └────┬─────┘                               └──────────┘
  │         │
  │    ┌────┼──────────┬──────────┬──────────┐
  │    │    │          │          │          │
  │  ┌─▼──┐ ┌──▼──┐ ┌──▼───┐ ┌──▼──┐ ┌──▼──────┐
  │  │ PG │ │Redis│ │Rabbit│ │MinIO│ │  OTEL   │
  │  │ 17 │ │  7  │ │ MQ   │ │     │ │Collector│
  │  └────┘ └─────┘ └──────┘ └─────┘ └────┬────┘
  │  self-                                 │
  │  hosted                          ┌─────▼─────┐
  │                                  │  SigNoz   │
  │                                  │(deferred) │
  │                                  └───────────┘
```

## Subdomains

| Subdomain | Service | Access |
|---|---|---|
| `api.aegisremit.ng` | Portal API | Public |
| `erp.aegisremit.ng` | ERP API | Public |
| `app.aegisremit.ng` | React admin portal | Public |
| `aegisremit.ng` / `www` | React admin portal | Public |
| `traefik.aegisremit.ng` | Traefik dashboard | BasicAuth |
| `rabbitmq.aegisremit.ng` | RabbitMQ management | BasicAuth |
| `minio.aegisremit.ng` | MinIO console | BasicAuth |
| `sftpgo.aegisremit.ng` | SFTPGo web admin | BasicAuth |

## Quick start (after VPS provisioning)

```bash
# 1. SSH into VPS as root, run bootstrap
scp scripts/bootstrap-vps.sh root@YOUR_VPS_IP:/tmp/
ssh root@YOUR_VPS_IP 'bash /tmp/bootstrap-vps.sh "ssh-ed25519 AAAA...your-ci-key"'

# 2. SSH as deploy user, clone infra
ssh deploy@YOUR_VPS_IP
git clone git@github.com:Vantroxia-Labs/infra.git /opt/aegisremit
cd /opt/aegisremit

# 3. Configure environment
cp .env.example .env
nano .env  # fill in real passwords + Cloudflare token
chmod 600 .env

# 4. Launch each stack in order
cd /opt/aegisremit/traefik && docker compose --env-file ../.env up -d
cd /opt/aegisremit/infra   && docker compose --env-file ../.env up -d
cd /opt/aegisremit/apps    && docker compose --env-file ../.env up -d

# 5. Verify
curl -k https://api.aegisremit.ng/health
```

## CI/CD flow

```
Developer pushes to remit/admin repo
  │
  ├─► GitHub Actions builds Docker image
  ├─► Pushes to ghcr.io/vantroxia-labs/remit-*:sha-abc123
  ├─► Dispatches deploy event to infra repo
  │
  └─► VPS: cd /opt/aegisremit/apps → pull new image → restart service
```

See `.github/workflows/` in each repo for pipeline definitions.

## Secrets management

All secrets live in the `.env` file on the VPS (`/opt/aegisremit/.env`).
CI/CD secrets are stored as GitHub Actions secrets in the `infra` repo.

**Required GitHub secrets (infra repo):**

| Secret | Purpose |
|---|---|
| `VPS_HOST` | Contabo VPS IP address |
| `VPS_SSH_KEY` | Private SSH key for `deploy` user |
| `GHCR_TOKEN` | GitHub PAT with `packages:read` scope |

**Required GitHub secrets (remit + admin repos):**

| Secret | Purpose |
|---|---|
| `GHCR_TOKEN` | GitHub PAT with `packages:write` scope |
