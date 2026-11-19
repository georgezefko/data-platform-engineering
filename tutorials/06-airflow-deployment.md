# Deploying Airflow on the Local Platform (WIP)

> **Work in progress.** Dev deploys and runs healthy. First login, DAG runs and prod have not been verified yet. See [Status](#status) at the bottom.

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
- Postgres's `init.sql` only runs on an empty volume, so it can't add databases to a cluster that already exists. A Job in the Postgres app (`apps/postgres/base/airflow-db-job.yaml`) creates the two databases instead, and skips any that already exist.

> **Gotcha:** this was first written as a PostSync hook, and it never ran. Argo doesn't count hooks when it compares Git with the cluster. `postgres-app` was already Synced, so adding the hook created no diff, auto-sync never started, and the hook never fired. With no databases, the Airflow migration job failed until it hit its backoff limit. As a plain resource, the missing Job makes the app OutOfSync, so Argo creates it.

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

Where they live, and when to re-run the script:

- **Only in the kind cluster.** They are plain Kubernetes Secrets, not stored in Google Secret Manager, Git or Argo. `airflow-gcp-adc` is a copy of your local ADC file, and `airflow-keys` exists nowhere else.
- **After `make reset` or `make kind-down`**, both are gone: run `make airflow-secrets` after the next `make up`. The new random keys are fine, because the Airflow databases went with the cluster, so nothing is still encrypted with the old fernet key.
- **After `gcloud auth application-default login`**, your ADC file changes: re-run `make airflow-secrets` to refresh the copy. It leaves `airflow-keys` alone.
- **Dev and prod have different keys.** The script generates `airflow-keys` separately per namespace. This matters for the UI login, see [step 5](#5-open-the-ui).

To keep them outside the cluster (to survive rebuilds or share across clusters), the usual next step is the External Secrets Operator syncing from Google Secret Manager. For a local kind setup, the script is enough.

### Probes sized for a crowded kind node

Airflow 3 is slow to start: every component imports all of Airflow, and the scheduler also imports the DAGs' libraries (Cosmos/dbt). On one kind node shared with the rest of the platform, the chart's default probes killed the pods before they were up. The api-server failed its startup probe with `connection refused` and exited with code 143. The scheduler failed with `No alive jobs found`. Each restart booted Airflow again, which kept the node's CPU high and made the next start even slower.

`apps/airflow-helm/common/values.yaml` gives both components more room:

```yaml
config:
  api:
    workers: 1  # default 4: each worker imports all of Airflow at startup
apiServer:
  startupProbe:
    periodSeconds: 10
    timeoutSeconds: 20
    failureThreshold: 30  # up to 5 min to come up
scheduler:
  startupProbe:  # default gave up after ~1-2 min; boot (cosmos/dbt imports) takes longer
    periodSeconds: 10
    timeoutSeconds: 60
    failureThreshold: 30
  livenessProbe:
    initialDelaySeconds: 30
    periodSeconds: 60
    timeoutSeconds: 60
    failureThreshold: 5
```

While a rollout is in progress, the old pods keep crash-looping until the new ones are Ready. That's normal: judge by the newest pods.

### Image vs. bundles: what a release changes

- **The image is the runtime:** Airflow, Python packages, providers. Dev and prod each pin their own tag. Every task pod uses that image.
- **Bundles are the DAG code**, pulled from Git. Airflow 3 records the bundle version a DAG run started on, so a push mid-run doesn't mix old and new code.

A DAG-only release changes a team's `tracking_ref` and nothing else. A release that needs a new or upgraded Python package also needs a new image: build it, load it into kind, bump the tag (dev first, then prod), and only then move prod's `tracking_ref`. Otherwise the DAG fails with an import error. Prod has one image for every team, so an image bump is a platform change: keep it backward compatible.

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

In both `develop` and `prod`, this creates the namespace if it's missing, applies `airflow-gcp-adc` from your ADC file (re-running refreshes it), and creates `airflow-keys` only if it doesn't exist yet. Use a different ADC file with `ADC=/path/to/file.json make airflow-secrets`; give prod (its own GCP project) separate credentials with `PROD_ADC=/path/to/prod.json`.

### 4. Deploy through Argo CD

Argo CD tracks `main`, so changes only reach the cluster once they're merged. Then:

```bash
make argo-bootstrap
```

Running everything at once (Kafka, StarRocks, Airbyte and both Airflow environments) is heavy for one kind node. To run only what Airflow dev needs:

```bash
make argo-bootstrap APPS="postgres airflow-dev"
```

`APPS` also works with `make up`, and `make argo-bootstrap` with no `APPS` brings everything back. Names match files in `argo/apps/` whose name contains them, and dependencies are not added for you: Airflow needs `postgres`. Under the hood, `scripts/argo-apps.sh` sets a `directory.include` filter on the app-of-apps. Every child Application carries the `resources-finalizer.argocd.argoproj.io` finalizer, so a removed app's workloads are deleted too. The Postgres PVC has `argocd.argoproj.io/sync-options: Delete=false`, so turning Postgres off keeps its data.

> **Gotcha:** the finalizer only works if it is already on the Application when the app is removed. The first time, `APPS=` ran right after the merge, before Argo had synced the finalizers onto the child apps. Their Applications were deleted, but the pods kept running, orphaned. The fix was to run `make argo-bootstrap` (all apps), wait until every app showed the finalizer, then filter again:
>
> ```bash
> kubectl get applications -n argocd -o custom-columns=NAME:.metadata.name,FINALIZERS:.metadata.finalizers,SYNC:.status.sync.status
> ```

```bash
make status
```

On sync, the Postgres app's `airflow-db-init` Job creates `airflow_dev` and `airflow_prod`, the migration job runs as a Sync hook, and the admin user is created in PostSync. If the migration ran out of retries before the databases existed, re-sync `airflow-dev` and `airflow-prod`: automated sync doesn't retry a failed sync on the same commit.

### 5. Open the UI

```bash
make airflow-ui ENV=dev
```

Dev is at http://127.0.0.1:8081, prod (`ENV=prod`) at http://localhost:8082. Log in as `admin` / `admin`.

> **Why two different hosts?** Browsers don't separate cookies by port. With both UIs on `localhost`, logging in to prod replaced dev's login token. Dev can't verify a token signed with prod's key, so it kept sending you back to the login page well before the 24-hour token expiry (`[api_auth] jwt_expiration_time = 86400`). `127.0.0.1` and `localhost` count as different sites, so each keeps its own cookies.

If it fails with `bind: address already in use`, an earlier port-forward is still running, often in another terminal. Stop it and retry:

```bash
pkill -f "port-forward svc/airflow-api-server"
```

If something else owns the port, `lsof -i :8081` shows what.

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
- [x] Metadata databases created by a Job in the Postgres app (plain resource, not a hook)
- [x] Image loading into kind (`make airflow-image`, with the multi-arch fix)
- [x] Secrets for GCP credentials and Airflow keys (`make airflow-secrets`)
- [x] Merged to `main`; `airflow-dev` syncs and all pods are healthy
- [x] Probes and API workers sized for a shared kind node
- [x] `APPS=` to run only some apps

Not done yet:
- [ ] First login and DAG bundles visible in the UI
- [ ] Run a DAG end to end against BigQuery
- [ ] Bring up `airflow-prod` and confirm it's healthy
- [ ] Confirm the migration hook doesn't race the database Job on a fresh cluster
- [ ] Check CPU use once stable; tune DAG parsing if the DAG processor dominates
