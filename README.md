# vantroxia-vps

Infra repo for the Vantroxia Labs dev VPS. Dokploy owns deployment;
this repo holds the VPS bootstrap script, the CI template app repos
copy, and the runbook.

## Model

- **VPS:** Contabo Cloud VPS, Ubuntu 24.04. Hardened by
  [`scripts/bootstrap.sh`](scripts/bootstrap.sh), which then installs
  Dokploy (Docker, Swarm, Traefik, Postgres, Redis).
- **Dokploy panel:** `deploy.vantroxialabs.com`. It owns Traefik,
  cert issuance, container lifecycle and env vars.
- **Shared infra project** (in Dokploy): Postgres, Redis, RabbitMQ,
  OpenObserve — reusable by every dev service on `dokploy-network`.
- **Per-app projects** (in Dokploy): `aegisremit`, `gymmate`,
  `vantroxialabs`. Each app pulls its image from GHCR; env lives in
  the Dokploy UI.
- **CI:** App repos build on GitHub, push to GHCR, then POST to
  Dokploy's `/api/application.deploy`. Template:
  [`ci-templates/deploy-staging.yml`](ci-templates/deploy-staging.yml).
  The VPS never builds anything.

## Repo layout

```
scripts/bootstrap.sh          # one-shot VPS hardening + Dokploy install
ci-templates/deploy-staging.yml  # workflow template app repos copy
docs/dokploy-rebuild.md       # full rebuild runbook
```

## Rebuilding the VPS

See [`docs/dokploy-rebuild.md`](docs/dokploy-rebuild.md) for the
step-by-step: reinstall Contabo → run `bootstrap.sh` → claim the
Dokploy panel → create the `shared` project → wire CI → cut
each app over.

## History

The pre-Dokploy SSH + hand-rolled Traefik/compose scaffolding
(`traefik/`, `infra/`, `apps/`, `scripts/fresh-install.sh`,
`.github/workflows/deploy.yml`) was removed during the Dokploy
migration. See git history before commit `c10ffa5` for the old model.
