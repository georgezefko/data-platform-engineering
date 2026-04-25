# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

```bash
make up              # Full bootstrap: KinD cluster + Terraform (Argo CD) + app-of-apps
make tf-apply        # Re-run Terraform only (re-installs/upgrades Argo CD Helm release)
make argo-bootstrap  # Re-apply app-of-apps manifest only
make status          # Show Argo Application sync status + key namespaces
make reset           # Tear down cluster, wipe Terraform state, remove kubeconfig
make kind-down       # Delete KinD cluster only (keeps Terraform state)

# Port-forward helpers (run in separate terminals)
make argo-ui         # Argo CD UI at localhost:8080, prints admin password
make mage-ui         # Mage AI UI
make postgres-pf     # Postgres at localhost:5432
make kafka-connect-pf  # Kafka Connect REST API at localhost:8083
```

## Architecture

The platform follows a strict layered execution order:

```
infra/kind/kind-config.yaml
  → KinD single-node cluster ("development")
      → infra/terraform/environments/dev/
          → Helm-installs Argo CD into namespace "argocd"
              → argo/app-of-apps.yaml  (manually applied once)
                  → watches argo/apps/  (App-of-Apps pattern)
                      → individual Application CRDs → apps/*/dev/
```

**Argo CD tracks `HEAD` of the `main` branch.** Pushing to `main` triggers automated sync with `prune: true` and `selfHeal: true`.

All application workloads land in the **`develop` namespace**. In-cluster DNS follows `<service>-svc.develop.svc.cluster.local`.

## Two Deployment Patterns

### Kustomize-based (Kafka, Zookeeper, Kafka Connect, Postgres, Schema Registry)

```
apps/<service>/
  base/          ← deployment.yaml, service.yaml, (secrets.yaml, configmap.yaml), kustomization.yaml
  dev/
    kustomization.yaml   ← resources: [../base]  (add patches here for env-specific overrides)
```

The Argo Application points at `apps/<service>/dev`.

### Helm-based (Mage AI, Airbyte)

Uses Argo CD [multi-source](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/) to pull the chart from the upstream Helm repo and values from this repo:

```yaml
sources:
  - repoURL: <upstream-helm-repo>
    chart: <chart-name>
    targetRevision: "x.y.z"
    helm:
      releaseName: "<name>"
      valueFiles:
        - $values/apps/<service>/dev/values.yaml
  - repoURL: https://github.com/georgezefko/data-platform-engineering.git
    targetRevision: HEAD
    ref: values
    path: apps/<service>/dev
```

Values live in `apps/<service>/dev/values.yaml`.

## Adding a New Service

**Kustomize service:**
1. `apps/<service>/base/` — add `deployment.yaml`, `service.yaml`, `kustomization.yaml` (listing those resources)
2. `apps/<service>/dev/kustomization.yaml` — `resources: [../base]`
3. `argo/apps/<service>-application.yaml` — Argo Application pointing at `apps/<service>/dev`, namespace `develop`

**Helm service:**
1. `apps/<service>/dev/values.yaml` — chart values
2. `argo/apps/<service>-application.yaml` — multi-source Argo Application (see pattern above)

## Key Implementation Details

- **Secrets** use `stringData` (plain text) in `secrets.yaml` files — no base64 encoding required.
- **Postgres image** is `debezium/postgres:15` (not stock Postgres) because it has logical replication pre-configured for CDC.
- **Kafka Connect** uses the Debezium Connect image (`quay.io/debezium/connect:2.7`). The Debezium connector is registered via a Kubernetes `Job` with `argocd.argoproj.io/hook: PostSync` — this runs after each sync and is idempotent (skips if connector already exists).
- **Terraform state** is local (`.tfstate` in `infra/terraform/environments/dev/`). `make reset` removes it; `make tf-apply` re-creates.
- The `.kube/` directory at repo root is the kubeconfig mount point for the DevContainer — `mkdir -p .kube` must exist before `make up`.
