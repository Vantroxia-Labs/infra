# Staging rebuild on Dokploy

Replaces the hand-rolled Traefik + compose stacks (`traefik/`, `infra/`, `apps/`,
`scripts/fresh-install.sh`, `.github/workflows/deploy.yml`). Dokploy manages its own
Traefik from its UI, so there is no separate dashboard password any more.

Files:
- [`scripts/bootstrap.sh`](../scripts/bootstrap.sh): hardens a fresh Ubuntu 24.04 VPS and installs Dokploy
- [`ci-templates/deploy-staging.yml`](../ci-templates/deploy-staging.yml): app-repo workflow (build on GitHub, push to GHCR, call Dokploy)

## 0. Before you wipe

Dev environment: **no data is kept**. All databases, buckets and containers
are wiped; apps re-bootstrap their schemas on first deploy (EF Core
migrations, Spring JPA, etc.). Only secrets you can't regenerate matter.

```sh
# Pull the current .env files so you can paste them back into Dokploy as
# per-app environment (Paystack/Monnify sandbox, SES, JWT keys, GHCR token).
rsync -avm --include='*/' --include='.env*' --exclude='*' \
  root@207.180.197.64:/opt/vantroxia/ ./vantroxia-old/
```

Then **Create snapshot** in the Contabo panel as a rollback safety net
(not for data recovery — for getting the old server back if the rebuild
stalls).

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

`shared` holds the reusable infra every dev service plugs into. Create it
first so per-app projects can point at its service names on
`dokploy-network`.

| Project | Service | Type / image | Notes |
|---|---|---|---|
| shared | Postgres | Dokploy DB, `postgres:18` | one DB + role per app; scheduled backups to R2 |
| shared | Redis | Dokploy DB, `redis:7` | one logical DB (`0`, `1`, …) per app, or a prefix convention |
| shared | RabbitMQ | app, `rabbitmq:4-management-alpine` | vhost per product |
| shared | OpenObserve | app, `openobserve/openobserve:latest` | logs + traces + metrics; apps push OTLP directly, no OTEL Collector |
| aegisremit | portal-api, erp-api, admin | apps from GHCR | memory limits on each; `remit-migrator` runs first against cold DB |
| gymmate | api, web | apps from GHCR | JVM: set `-XX:MaxRAMPercentage` + limit |
| vantroxialabs | site | app from GHCR | |

- **Object storage:** Cloudflare R2 bucket per product (MinIO is gone —
  Docker Hub images removed). Only the S3 endpoint changes in app config.
  Self-hosted fallback: Garage, SeaweedFS, RustFS.
- **Observability:** OpenObserve lives in `shared`; every app sends OTLP
  logs/traces/metrics straight to it over `dokploy-network`. Dokploy's
  built-in container metrics/logs stay on for the platform layer.

### Cold-DB bootstrap (aegisremit)

The shared Postgres is empty. Before `portal-api` / `erp-api` start on
first deploy, `remit-migrator` must apply the schema. Two patterns:

- **Separate Dokploy Application** for `remit-migrator` (image
  `ghcr.io/vantroxia-labs/remit-migrator:<tag>`, command override runs the
  EF Core bundle, no exposed ports). CI deploys it first and waits for
  exit before deploying the APIs. Gives explicit, auditable runs.
- **Pre-deploy command** on `portal-api` (Advanced → Pre-deploy) that
  runs the migrator bundle. Simpler, but every portal-api deploy re-runs
  migrations (idempotent, so safe — just noisy).

Pick the separate-app pattern for clarity; the cold-start case already
needs it and later deploys reuse the same flow. Spring (`gymmate api`)
runs its own JPA migrations on boot — no separate step needed.

## 5. CI

Copy `ci-templates/deploy-staging.yml` into each app repo and set `DOKPLOY_URL`,
`DOKPLOY_API_KEY`, `DOKPLOY_APP_ID`. Remove the old `repository_dispatch` step that
targets this repo.

## 6. Backups + golden snapshot

- Dokploy → Destinations: add R2; schedule Postgres backups; enable Dokploy self-backup.
- When everything is green, take a Contabo snapshot so the next rebuild is a restore.

## After cutover

- Close port 3000 on both the Contabo firewall and UFW
  (`sudo ufw delete allow 3000/tcp`) once `deploy.vantroxialabs.com`
  resolves and HTTPS works end-to-end.
- Shred the local `./vantroxia-old/` copy of the pre-wipe `.env` files
  once every secret is pasted into Dokploy UI.
- Tag the repo `dokploy-live-v1` so future rebuilds have a clean
  reference point.

The old SSH-era scaffolding (`traefik/`, `infra/`, `apps/`,
`scripts/fresh-install.sh`, `.github/workflows/deploy.yml`) was removed
in commit `<see git log>` once the Contabo reinstall was greenlit.
