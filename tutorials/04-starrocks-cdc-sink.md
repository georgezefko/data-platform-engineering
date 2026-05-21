# Adding StarRocks as a CDC Sink on Local Kubernetes

This tutorial extends the platform from Tutorial 3 by adding **StarRocks** — a real-time analytical database that will be the destination for the Debezium CDC stream. By the end you will have a single-node StarRocks cluster (1 FE + 1 BE) running in the same Kubernetes cluster, managed end-to-end by Argo CD, with a working MySQL client connection.

## What is StarRocks?

StarRocks is a high-performance OLAP database, MySQL-protocol compatible, designed for sub-second analytics on large datasets. It has two main process types:

- **FE (Frontend)** — metadata, query planning, MySQL protocol on port `9030`, HTTP dashboard on port `8030`.
- **BE (Backend)** — tablet storage and query execution, ports `8040` (HTTP) and `9060` (BE RPC).

For CDC, StarRocks has a feature called **Routine Load** that consumes directly from Kafka topics, so no extra connector jar in Kafka Connect is required — the database itself pulls from Kafka. We'll wire that part in a follow-up tutorial; this one focuses on getting the cluster running and connectable.

## How it fits in the platform

```
PostgreSQL WAL
      │  (Debezium + Kafka Connect, from Tutorial 3)
      ▼
Kafka Topics (mage.public.<table>)
      │
      ▼  (Routine Load — next tutorial)
StarRocks  ←  this tutorial deploys this
   FE (8030 / 9030)
   BE (8040 / 9060)
```

---

## Prerequisites

- Platform running (`make up` completed)
- Postgres, Kafka, Zookeeper, Kafka Connect, and Schema Registry healthy in the `develop` namespace
- Argo CD accessible (`make argo-ui`)
- A MySQL client on your laptop (`apt install default-mysql-client` or `brew install mysql-client`)

---

## Step 1 — Why the `kube-starrocks` Helm chart + operator

StarRocks publishes an official Kubernetes Operator. The operator watches a **`StarRocksCluster`** Custom Resource and manages the FE and BE StatefulSets, services, and config behind it. You describe the cluster declaratively; the operator handles the imperative steps (init order, leader election, scale-up, config reloads).

The operator is installed via the `kube-starrocks` parent Helm chart, which bundles two sub-charts:

- **operator** — the operator Deployment + RBAC + CRDs
- **starrocks** — a templated `StarRocksCluster` CR (one FE + one BE by default)

This matches the **Helm multi-source pattern** already used by `apps/mage-ai-helm` and `apps/airbyte-helm`: the chart comes from the upstream Helm repo, and the values file comes from this Git repo.

---

## Step 2 — Argo CD Application

File: `argo/apps/starrocks-application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: starrocks
  namespace: argocd
spec:
  project: default

  sources:
    - repoURL: "https://starrocks.github.io/starrocks-kubernetes-operator"
      chart: kube-starrocks
      targetRevision: "1.11.4"
      helm:
        releaseName: "starrocks"
        valueFiles:
          - $values/apps/starrocks-helm/dev/values.yaml

    - repoURL: "https://github.com/georgezefko/data-platform-engineering.git"
      targetRevision: HEAD
      ref: values
      path: apps/starrocks-helm/dev

  destination:
    server: https://kubernetes.default.svc
    namespace: develop

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### Why two `sources` entries?

This is the standard Argo CD Helm-with-Git-values pattern. The first source declares **the chart** (from the StarRocks Helm repo). The second source declares **values from this Git repo**, exposed under the alias `$values` and referenced by `valueFiles:`. This means chart upgrades (bump `targetRevision`) and value tweaks (edit `values.yaml`) are independent changes.

### Why `ServerSideApply=true`?

This is the one detail that's different from the Mage/Airbyte Applications. The StarRocks operator ships large CRDs (`StarRocksCluster`, `StarRocksWarehouse`) whose embedded OpenAPI schemas exceed Kubernetes' 256 KiB annotation limit when applied with `kubectl apply` (client-side apply). Server-side apply doesn't use the `last-applied-configuration` annotation, so it sidesteps the limit. Without this flag the first sync would fail with `metadata.annotations: Too long`.

### Where does this file get picked up?

`argo/app-of-apps.yaml` watches the `argo/apps/` directory. Dropping a new `*-application.yaml` in there is the entire wiring step — no edits to any existing file required.

---

## Step 3 — Helm values

File: `apps/starrocks-helm/dev/values.yaml`

```yaml
operator:
  starrocksOperator:
    enabled: true
    resources:
      requests:
        cpu: 100m
        memory: 200Mi
      limits:
        cpu: 500m
        memory: 500Mi

starrocks:
  nameOverride: "starrocks"

  initPassword:
    enabled: false

  starrocksCluster:
    name: "starrocks"
    enabledBe: true
    enabledCn: false

  starrocksFESpec:
    replicas: 1
    resources:
      requests: { cpu: 500m, memory: 1Gi }
      limits:   { cpu: "1", memory: 2Gi }
    storageSpec:
      name: ""

  starrocksBeSpec:
    replicas: 1
    resources:
      requests: { cpu: 500m, memory: 2Gi }
      limits:   { cpu: "2", memory: 4Gi }
    storageSpec:
      name: ""
```

### Field-by-field rationale

| Field | Value | Why |
|---|---|---|
| `operator.starrocksOperator.resources` | small | The operator is a controller pod, not the database — a few hundred MB is plenty |
| `starrocks.nameOverride` | `starrocks` | Prefix for resources the chart creates (services, configmaps). Default would be `kube-starrocks-*` |
| `starrocks.initPassword.enabled` | `false` | Skip the `root` password rotation Job. For dev we keep an empty `root` password |
| `starrocksCluster.name` | `starrocks` | This becomes the prefix of the FE/BE service names (e.g., `starrocks-fe-service`) |
| `enabledBe` / `enabledCn` | `true` / `false` | One BE (Backend) is the minimum for a working cluster. CN (Compute Node) is a stateless variant used in storage-compute separation deployments — not needed in dev |
| `starrocksFESpec.replicas` | `1` | Single FE works fine for dev. Production starts at 3 for Raft quorum |
| `starrocksBeSpec.replicas` | `1` | One BE means we can only use `replication_num=1` on tables (covered in the next tutorial) |
| `storageSpec.name: ""` | empty | Triggers `emptyDir` instead of provisioning a PVC. **Data is lost on pod restart** — acceptable for dev, not for anything you care about |

### Resource sizing notes

`memory: 2Gi` and `4Gi` limits on FE and BE respectively mean Docker Desktop on the developer laptop needs ~8 GB total available (Kafka, Postgres, Mage, etc. also live in the same cluster). If the BE pod gets OOMKilled, this is the first thing to inspect.

---

## Step 4 — Makefile and port-forward script

File: `scripts/starrocks-pf.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="develop"
SERVICE="starrocks-fe-service"
MYSQL_PORT=9030
HTTP_PORT=8030

echo "StarRocks FE MySQL → localhost:${MYSQL_PORT}  (mysql -h127.0.0.1 -P${MYSQL_PORT} -uroot)"
echo "StarRocks FE HTTP  → http://localhost:${HTTP_PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${MYSQL_PORT}:${MYSQL_PORT}" "${HTTP_PORT}:${HTTP_PORT}"
```

It forwards two ports together because they belong to the same FE service: the MySQL protocol port (used by the `mysql` client / JDBC drivers) and the HTTP admin port (the web dashboard).

Makefile target:

```makefile
starrocks-pf:
	@bash scripts/starrocks-pf.sh
```

And the help line:

```makefile
@echo "  make starrocks-pf      - port-forward StarRocks FE (mysql localhost:9030, http localhost:8030)"
```

---

## Verifying the Deployment

This is the exact sequence used to confirm the install works after merging to `main`.

### 1. Check Argo CD sync

```bash
make status
# or watch:
kubectl -n argocd get applications starrocks -w
```

Wait for the `starrocks` Application to reach `Synced / Healthy`. The first sync downloads the operator image and the (larger) StarRocks FE/BE images — give it 2–5 minutes on a fresh cluster.

### 2. Check the cluster CR and pods

```bash
kubectl -n develop get starrockscluster
kubectl -n develop get pods | grep -Ei 'starrocks|kube-starrocks'
```

Expect three pods in `Running 1/1`:

```
kube-starrocks-operator-...         1/1   Running
starrocks-fe-0                       1/1   Running
starrocks-be-0                       1/1   Running
```

If a pod is `Pending`, run `kubectl -n develop describe pod <name>` — usually a scheduling issue (insufficient memory). If a pod is `CrashLoopBackOff`, `kubectl -n develop logs <name>` shows the reason.

### 3. Confirm service names

```bash
kubectl -n develop get svc | grep starrocks
```

The MySQL port (`9030`) and HTTP port (`8030`) live on the FE service:

```
starrocks-fe-service     ClusterIP   ...   8030/TCP,9020/TCP,9030/TCP
starrocks-fe-search      ClusterIP   None  ...
starrocks-be-service     ClusterIP   ...   9060/TCP,8040/TCP,9050/TCP
```

If the FE service is named something other than `starrocks-fe-service`, update `SERVICE=` in `scripts/starrocks-pf.sh`.

### 4. Port-forward and check FE/BE liveness

```bash
make starrocks-pf
# in another terminal:
mysql -h127.0.0.1 -P9030 -uroot -e "SHOW FRONTENDS\G SHOW BACKENDS\G"
```

The load-bearing fields are:

- **FE row** — `Alive: true`, `IsMaster: true`
- **BE row** — `Alive: true`, `SystemDecommissioned: false`

If both are alive, the cluster is functional. If the BE shows `Alive: false`, the FE can't reach the BE — usually a service DNS / network issue, check the BE pod logs.

### 5. End-to-end smoke test (writing real data)

```bash
mysql -h127.0.0.1 -P9030 -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS smoketest;
USE smoketest;

CREATE TABLE IF NOT EXISTS hello (
  id  INT,
  msg VARCHAR(64)
)
PRIMARY KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 1
PROPERTIES("replication_num" = "1");

INSERT INTO hello VALUES (1, 'starrocks is up'), (2, 'cdc next');
SELECT * FROM hello;
SQL
```

Expect two rows back. `replication_num = 1` is mandatory because we have only one BE — the StarRocks default of `3` would fail to allocate replicas.

### 6. FE web dashboard

In a browser, open http://localhost:8030. Username `root`, empty password (because we set `initPassword.enabled: false`). You should see the FE landing page with cluster status and the database list including `smoketest`.

---

## What's next

The cluster is up but nothing is loading data into it yet. The next tutorial wires Debezium → StarRocks via **Routine Load**:

1. Add the `ExtractNewRecordState` SMT to the existing Debezium connector config so messages are flat JSON instead of the `{before, after, op, source}` envelope.
2. Create a target table in StarRocks using the **Primary Key model** (CDC upserts/deletes).
3. Submit a `CREATE ROUTINE LOAD` statement that consumes the `mage.public.<table>` topic.
4. Insert/update/delete in Postgres, verify the changes propagate end-to-end.

Optionally, that can be packaged as a PostSync Job under `apps/starrocks-helm/dev/` so the database, table, and Routine Load bootstrap automatically on every sync — fully GitOps.

---

## Troubleshooting

### `metadata.annotations: Too long` on first sync

**Symptom:** The Application stays `OutOfSync` and the Argo CD UI shows a CRD apply error mentioning the 262144-byte annotation limit.

**Root cause:** Missing `ServerSideApply=true` in `syncOptions`. The StarRocks CRDs' embedded OpenAPI schemas exceed the `kubectl apply` (client-side) annotation cap.

**Fix:** Confirm `argo/apps/starrocks-application.yaml` contains:

```yaml
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
```

### BE pod stuck in `CrashLoopBackOff` or `OOMKilled`

**Symptom:** `kubectl -n develop describe pod starrocks-be-0` shows `Reason: OOMKilled`.

**Root cause:** Docker Desktop / KinD doesn't have enough memory available to honor the 4Gi limit.

**Fix:** Either raise Docker Desktop's memory allocation (≥ 8 GB recommended for the full platform), or lower the BE limit in `apps/starrocks-helm/dev/values.yaml`. Note that StarRocks BE refuses to start if it can't reserve enough memory for tablet metadata — going below ~1.5 Gi will not work.

### `replication_num = 3 is invalid` when creating tables

**Symptom:** `CREATE TABLE` fails with `Table replication num should be less than or equal to the number of backend nodes`.

**Root cause:** Default `replication_num = 3`, but we have one BE.

**Fix:** Always add `PROPERTIES("replication_num" = "1")` to `CREATE TABLE` statements in dev. Or set a session-level default with `SET PROPERTY 'default_replication_num' = '1';`.

### `make starrocks-pf` says `unable to forward port because pod is not found`

**Symptom:** Port-forward fails immediately.

**Root cause:** The FE pod isn't ready yet, or the FE service name doesn't match what's in the script.

**Fix:**

```bash
kubectl -n develop get pods -l app.starrocks.ownedby/component=fe
kubectl -n develop get svc | grep starrocks
```

Update `SERVICE=` in `scripts/starrocks-pf.sh` if the FE service name differs.
