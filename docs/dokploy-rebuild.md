# Staging rebuild on Dokploy

Replaces the hand-rolled Traefik + compose stacks (`traefik/`, `infra/`, `apps/`,
`scripts/fresh-install.sh`, `.github/workflows/deploy.yml`). Dokploy manages its own
Traefik from its UI, so there is no separate dashboard password any more.

Files:
- [`scripts/bootstrap.sh`](../scripts/bootstrap.sh): hardens a fresh Ubuntu 24.04 VPS and installs Dokploy
- [`ci-templates/deploy-staging.yml`](../ci-templates/deploy-staging.yml): app-repo workflow (build on GitHub, push to GHCR, call Dokploy)

## 0. Before you wipe

```sh
# configs + secrets (Paystack/Monnify sandbox, SES, JWT keys)
rsync -avm --include='*/' --include='*.yml' --include='*.yaml' --include='.env*' --exclude='*' \
  root@207.180.197.64:/opt/vantroxia/ ./vantroxia-old/

# database contents, if any staging data is worth keeping
ssh root@207.180.197.64 'docker exec postgres sh -c "pg_dumpall -U \$POSTGRES_USER"' | gzip > vantroxia-old/pg_dumpall.sql.gz
```

Then **Create snapshot** in the Contabo panel as a safety net.

## 1. Reinstall + firewall

- Contabo ⋮ → Reinstall → Ubuntu 24.04, **no** Docker app, paste your SSH public key.
- Contabo Firewall tab: allow 22, 80, 443; allow 3000 only from your IP.
  (Docker-published ports bypass UFW; this firewall is the one that guards containers.)

## 2. Bootstrap

```sh
scp scripts/bootstrap.sh root@207.180.197.64:/root/
ssh root@207.180.197.64 'ADMIN_USER=godswill bash /root/bootstrap.sh'   # or run it interactively to set a sudo password
```

Confirm `ssh godswill@207.180.197.64` + `sudo -v` works from a second terminal before closing the root session.

## 3. Claim and lock down Dokploy

1. Open `http://207.180.197.64:3000` immediately, create the admin, enable 2FA.
2. Cloudflare, DNS-only (grey cloud) A records → `207.180.197.64`:
   `deploy.vantroxialabs.com`, `*.staging.vantroxialabs.com`.
   Other zones (e.g. `aegisremit.ng`) need their own records.
3. Settings → Web Server → set `deploy.vantroxialabs.com`, Let's Encrypt, HTTPS on.
4. Only after HTTPS works:
   `docker service update --publish-rm "published=3000,target=3000,mode=host" dokploy`
   and remove 3000 from the Contabo firewall and UFW (`sudo ufw delete allow 3000/tcp`).

## 4. Services

| Project | Service | Type / image | Notes |
|---|---|---|---|
| shared | Postgres | Dokploy DB, `postgres:18` | match the old major so `pg_dumpall` restores cleanly; scheduled backups to R2 |
| shared | Redis | Dokploy DB, `redis:7` | |
| shared | RabbitMQ | app, `rabbitmq:4-management-alpine` | vhost per product |
| aegisremit | portal-api, erp-api, admin | apps from GHCR | memory limits on each |
| gymmate | api, web | apps from GHCR | JVM: set `-XX:MaxRAMPercentage` + limit |
| vantroxialabs | site | app from GHCR | |

- **MinIO is gone** (Docker Hub images removed). Use a Cloudflare R2 bucket; only the S3 endpoint changes.
  Self-hosted alternatives: Garage, SeaweedFS, RustFS.
- **Monitoring:** Dokploy's built-in metrics/logs. Bring OpenObserve back only if you need traces;
  apps can send OTLP straight to it (no separate OTEL Collector).

## 5. CI

Copy `ci-templates/deploy-staging.yml` into each app repo and set `DOKPLOY_URL`,
`DOKPLOY_API_KEY`, `DOKPLOY_APP_ID`. Remove the old `repository_dispatch` step that
targets this repo.

## 6. Backups + golden snapshot

- Dokploy → Destinations: add R2; schedule Postgres backups; enable Dokploy self-backup.
- When everything is green, take a Contabo snapshot so the next rebuild is a restore.

## After cutover

Delete `traefik/`, `infra/`, `apps/`, `scripts/fresh-install.sh` and
`.github/workflows/deploy.yml` from this repo (kept until the new server is live, for reference).
