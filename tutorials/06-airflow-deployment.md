# Deploying Airflow on the Local Platform (WIP)

> **Work in progress.** This covers what is built on the `feat/airflow` branch so far. The Argo CD sync, first login and running a DAG end to end have not been verified yet. See [Status](#status) at the bottom.

This tutorial adds Apache Airflow 3 to the platform as two environments, **dev** and **prod**, both deployed by Argo CD from the official Helm chart. DAGs are not stored in this repo or baked into the image: they live in a separate repo, [`airflow-monorepo`](https://github.com/georgezefko/airflow-monorepo), and Airflow pulls them at runtime as **Git DAG bundles**, one per team.

## How it fits in the platform

```
airflow-monorepo (GitHub)
  ├── CI builds image ──▶ Artifact Registry: airflow:<version>-<sha>
  │                              │  make airflow-image (pull + load into kind)
  │                              ▼
  └── teams/*/dags ─────▶ Airflow DAG processor (GitDagBundle, one per team)

argo/apps/airflow-dev-application.yaml   ─▶ namespace develop  (Helm chart 1.22.0)
argo/apps/airflow-prod-application.yaml  ─▶ namespace prod     (Helm chart 1.22.0)
                                               │
                                               ▼
                          platform Postgres (develop): databases airflow_dev / airflow_prod
```

| Piece | Where |
|---|---|
| Argo CD apps | `argo/apps/airflow-dev-application.yaml`, `argo/apps/airflow-prod-application.yaml` |
| Shared chart values | `apps/airflow-helm/common/values.yaml` |
| Per-env values (image tag, DB, DAG bundles) | `apps/airflow-helm/dev/values.yaml`, `apps/airflow-helm/prod/values.yaml` |
| Metadata DB creation | `apps/postgres/base/airflow-db-job.yaml` |
| Helper scripts | `scripts/airflow-image.sh`, `scripts/airflow-secrets.sh`, `scripts/airflow-ui.sh` |

---

## Design choices

### Two environments from one chart

Both Argo apps use the same multi-source pattern as Mage and Airbyte. The chart comes from `https://airflow.apache.org` and the values come from this repo, layered `common` then `dev` or `prod`:

```yaml
sources:
  - repoURL: "https://airflow.apache.org"
    chart: airflow
    targetRevision: "1.22.0"
    helm:
      releaseName: "airflow"
      valueFiles:
        - $values/apps/airflow-helm/common/values.yaml
        - $values/apps/airflow-helm/dev/values.yaml
  # values only (no path): with a path Argo would also apply the folder's files as manifests
  - repoURL: "https://github.com/georgezefko/data-platform-engineering.git"
    targetRevision: HEAD
    ref: values
```

### Executor and metadata database

- **KubernetesExecutor**: every task runs in its own pod, so no Celery workers or Redis are needed.
- **No bundled Postgres** (`postgresql.enabled: false`). Airflow uses the platform Postgres in `develop` (`postgres.develop.svc.cluster.local`), with one database per environment: `airflow_dev` and `airflow_prod`.
- Postgres's `init.sql` only runs on an empty volume, so it can't add databases to a cluster that already exists. A PostSync Job (`apps/postgres/base/airflow-db-job.yaml`) creates the two databases instead, and skips any that already exist.

### Helm hooks as Argo sync hooks

Argo CD does not run Helm hooks the way Helm does, so the chart's migration and user-creation jobs are switched over to Argo hooks:

```yaml
migrateDatabaseJob:
  useHelmHooks: false
  jobAnnotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
createUserJob:
  useHelmHooks: false
  jobAnnotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

### DAGs as Git bundles

Each team's DAG folder in `airflow-monorepo` is a separate bundle. Promoting a release means changing `tracking_ref` for that team, nothing else:

- **dev** tracks `main` for every team, so a merge in `airflow-monorepo` goes live with no change in this repo.
- **prod** pins each team to a release tag (for example `sales-v1.0.1`). Teams without a tag yet still track `main`.

```yaml
dagProcessor:
  dagBundleConfigList:
    - name: sales
      classpath: airflow.providers.git.bundles.git.GitDagBundle
      kwargs: {repo_url: "https://github.com/georgezefko/airflow-monorepo.git", tracking_ref: sales-v1.0.1, subdir: teams/sales/dags}
```

### Image: loaded into kind, never pulled

The image is built by `airflow-monorepo` CI and pushed to Google Artifact Registry as `airflow:<airflow-version>-<git-sha>` (currently `3.3.2-ed27682`). Registry tokens last only an hour, so the cluster never pulls the image itself: it is loaded into the kind node ahead of time, and the chart uses `pullPolicy: IfNotPresent`.

### Secrets outside git

Two Secrets are created by a script rather than committed. Argo doesn't manage them, so `prune` leaves them alone:

- **`airflow-gcp-adc`**: your gcloud Application Default Credentials, mounted at `/opt/gcp/adc.json` in every component and task pod (`GOOGLE_APPLICATION_CREDENTIALS`), so DAGs can reach BigQuery.
- **`airflow-keys`**: the fernet, API and JWT keys. If the chart generated them, Argo would rotate them on every sync, and a new fernet key would make stored connections unreadable. The script creates them once and never rotates them.

---

## Step by step

All commands run from the devcontainer, with the cluster already up (`make up`).

### 1. Log in to Google Cloud

```bash
gcloud auth login
```

```bash
gcloud auth application-default login
```

The first login lets Docker pull from Artifact Registry. The second writes the ADC file that the secrets step copies into the cluster.

### 2. Load the Airflow image into kind

```bash
make airflow-image
```

With no `TAG`, this loads every tag referenced in the dev and prod values files. To load one tag:

```bash
make airflow-image TAG=3.3.2-ed27682
```

The script pulls the image, then streams it into each kind node:

```bash
docker save "$IMAGE:$tag" | docker exec -i "$node" ctr --namespace=k8s.io images import --snapshotter=overlayfs -
```

> **Why not `kind load docker-image`?** It imports with `--all-platforms`. The image is multi-arch, and Docker's containerd image store only downloads the local platform's layers, so the import fails with `ctr: content digest sha256:...: not found`. Importing without `--all-platforms` loads only the platform that is present. If `docker save` itself complains about missing content, add `--platform linux/arm64` (or `linux/amd64`) to it.

### 3. Create the secrets

```bash
make airflow-secrets
```

In both `develop` and `prod`, this creates the namespace if it's missing, applies `airflow-gcp-adc` from your ADC file (re-running refreshes it), and creates `airflow-keys` only if it doesn't exist yet. Use a different ADC file with `ADC=/path/to/file.json make airflow-secrets`.

### 4. Deploy through Argo CD

Argo CD tracks `main`, so the Airflow apps only appear after `feat/airflow` is merged. Then:

```bash
make argo-bootstrap
```

```bash
make status
```

On sync, the Postgres app's PostSync Job creates `airflow_dev` and `airflow_prod`, the migration job runs as a Sync hook, and the admin user is created in PostSync.

### 5. Open the UI

```bash
make airflow-ui ENV=dev
```

Dev is at http://localhost:8081, prod (`ENV=prod`) at http://localhost:8082. Log in as `admin` / `admin`.

---

## Shipping a new image

1. CI in `airflow-monorepo` pushes a new `airflow:<version>-<sha>`.
2. Bump `images.airflow.tag` in `apps/airflow-helm/dev/values.yaml`.
3. Run `make airflow-image` so the new tag is on the kind node **before** Argo rolls the pods. Otherwise they fail with `ErrImageNeverPull` or `ImagePullBackOff`.
4. Push. Promote to prod later by bumping the tag in `apps/airflow-helm/prod/values.yaml` the same way.

---

## Status

Done:
- [x] Argo apps for dev and prod, shared and per-env values
- [x] Metadata databases created by a PostSync Job
- [x] Image loading into kind (`make airflow-image`, with the multi-arch fix)
- [x] Secrets for GCP credentials and Airflow keys (`make airflow-secrets`)

Not done yet:
- [ ] Merge `feat/airflow` to `main` and confirm both apps sync healthy
- [ ] Confirm the migration hook doesn't race the database Job on a fresh cluster
- [ ] First login and DAG bundles visible in the UI
- [ ] Run a DAG end to end against BigQuery
