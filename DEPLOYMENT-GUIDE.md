# AegisRemit — Complete Deployment Guide
## Everything remaining, in exact order. Do not skip steps.

---

## Architecture Overview

```
                    Internet
                       │
                  Cloudflare CDN
                       │
                   Traefik v3.1
                (TLS via Let's Encrypt)
              ┌────┬────┬────┬────┐
          Portal  ERP  SFTP  Admin  Dashboard
           API    API  API  (nginx) (Traefik)
              └────┴────┴────┘
                   │    Internal Network
           ┌──────┼──────┬──────────┐
         Redis  RabbitMQ  MinIO   OTEL Collector
                   │
           Aiven Cloud PostgreSQL (external)
```

**Services:**
- 3 x .NET 10 Web APIs (Portal, ERP, SFTP)
- 1 x React/TypeScript admin portal + landing pages (nginx)
- Traefik v3.1 (reverse proxy, TLS)
- Redis 7 (cache)
- RabbitMQ 3.13 (message broker)
- MinIO (object storage for invoices/files)
- OTEL Collector (telemetry → SigNoz later)
- Database: Aiven Cloud PostgreSQL (external, not on VPS)

---

## PHASE 1: LOCAL SETUP (your Windows machine)

### Step 1.1 — Set up SSH config for easy access

Open PowerShell and create/edit your SSH config:

```powershell
notepad C:\Users\PRECISION` 5560\.ssh\config
```

Paste this content and save:

```
Host aegisremit
    HostName 207.180.197.64
    User deploy
    IdentityFile C:\Users\PRECISION 5560\source\repos\AegisRemit\aegisremit_key_godswill
```

Test it works:

```powershell
ssh aegisremit
```

✅ You should get in without a password prompt.
✅ From now on, use `ssh aegisremit` instead of the long command.

Type `exit` to disconnect.

---

### Step 1.2 — Push infra repo to GitHub

Make sure you have already created the `infra` repo under `Vantroxia-Labs` on GitHub.

In PowerShell, go to your local Infra folder:

```powershell
cd "C:\Users\PRECISION 5560\source\repos\AegisRemit\Infra"
```

Initialize and push:

```powershell
git init
git remote add origin https://github.com/Vantroxia-Labs/infra.git
git add .
git commit -m "Initial infra: docker-compose, CI/CD, setup scripts"
git branch -M main
git push -u origin main
```

✅ Verify at https://github.com/Vantroxia-Labs/infra — all files should be there.

---

## PHASE 2: CLOUDFLARE DNS

### Step 2.1 — Get Cloudflare nameservers

1. Go to https://dash.cloudflare.com
2. Click on `aegisremit.ng`
3. If you haven't completed activation, Cloudflare shows you 2 nameservers like:
   - `anna.ns.cloudflare.com`
   - `bob.ns.cloudflare.com`
4. Copy both nameserver values

### Step 2.2 — Update nameservers at Whogohost

1. Go to https://app.go54.com
2. Domain → My Domains → aegisremit.ng → Manage Domain
3. Under Nameservers → select "Custom Nameservers"
4. Paste Cloudflare nameserver 1 into "Nameserver 1"
5. Paste Cloudflare nameserver 2 into "Nameserver 2"
6. Click "Update Nameservers"

✅ Wait 5–60 minutes for propagation.
✅ Cloudflare dashboard will show "Active" status once propagated.

### Step 2.3 — Add DNS records in Cloudflare

Go to Cloudflare → aegisremit.ng → DNS → Records.
Click "Add record" for each row below:

| # | Type  | Name       | Content        | Proxy  |
|---|-------|------------|----------------|--------|
| 1 | A     | @          | 207.180.197.64 | Off    |
| 2 | A     | app        | 207.180.197.64 | Off    |
| 3 | A     | api        | 207.180.197.64 | Off    |
| 4 | A     | erp        | 207.180.197.64 | Off    |
| 5 | A     | sftp-api   | 207.180.197.64 | Off    |
| 6 | A     | traefik    | 207.180.197.64 | Off    |
| 7 | A     | rabbitmq   | 207.180.197.64 | Off    |
| 8 | A     | minio      | 207.180.197.64 | Off    |
| 9 | CNAME | www        | aegisremit.ng  | Off    |

Proxy "On" = orange cloud icon.
Proxy "Off" = gray cloud icon.

**Start with all records grey (Proxy Off)** for the first deploy — Traefik's Let's Encrypt DNS challenge works regardless, and orange cloud in front of Traefik can interfere with websockets, long uploads, and cert issuance troubleshooting. Once the stack is stable, you can flip `@`, `www`, and `app` to orange for CDN caching on the marketing pages.

✅ 9 records total when done.

### Step 2.4 — Create Cloudflare API token (for SSL certificates)

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click "Create Token"
3. Click "Use template" next to "Edit zone DNS"
4. Under Permissions: Zone → DNS → Edit (should be pre-filled)
5. Under Zone Resources: Include → Specific zone → aegisremit.ng
6. Click "Continue to summary" → "Create Token"
7. **COPY THE TOKEN NOW** — you cannot see it again

Save it somewhere safe temporarily. We'll use it in Step 3.3.

### Step 2.5 — Configure Cloudflare SSL settings

1. Go to Cloudflare → aegisremit.ng → SSL/TLS → Overview
2. Set encryption mode to **Full (strict)**
3. Go to SSL/TLS → Edge Certificates
4. Turn on "Always Use HTTPS"
5. Set "Minimum TLS Version" to **1.2**

✅ SSL is configured. Actual certs come from Traefik + Let's Encrypt.

---

## PHASE 3: VPS DEPLOYMENT

### Step 3.0 — VPS bootstrap (skip if already done)

If you started from a fresh Ubuntu 24.04 image, run the idempotent bootstrap script first. It installs Docker, creates the `deploy` user with your CI public key, hardens sshd, configures ufw (22/80/443), enables fail2ban + unattended-upgrades, creates `/opt/aegisremit`, the `aegisremit-web` docker network, and a 2 GB swap file.

```bash
# Upload the script to the VPS (from your Windows machine)
scp Infra/scripts/bootstrap-vps.sh root@207.180.197.64:/tmp/

# SSH as root and run it with your CI public key as the argument
ssh root@207.180.197.64
bash /tmp/bootstrap-vps.sh "ssh-ed25519 AAAA...your-ci-public-key"
```

The script is safe to re-run — it detects existing Docker, deploy user, swap, and network and skips them.

✅ If your VPS already has Docker, git, and a `deploy` user (as shown by `docker -v` and `whoami`), you can skip this step and go straight to 3.1.

### Step 3.1 — Reboot VPS (pending kernel update)

```powershell
ssh aegisremit
```

Then:

```bash
sudo reboot
```

Wait 30 seconds. Reconnect:

```powershell
ssh aegisremit
```

✅ "System restart required" message should be gone.

### Step 3.2 — Clone infra repo to VPS

```bash
cd /opt/aegisremit
git clone https://github.com/Vantroxia-Labs/infra.git .
```

If the repo is private, use a PAT:

```bash
git clone https://YOUR_GITHUB_PAT@github.com/Vantroxia-Labs/infra.git .
```

Verify files are there:

```bash
ls -la
```

✅ You should see: docker-compose.yml, .env.example, config/, setup/, scripts/, etc.

### Step 3.3 — Create .env file with real secrets

```bash
cp .env.example .env
nano .env
```

Fill in every value. The basic values first:

```
DOMAIN=aegisremit.ng
IMAGE_TAG=latest
ACME_EMAIL=davidgodswill@gmail.com
CF_DNS_API_TOKEN=<paste token from Step 2.4>
```

Generate the Traefik dashboard password:

```bash
sudo apt install -y apache2-utils
TRAEFIK_PASS=$(htpasswd -nB admin | sed 's/\$/\$\$/g')
echo "TRAEFIK_DASHBOARD_AUTH=$TRAEFIK_PASS"
```

Copy that output line into .env.

Generate strong passwords (run each one, copy output into .env):

```bash
echo "REDIS_PASSWORD=$(openssl rand -base64 24)"
echo "RABBITMQ_PASSWORD=$(openssl rand -base64 24)"
echo "MINIO_ROOT_PASSWORD=$(openssl rand -base64 24)"
```

Generate the JWT signing secret and payload encryption key/IV (consumed by Portal.API, ERP.API, SFTP.API):

```bash
echo "JWT_SECRET_KEY=$(openssl rand -base64 48)"
echo "ENCRYPTION_KEY=$(openssl rand -base64 32)"
echo "ENCRYPTION_IV=$(openssl rand -base64 16)"
```

Your final .env should look like:

```
DOMAIN=aegisremit.ng
IMAGE_TAG=latest
ACME_EMAIL=davidgodswill@gmail.com
CF_DNS_API_TOKEN=abc123...your-cloudflare-token
TRAEFIK_DASHBOARD_AUTH=admin:$$2y$$05$$...hashed-password
AIVEN_CONNECTION_STRING=Host=your-host.aivencloud.com;Port=12345;Database=aegisremit;Username=avnadmin;Password=YOUR_AIVEN_PASSWORD;SslMode=Require;Trust Server Certificate=true
REDIS_PASSWORD=<generated-password-1>
RABBITMQ_USER=aegisremit
RABBITMQ_PASSWORD=<generated-password-2>
MINIO_ROOT_USER=aegisremit
MINIO_ROOT_PASSWORD=<generated-password-3>
JWT_SECRET_KEY=<generated-48-byte-base64>
JWT_ISSUER=https://api.aegisremit.ng
JWT_AUDIENCE=aegisremit
ENCRYPTION_KEY=<generated-32-byte-base64>
ENCRYPTION_IV=<generated-16-byte-base64>
```

Save and exit nano (Ctrl+X → Y → Enter), then lock permissions:

```bash
chmod 600 .env
```

✅ Verify: `cat .env` — all values filled, no CHANGE_ME remaining.

### Step 3.4 — Verify the OTEL collector config

The config file should be in the infra root directory:

```bash
cat otel-collector-config.yaml
```

✅ Should show the OTLP receiver/exporter config.

### Step 3.5 — Start infrastructure services FIRST

Don't start everything at once. Start the dependencies first:

```bash
docker compose up -d traefik redis rabbitmq minio otel-collector
```

Wait 30 seconds, then check all are healthy:

```bash
docker compose ps
```

✅ All 5 services should show "running" or "healthy".

If any service shows "restarting" or "exited", check logs:

```bash
docker compose logs <service-name>
```

### Step 3.6 — Verify Traefik + SSL

Check if Traefik can reach Cloudflare for SSL:

```bash
docker compose logs traefik | grep -i "acme\|certificate\|error"
```

Test the Traefik dashboard:

```bash
curl -k https://traefik.aegisremit.ng
```

✅ Should return HTML (or 401 Unauthorized — that's correct, it's BasicAuth protected).

If you get connection errors, wait a few minutes for DNS propagation and SSL cert generation.

### Step 3.7 — Verify service connections

```bash
# Load .env into the shell so variables are available
set -a && source .env && set +a

# Redis (uses -f2- to handle base64 padding "=" in the password)
docker exec aegisremit-redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping
# Expected: PONG

# RabbitMQ
docker exec aegisremit-rabbitmq rabbitmq-diagnostics -q check_running
# Expected: (no error, exit code 0)

# MinIO — readiness on the internal API port
docker exec aegisremit-minio curl -fsS http://localhost:9000/minio/health/live
# Expected: HTTP 200 (silent on success)
```

✅ All three should respond positively.

### Step 3.8 — Create MinIO buckets

Access MinIO console at https://minio.aegisremit.ng or via CLI inside the container. Docker `exec` does NOT inherit host shell variables, so you must pass them explicitly via `-e`:

```bash
set -a && source .env && set +a

docker exec -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD aegisremit-minio \
    mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

docker exec aegisremit-minio mc mb --ignore-existing local/invoices
docker exec aegisremit-minio mc mb --ignore-existing local/uploads
docker exec aegisremit-minio mc mb --ignore-existing local/documents
```

✅ 3 buckets created.

### Step 3.8b — Run database migrations against Aiven (one-time, from your dev machine)

**Do this BEFORE Step 3.9.** Portal.API's auto-migrate on startup is gated on `ASPNETCORE_ENVIRONMENT=Development`, but in production the containers run as `Production`, so migrations will never be applied automatically. You must apply them once by hand from your local dev machine, pointed at the Aiven connection string.

On your Windows dev machine:

```powershell
cd "C:\Users\PRECISION 5560\source\repos\AegisRemit\Remit\src\Presentation\AegisEInvoicing.Portal.API"

# Set the same Aiven connection string that's in /opt/aegisremit/.env on the VPS
$env:ConnectionStrings__DefaultConnection = "Host=your-host.aivencloud.com;Port=12345;Database=aegisremit;Username=avnadmin;Password=YOUR_AIVEN_PASSWORD;SslMode=Require;Trust Server Certificate=true"

# Apply all pending migrations (requires dotnet-ef tool: dotnet tool install -g dotnet-ef)
dotnet ef database update --project ../../Infrastructure/AegisEInvoicing.Infrastructure
```

✅ You should see `Done.` with no errors. Verify in the Aiven console that the tables were created.

> **Repeat this step whenever a new EF migration is added to Portal.API before deploying the update.** If you ever hit a `relation "…" does not exist` error in production logs, that's the signal you forgot this step.

### Step 3.9 — Start application services (if images exist)

If you haven't built and pushed Docker images yet, SKIP this step.

If images are available:

```bash
docker compose up -d portal-api erp-api sftp-api admin
docker compose ps
```

---

## PHASE 4: CI/CD SETUP

### Step 4.1 — Generate a deploy SSH key

On your LOCAL machine (PowerShell):

```powershell
ssh-keygen -t ed25519 -C "aegisremit-ci-deploy" -f aegisremit_deploy_key -N '""'
```

This creates two files:
- `aegisremit_deploy_key` (private — goes to GitHub)
- `aegisremit_deploy_key.pub` (public — goes to VPS)

### Step 4.2 — Add deploy key public key to VPS

```powershell
# Display the public key
cat aegisremit_deploy_key.pub
```

Copy the output. Then SSH to VPS:

```powershell
ssh aegisremit
```

```bash
echo "ssh-ed25519 AAAA...the-full-public-key" >> ~/.ssh/authorized_keys
exit
```

✅ Verify CI key works:

```powershell
ssh -i aegisremit_deploy_key deploy@207.180.197.64
```

### Step 4.3 — Create GitHub PAT for cross-repo dispatch

1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Name: `aegisremit-ci`
4. Scopes: check `repo` and `write:packages`
5. Click "Generate token"
6. **COPY THE TOKEN**

### Step 4.4 — Add secrets to infra repo

Go to https://github.com/Vantroxia-Labs/infra/settings/secrets/actions

Add these 3 secrets:

| Secret Name   | Value                                         |
|---------------|-----------------------------------------------|
| VPS_HOST      | 207.180.197.64                                |
| VPS_SSH_KEY   | Contents of `aegisremit_deploy_key` (private) |
| GHCR_TOKEN    | The GitHub PAT from Step 4.3                  |

### Step 4.5 — Add secrets to remit repo

Go to https://github.com/Vantroxia-Labs/remit/settings/secrets/actions

Add this 1 secret:

| Secret Name        | Value                        |
|--------------------|------------------------------|
| INFRA_DEPLOY_TOKEN | The GitHub PAT from Step 4.3 |

### Step 4.6 — Add secrets to admin repo

Go to https://github.com/Vantroxia-Labs/admin/settings/secrets/actions

Add this 1 secret:

| Secret Name        | Value                        |
|--------------------|------------------------------|
| INFRA_DEPLOY_TOKEN | The GitHub PAT from Step 4.3 |

### Step 4.7 — Copy CI workflow files to repos

Copy from the infra repo to the correct locations:

**For remit repo:**
- Copy `ci-remit.yml` → `Vantroxia-Labs/remit/.github/workflows/ci.yml`
- Copy `Dockerfile.portal-api` → `Vantroxia-Labs/remit/Dockerfile.portal-api`
- Copy `Dockerfile.erp-api` → `Vantroxia-Labs/remit/Dockerfile.erp-api`
- Copy `Dockerfile.sftp-api` → `Vantroxia-Labs/remit/Dockerfile.sftp-api`

**For admin repo:**
- Copy `ci-admin.yml` → `Vantroxia-Labs/admin/.github/workflows/ci.yml`
- Copy `Dockerfile.admin` → `Vantroxia-Labs/admin/Dockerfile`

Commit and push to each repo.

### Step 4.8 — Test the CI/CD pipeline

Make a small change in the `remit` repo and push to main:

```bash
git commit --allow-empty -m "test: trigger CI pipeline"
git push origin main
```

Watch the pipeline:
1. Go to https://github.com/Vantroxia-Labs/remit/actions → CI should run
2. After CI finishes → https://github.com/Vantroxia-Labs/infra/actions → Deploy should trigger
3. SSH to VPS and verify: `docker compose ps`

✅ All services running with new images.

---

## PHASE 5: VERIFICATION CHECKLIST

Run these from your local machine:

```powershell
# DNS resolves
nslookup portal.aegisremit.ng
nslookup erp.aegisremit.ng
nslookup sftp-api.aegisremit.ng
nslookup app.aegisremit.ng
nslookup minio.aegisremit.ng

# SSL + API health
curl https://portal.aegisremit.ng/health
curl https://erp.aegisremit.ng/health
curl https://sftp-api.aegisremit.ng/health

# Admin portal loads
curl -I https://app.aegisremit.ng
curl -I https://aegisremit.ng
```

Run these from the VPS:

```bash
# All containers running
docker compose ps

# No restart loops
docker compose ps --format "{{.Name}} {{.Status}}" | grep -i restart

# Disk usage is reasonable
df -h /
docker system df
```

---

## SUMMARY OF ACCOUNTS & CREDENTIALS

Keep this list updated:

| Service    | URL / Location                          | Notes                       |
|------------|-----------------------------------------|-----------------------------|
| VPS        | 207.180.197.64 (ssh aegisremit)         | Contabo, 4vCPU/8GB/75GB    |
| Cloudflare | dash.cloudflare.com                     | DNS + CDN                   |
| Domain     | aegisremit.ng (Whogohost)               | Renews Nov 2026             |
| GitHub     | github.com/Vantroxia-Labs               | remit, admin, infra         |
| GHCR       | ghcr.io/vantroxia-labs/*                | Docker images               |
| Aiven      | console.aiven.io                        | PostgreSQL managed DB       |
| Secrets    | /opt/aegisremit/.env on VPS             | NEVER commit to git         |

### Subdomain → Service Map

| Subdomain                    | Service      | Port |
|------------------------------|--------------|------|
| aegisremit.ng / www          | admin        | 80   |
| app.aegisremit.ng            | admin        | 80   |
| portal.aegisremit.ng         | portal-api   | 8080 |
| erp.aegisremit.ng            | erp-api      | 8080 |
| sftp-api.aegisremit.ng       | sftp-api     | 8080 |
| minio.aegisremit.ng          | minio        | 9001 |
| rabbitmq.aegisremit.ng       | rabbitmq     | 15672|
| traefik.aegisremit.ng        | traefik      | 8080 |

---

## WHAT'S NOT DONE YET (do later)

- [ ] SigNoz observability (deploy standalone, OTEL collector already configured)
- [ ] Transactional email (MX records + AWS SES or similar)
- [ ] vantroxialabs.com landing page
- [ ] Contabo firewall rules (use their free firewall feature)
- [ ] GitHub branch protection rules on main
