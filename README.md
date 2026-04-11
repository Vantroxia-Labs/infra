# AegisRemit — Infrastructure

Production infrastructure for [aegisremit.ng](https://aegisremit.ng), deployed on a Contabo Cloud VPS (EU region).

## Repository map

```
Vantroxia-Labs/
├── remit          # .NET 9 backend (API + background worker)
├── admin          # React/TypeScript admin portal
└── infra          # ← you are here (deployment, CI/CD, config)
```

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
  │    ┌────▼─────┐          rabbitmq.*      ┌────▼─────┐
  │    │  .NET 9  │          traefik.*       │  React   │
  │    │   API    │          (dashboards)     │  Admin   │
  │    └────┬─────┘                          └──────────┘
  │         │
  │    ┌────▼─────┐
  │    │  Worker  │ (SFTP + Quartz jobs)
  │    └────┬─────┘
  │         │
  │    ┌────┼──────────┬──────────┐
  │    │    │          │          │
  │  ┌─▼──┐ ┌──▼──┐ ┌──▼───┐ ┌──▼──────┐
  │  │ PG │ │Redis│ │Rabbit│ │  OTEL   │
  │  │ 16 │ │  7  │ │ MQ   │ │Collector│
  │  └────┘ └─────┘ └──────┘ └────┬────┘
  │                                │
  │                          ┌─────▼─────┐
  │                          │  SigNoz   │
  │                          │(deferred) │
  │                          └───────────┘
```

## Subdomains

| Subdomain | Service | Access |
|---|---|---|
| `api.aegisremit.ng` | .NET API | Public |
| `app.aegisremit.ng` | React admin portal | Public |
| `traefik.aegisremit.ng` | Traefik dashboard | BasicAuth |
| `rabbitmq.aegisremit.ng` | RabbitMQ management | BasicAuth |
| `signoz.aegisremit.ng` | SigNoz UI (future) | BasicAuth |

## Quick start (after VPS provisioning)

```bash
# 1. SSH into VPS as root, run initial setup
scp setup/setup-vps.sh root@YOUR_VPS_IP:/root/
ssh root@YOUR_VPS_IP 'bash /root/setup-vps.sh'

# 2. SSH as deploy user, clone infra
ssh deploy@YOUR_VPS_IP
git clone git@github.com:Vantroxia-Labs/infra.git /opt/aegisremit
cd /opt/aegisremit

# 3. Configure environment
cp .env.example .env
nano .env  # fill in real passwords + Cloudflare token

# 4. Launch
docker compose up -d

# 5. Verify
docker compose ps
curl -k https://api.aegisremit.ng/health
```

## CI/CD flow

```
Developer pushes to remit/admin repo
  │
  ├─► GitHub Actions builds Docker image
  ├─► Pushes to ghcr.io/vantroxia-labs/remit-api:sha-abc123
  ├─► Updates image tag in infra repo (or dispatches deploy)
  │
  └─► VPS pulls new image + restarts service
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
