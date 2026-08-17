# Vantroxia Labs — Deployment & CI/CD Guide

This guide details the deployment architecture, CI/CD pipelines, container orchestration, edge routing, and operational runbooks for all applications hosted on the Vantroxia Labs VPS.

---

## 1. Architecture Overview

The infrastructure employs a **Hub-and-Spoke (Repository Dispatch)** deployment model.

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                           APPLICATION REPOSITORIES                             │
│                                                                                │
│  GymmateHub/Backend       GymmateHub/frontend   Vantroxia-Labs/remit   Vantroxia-Labs/admin │
│  (Spring Boot / Java 21)  (React / Vite)        (.NET 10 Web APIs)     (React / Vite)       │
└───────────┬───────────────────────┬──────────────────────┬─────────────────────┬───────────┘
            │                       │                      │                     │
      Build & Push            Build & Push           Build & Push          Build & Push
            │                       │                      │                     │
            ▼                       ▼                      ▼                     ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                        GITHUB CONTAINER REGISTRY (ghcr.io)                                 │
│  • gymmate-backend:latest          • gymmate-frontend:latest                               │
│  • remit-portal-api:latest         • remit-erp-api:latest        • remit-admin:latest      │
└──────────────────────────────────────────────────────────────┬─────────────────────────────┘
                                                               │
                                                 repository_dispatch (Webhook)
                                                               │
                                                               ▼
                                       ┌──────────────────────────────────────────────┐
                                       │        Vantroxia-Labs/infra (This Repo)      │
                                       │        Workflow: .github/workflows/deploy.yml│
                                       └──────────────────────┬───────────────────────┘
                                                              │
                                                        SSH / SCP Sync
                                                              │
                                                              ▼
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                                    PRODUCTION VPS                                          │
│                                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐  │
│  │                              TRAEFIK v3.6 (EDGE REVERSE PROXY)                       │  │
│  │  Ports: 80 / 443 | Automatic Let's Encrypt SSL (HTTP-01) | Security Headers & Rate Limit│
│  └───────┬──────────────────────────────┬──────────────────────────────┬────────────────┘  │
│          │                              │                              │                   │
│          ▼                              ▼                              ▼                   │
│   [ apps/gymmate ]              [ apps/aegisremit ]           [ apps/vantroxialabs ]       │
│   • gymmate-web (80)            • aegisremit-admin (80)       • vantroxialabs-web (80)     │
│   • gymmate-api (8080)          • aegisremit-portal-api (8080)                             │
│                                 • aegisremit-erp-api (8080)                                │
│          │                              │                                                  │
│          └──────────────────────────────┼──────────────────────────────────────────────────┘
│                                         ▼
│                              [ infra (Shared Services) ]
│                              • PostgreSQL 18 Alpine (gymmate_db, aegisremit_db)
│                              • Redis 7 Alpine (DB 0: AegisRemit, DB 1: GymMate)
│                              • RabbitMQ 4 Alpine (/aegisremit vhost)
│                              • MinIO (S3 API & Console)
│                              • OpenObserve & OpenTelemetry Collector
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Domains, Routing & Services Directory

| Application / Site | Exposed Domain | Container Name | Upstream Port | Network | SSL Resolver |
|---|---|---|---|---|---|
| **GymMate Web** | `gymmatehub.com`<br>`www.gymmatehub.com` | `gymmate-web` | `80` (nginx) | `proxy` | Let's Encrypt |
| **GymMate API** | `api.gymmatehub.com`<br>`api.gymmate.vantroxialabs.com` | `gymmate-api` | `8080` (Spring Boot) | `proxy`, `backend` | Let's Encrypt |
| **AegisRemit Admin** | `aegisremit.ng`<br>`www.aegisremit.ng` | `aegisremit-admin` | `80` (nginx) | `proxy` | Let's Encrypt |
| **AegisRemit Portal API** | `api.aegisremit.ng` | `aegisremit-portal-api` | `8080` (.NET 10) | `proxy`, `backend` | Let's Encrypt |
| **AegisRemit ERP API** | `erp.aegisremit.ng` | `aegisremit-erp-api` | `8080` (.NET 10) | `proxy`, `backend` | Let's Encrypt |
| **Vantroxia Labs Web** | `vantroxialabs.com`<br>`www.vantroxialabs.com` | `vantroxialabs-web` | `80` (nginx) | `proxy` | Let's Encrypt |
| **Traefik Dashboard** | `traefik.vantroxialabs.com` | `traefik` | internal api | `proxy` | Let's Encrypt (CF IP restricted) |
| **RabbitMQ Management**| `mq.vantroxialabs.com` | `rabbitmq` | `15672` | `proxy`, `backend` | Let's Encrypt (CF IP restricted) |
| **MinIO Console** | `minio.vantroxialabs.com` | `minio` | `9001` | `proxy`, `backend` | Let's Encrypt (CF IP restricted) |
| **MinIO S3 API** | `s3.vantroxialabs.com` | `minio` | `9000` | `proxy`, `backend` | Let's Encrypt (Public) |
| **OpenObserve UI** | `logs.vantroxialabs.com` | `openobserve` | `5080` | `proxy`, `backend` | Let's Encrypt (CF IP restricted) |

---

## 3. Automated CI/CD Workflows

### How the Pipeline Works

1. A developer merges code into the `main` branch of an application repository.
2. The application repository's GitHub Actions workflow runs tests, builds container images, and pushes them to `ghcr.io`.
3. The workflow dispatches a `repository_dispatch` webhook event to `Vantroxia-Labs/infra`.
4. `Vantroxia-Labs/infra` receives the event, SSHes to the VPS, syncs configuration files, pulls updated images, restarts affected services with zero/minimal downtime, and executes automated health checks.

### Required Secrets in App Repositories

Each application repository requires:
- `GITHUB_TOKEN` (Automatically provided by GitHub Actions for GHCR access)
- `INFRA_DEPLOY_TOKEN`: A Personal Access Token (PAT) with `repo` scope to trigger the dispatch event in `Vantroxia-Labs/infra`.

### Repository Dispatch Configuration Matrix

#### A. GymMate Backend (`GymmateHub/Backend/.github/workflows/main.yml`)
```yaml
- name: Dispatch deploy workflow
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_DEPLOY_TOKEN }}
    repository: Vantroxia-Labs/infra
    event-type: deploy
    client-payload: |
      {
        "service": "gymmate",
        "image_tag": "${{ steps.tags.outputs.sha_tag || 'latest' }}",
        "triggered_by": "${{ github.repository }}",
        "commit_sha": "${{ github.sha }}"
      }
```

#### B. GymMate Frontend (`GymmateHub/frontend/.github/workflows/main.yml`)
```yaml
- name: Dispatch deploy workflow
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_DEPLOY_TOKEN }}
    repository: Vantroxia-Labs/infra
    event-type: deploy
    client-payload: |
      {
        "service": "gymmate",
        "image_tag": "${{ steps.tags.outputs.sha_tag || 'latest' }}",
        "triggered_by": "${{ github.repository }}",
        "commit_sha": "${{ github.sha }}"
      }
```

#### C. AegisRemit Backend APIs (`Vantroxia-Labs/remit/.github/workflows/ci.yml`)
```yaml
- name: Dispatch deploy workflow
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_DEPLOY_TOKEN }}
    repository: Vantroxia-Labs/infra
    event-type: deploy
    client-payload: |
      {
        "service": "all-apis",
        "image_tag": "${{ steps.tags.outputs.sha_tag || 'latest' }}",
        "triggered_by": "${{ github.repository }}",
        "commit_sha": "${{ github.sha }}"
      }
```

#### D. AegisRemit Admin Portal (`Vantroxia-Labs/admin/.github/workflows/ci.yml`)
```yaml
- name: Dispatch deploy workflow
  uses: peter-evans/repository-dispatch@v3
  with:
    token: ${{ secrets.INFRA_DEPLOY_TOKEN }}
    repository: Vantroxia-Labs/infra
    event-type: deploy
    client-payload: |
      {
        "service": "admin",
        "image_tag": "latest",
        "triggered_by": "${{ github.repository }}",
        "commit_sha": "${{ github.sha }}"
      }
```

---

## 4. Manual Deployments & Operations Runbook

### Option 1: Trigger via GitHub Actions UI

You can trigger a deployment on demand for any service from the `Vantroxia-Labs/infra` Actions tab:
1. Navigate to **Actions** -> **Deploy**.
2. Click **Run workflow**.
3. Select the target service:
   - `all`: Redeploys every app stack (AegisRemit + GymMate + Vantroxia Labs).
   - `all-aegisremit`: Redeploys all AegisRemit services (APIs + Admin Portal).
   - `all-apis`: Runs EF Core database migrations and updates AegisRemit Portal and ERP APIs.
   - `admin`: Updates only the AegisRemit Admin web app (`aegisremit.ng`).
   - `portal-api`: Updates only the AegisRemit Portal API (`api.aegisremit.ng`).
   - `erp-api`: Updates only the AegisRemit ERP API (`erp.aegisremit.ng`).
   - `gymmate`: Updates both GymMate API (`api.gymmatehub.com`) and Web app (`gymmatehub.com`).
   - `vantroxialabs`: Rebuilds and redeploys `vantroxialabs.com`.
   - `infra`: Restarts core services (PostgreSQL, Redis, RabbitMQ, MinIO, OpenObserve).
   - `traefik`: Restarts the Traefik reverse proxy.
4. Specify the image tag (default: `latest`) and click **Run workflow**.

---

### Option 2: CLI Redeployments via SSH

When troubleshooting or applying immediate updates from your workstation terminal:

```bash
# Connect to VPS
ssh deploy@vantroxia

# ── 1. Redeploy GymMate (Frontend + Backend) ──
cd /opt/vantroxia/apps/gymmate
docker compose pull
docker compose up -d

# ── 2. Redeploy AegisRemit ──
cd /opt/vantroxia/apps/aegisremit
# Pull and apply migrations if needed:
docker pull ghcr.io/vantroxia-labs/remit-migrator:latest
docker run --rm --network backend \
  -e "ConnectionStrings__DefaultConnection=$(grep -E '^DB_CONNECTION_STRING=' .env | cut -d= -f2-)" \
  ghcr.io/vantroxia-labs/remit-migrator:latest
# Update services:
docker compose pull
docker compose up -d

# ── 3. Redeploy Vantroxia Labs Landing Page ──
cd /opt/vantroxia/apps/vantroxialabs
docker compose up -d --build

# ── 4. Restart Edge Proxy ──
cd /opt/vantroxia/traefik
docker compose up -d
```

---

## 5. Health Check & Diagnostic Commands

Run these commands to verify all services are running and accessible:

```bash
# Verify container status across all stacks
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Test HTTP status codes directly
curl -sI -o /dev/null -w "GymMate Web: %{http_code}\n" https://gymmatehub.com
curl -sI -o /dev/null -w "GymMate API: %{http_code}\n" https://api.gymmatehub.com/actuator/health
curl -sI -o /dev/null -w "AegisRemit Admin: %{http_code}\n" https://aegisremit.ng
curl -s -o /dev/null -w "AegisRemit Portal API: %{http_code}\n" https://api.aegisremit.ng/health
curl -s -o /dev/null -w "AegisRemit ERP API: %{http_code}\n" https://erp.aegisremit.ng/health
curl -sI -o /dev/null -w "Vantroxia Labs: %{http_code}\n" https://vantroxialabs.com

# Inspect real-time Traefik access logs
docker logs -f traefik --tail 50

# Check container memory usage
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

---

## 6. Onboarding a New App or Microservice

To add a new application to the VPS infrastructure:

1. **Provision Database and Message Queue (if needed)**:
   ```bash
   cd /opt/vantroxia/infra
   ./postgres/create-app-db.sh <app_name> '<secure_db_password>'
   ./rabbitmq/create-app-vhost.sh <app_name> '<secure_mq_password>'
   ```
2. **Create Application Stack**:
   - Create directory `apps/<app_name>/` in this repo.
   - Create `docker-compose.yml` defining the service, memory limits, and Traefik routing labels.
   - Create `.env.example` documenting required environment variables.
3. **Configure Traefik Labels in `docker-compose.yml`**:
   ```yaml
   labels:
     - traefik.enable=true
     - traefik.http.routers.<app>.rule=Host(`<app-domain>.<base-domain>`)
     - traefik.http.routers.<app>.entrypoints=websecure
     - traefik.http.routers.<app>.tls.certresolver=le
     - traefik.http.routers.<app>.middlewares=secure-headers@file,api-ratelimit@file
     - traefik.http.services.<app>.loadbalancer.server.port=<container_port>
   ```
4. **Update `.github/workflows/deploy.yml`**:
   - Add `<app_name>` to the `service` options in `workflow_dispatch`.
   - Add deployment case block in the deploy script.
   - Add endpoint health check to the verification step.
5. **Set up CI Dispatch in the New App Repository**:
   - Add the `trigger-deploy` step to the app repo's GitHub Actions workflow sending `"service": "<app_name>"`.
