# Building a CDC Pipeline with Debezium and Kafka Connect on Local Kubernetes

This tutorial extends the data platform from Tutorial 2 by adding **Change Data Capture (CDC)**. By the end you will have Debezium streaming every INSERT/UPDATE/DELETE from PostgreSQL into Kafka topics, automatically, via GitOps.

## What is CDC?

Change Data Capture reads a database's internal write-ahead log (WAL) instead of polling tables. Every committed row change becomes an event published to a message broker. Consumers downstream get low-latency, ordered, complete change history — without touching the source database with expensive queries.

Debezium is an open-source CDC platform built on top of Kafka Connect. It ships connector plugins for many databases; here we use the PostgreSQL connector.

## How it fits in the platform

The platform already has:

- **PostgreSQL** — source database (`mage` DB, `develop` namespace)
- **Kafka + Zookeeper** — message broker
- **Schema Registry** — schema management
- **Argo CD** — GitOps controller watching `main`

What we add:

```
PostgreSQL WAL
      │  (logical replication via pgoutput)
      ▼
Kafka Connect  ←  Debezium PostgreSQL Connector
      │  (change events)
      ▼
Kafka Topics  (mage.public.<table>)
      │
      ▼
Any consumer (Flink, Spark, dbt, etc.)
```

---

## Prerequisites

- Platform running (`make up` completed)
- Postgres, Kafka, Zookeeper, and Schema Registry healthy in the `develop` namespace
- Argo CD accessible (`make argo-ui`)

---

## Step 1 — Why `debezium/postgres:15`

Logical replication requires `wal_level = logical` in `postgresql.conf`. The stock `postgres:15` image defaults to `wal_level = replica`, which is not enough.

`debezium/postgres:15` ships with `wal_level = logical` pre-configured. No custom `postgresql.conf` or init script changes are needed.

This is already set in `apps/postgres/base/deployment.yaml`:

```yaml
image: debezium/postgres:15
```

When Debezium connects for the first time it automatically creates:
- a **replication slot** (`debezium_slot`) — tracks WAL position for this connector
- a **publication** (`debezium_publication FOR ALL TABLES`) — declares which changes to stream

Both are created by Debezium; you do not need SQL in `init.sql` for them.

---

## Step 2 — Kafka Connect Deployment

File: `apps/kafka-connect/base/deployment.yaml`

```yaml
image: quay.io/debezium/connect:2.7
```

Debezium distributes a pre-built Kafka Connect image with the PostgreSQL connector plugin already on the classpath. You do not need to install anything.

### Key environment variables

| Variable | Value | Why |
|---|---|---|
| `BOOTSTRAP_SERVERS` | `kafka-svc.develop.svc.cluster.local:9092` | In-cluster DNS for Kafka |
| `GROUP_ID` | `debezium-connect` | Identifies this Connect cluster |
| `CONFIG_STORAGE_TOPIC` | `debezium_connect_configs` | Connector configs persisted here |
| `OFFSET_STORAGE_TOPIC` | `debezium_connect_offsets` | WAL offsets (resume position) persisted here |
| `STATUS_STORAGE_TOPIC` | `debezium_connect_statuses` | Task status persisted here |
| `*_REPLICATION_FACTOR` | `1` | Dev only — single Kafka broker, no redundancy |
| `CONNECT_KEY_CONVERTER` | `JsonConverter` | JSON events, no Avro/Schema Registry |
| `CONNECT_VALUE_CONVERTER` | `JsonConverter` | |
| `*_SCHEMAS_ENABLE` | `false` | Omit the schema envelope from every message |

### Health probes

Both readiness and liveness probes call `GET /connectors` on port 8083. The REST API only responds once Kafka Connect has fully started and loaded its internal topics.

```yaml
readinessProbe:
  httpGet:
    path: /connectors
    port: 8083
  initialDelaySeconds: 30
  periodSeconds: 10
```

The readiness probe is important — the registration Job waits for it before posting the connector config.

---

## Step 3 — Service

File: `apps/kafka-connect/base/service.yaml`

A ClusterIP service exposes the REST API inside the cluster:

```
kafka-connect-svc.develop.svc.cluster.local:8083
```

The registration Job and any other in-cluster clients use this DNS name. For local access, `make kafka-connect-pf` forwards port 8083 to `localhost:8083`.

---

## Step 4 — Connector ConfigMap

File: `apps/kafka-connect/base/connector-configmap.yaml`

The connector configuration is stored as a ConfigMap so it can be version-controlled and mounted into the registration Job.

```json
{
  "name": "postgres-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres.develop.svc.cluster.local",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "mage",
    "topic.prefix": "mage",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_slot",
    "publication.name": "debezium_publication",
    "schema.history.internal.kafka.bootstrap.servers": "kafka-svc.develop.svc.cluster.local:9092",
    "schema.history.internal.kafka.topic": "schema-changes.mage"
  }
}
```

### Field-by-field explanation

| Field | Value | Why |
|---|---|---|
| `connector.class` | `PostgresConnector` | Tells Kafka Connect which plugin to load |
| `database.*` | in-cluster DNS + mage DB | Standard JDBC-style connection |
| `topic.prefix` | `mage` | Topics named `mage.<schema>.<table>` (e.g. `mage.public.telemetry`) |
| `plugin.name` | `pgoutput` | Native PostgreSQL logical decoding — no extra extensions needed |
| `slot.name` | `debezium_slot` | Postgres creates this slot; it tracks the WAL LSN (log sequence number) so Debezium can resume after a restart without missing events |
| `publication.name` | `debezium_publication` | Postgres publication for `FOR ALL TABLES`; auto-created by Debezium on first connect |
| `schema.history.internal.*` | Kafka topic | DDL changes (ALTER TABLE, etc.) are recorded here so Debezium can replay schema history on restart |

### One replication slot per connector

A replication slot tracks WAL position for one consumer. One connector = one slot, regardless of how many tables you watch. Do not create multiple slots for the same connector — it wastes WAL retention space.

---

## Step 5 — PostSync Registration Job

File: `apps/kafka-connect/base/connector-job.yaml`

Kafka Connect exposes a REST API for managing connectors. The connector config in the ConfigMap is not automatically picked up — it must be POSTed to the API. A Kubernetes Job handles this.

### Argo CD PostSync hook

```yaml
annotations:
  argocd.argoproj.io/hook: PostSync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

`PostSync` means Argo CD runs this Job after every sync, once all resources are healthy. `BeforeHookCreation` deletes the previous Job run before starting a new one (avoids naming conflicts).

### Init container — wait for readiness

```bash
until curl -sf http://kafka-connect-svc.develop.svc.cluster.local:8083/connectors; do
  echo "Waiting for Kafka Connect to be ready..."; sleep 5
done
```

Kafka Connect can take 30-60 seconds to start. The init container polls until the REST API responds before the main container runs.

### Main container — idempotent registration

```bash
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  http://kafka-connect-svc.develop.svc.cluster.local:8083/connectors/postgres-connector)

if [ "$STATUS" = "404" ]; then
  curl -X POST http://kafka-connect-svc.develop.svc.cluster.local:8083/connectors \
    -H "Content-Type: application/json" \
    -d @/config/connector.json
else
  echo "Connector already exists (HTTP $STATUS), skipping."
fi
```

- HTTP 200 from `GET /connectors/postgres-connector` → connector exists, skip
- HTTP 404 → connector missing, POST the config
- The ConfigMap is mounted at `/config/connector.json`

The Job uses `curlimages/curl:8.7.1` — a tiny image (~5 MB) with no JVM, fast to pull.

---

## Step 6 — Kustomization Wiring

`apps/kafka-connect/base/kustomization.yaml` lists all four resources:

```yaml
resources:
  - deployment.yaml
  - service.yaml
  - connector-configmap.yaml
  - connector-job.yaml
```

`apps/kafka-connect/dev/kustomization.yaml` simply inherits:

```yaml
resources:
  - ../base
```

The dev overlay exists to add environment-specific patches later (resource limits, image tags, etc.) without changing base.

---

## Step 7 — Argo CD Application

File: `argo/apps/kafka-connect-application.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kafka-connect-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: "https://github.com/georgezefko/data-platform-engineering.git"
    targetRevision: HEAD
    path: apps/kafka-connect/dev
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: develop
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Placing this file in `argo/apps/` is all that's needed. The app-of-apps Application (`argo/app-of-apps.yaml`) watches that directory and automatically picks up any new `*-application.yaml`. No changes to existing Argo files are required.

---

## Step 8 — Makefile and Port-Forward

`scripts/kafka-connect-pf.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="develop"
SERVICE="kafka-connect-svc"
PORT=8083
echo "Kafka Connect REST API → http://localhost:${PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${PORT}:${PORT}"
```

`Makefile` target:

```makefile
kafka-connect-pf:
    @bash scripts/kafka-connect-pf.sh
```

---

## Verifying the Deployment

### 1. Check Argo CD sync

```bash
make status
# or
kubectl get applications -n argocd
```

Wait for `kafka-connect-app` to reach `Synced / Healthy`.

### 2. Check the registration Job

```bash
kubectl get jobs -n develop
kubectl logs -n develop job/register-debezium-connector -c register-connector
# Expected: "Connector registered." or "Connector already exists"
```

### 3. Query the REST API

```bash
make kafka-connect-pf
# in another terminal:
curl http://localhost:8083/connectors
# ["postgres-connector"]

curl http://localhost:8083/connectors/postgres-connector/status
```

A healthy connector status looks like:

```json
{
  "name": "postgres-connector",
  "connector": { "state": "RUNNING" },
  "tasks": [{ "id": 0, "state": "RUNNING" }]
}
```

### 4. Inspect Kafka topics

```bash
kubectl exec -n develop kafka-0 -- \
  kafka-topics --bootstrap-server localhost:9092 --list
```

You should see `mage.public.<table>` topics appearing as Debezium captures changes.

### 5. Consume change events

```bash
kubectl exec -it -n develop kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic mage.public.telemetry \
  --from-beginning
```

Each message is a JSON change event containing `before`, `after`, and metadata fields (operation type, timestamp, source info).

---

## Filtering Tables

By default Debezium auto-creates `debezium_publication FOR ALL TABLES` — every table in the `mage` database streams to Kafka.

### Option A — Filter at the connector level (recommended for dev)

Add `table.include.list` to `connector-configmap.yaml`:

```json
"table.include.list": "public.orders,public.products"
```

Debezium still reads the full WAL but only emits events for the listed tables. No PostgreSQL changes needed. Changing which tables to capture is a ConfigMap update + connector re-registration — no database downtime.

### Option B — Scope the publication in PostgreSQL

Add to `apps/postgres/base/configmap.yaml` `init.sql`:

```sql
CREATE PUBLICATION debezium_publication FOR TABLE public.orders, public.products;
```

PostgreSQL only sends those rows over the replication stream — more efficient for large schemas. Requires a DB change and recreation of the publication if you add tables.

---

## Troubleshooting

### Connector disappears after Kafka restart

**Symptom:** After Kafka restarts, `curl /connectors` returns `[]`.

**Root cause:** In dev the internal Connect topics (`debezium_connect_configs`, `debezium_connect_offsets`, `debezium_connect_statuses`) use `replication.factor=1`. A single-node Kafka losing its PVC wipes those topics. Kafka Connect reloads connector config from its internal topics on startup — if the topics are empty, all connectors are gone.

The PostSync Job only re-runs on Argo CD sync events, not on Kafka restarts.

**Immediate fix — re-register manually:**

```bash
make kafka-connect-pf
# in another terminal:
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "postgres-connector",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "database.hostname": "postgres.develop.svc.cluster.local",
      "database.port": "5432",
      "database.user": "postgres",
      "database.password": "postgres",
      "database.dbname": "mage",
      "topic.prefix": "mage",
      "plugin.name": "pgoutput",
      "slot.name": "debezium_slot",
      "publication.name": "debezium_publication",
      "schema.history.internal.kafka.bootstrap.servers": "kafka-svc.develop.svc.cluster.local:9092",
      "schema.history.internal.kafka.topic": "schema-changes.mage"
    }
  }'
```

**Production fix:** Add a sidecar or init container to Kafka Connect that always POSTs the connector config on startup, rather than relying solely on the PostSync Job.

### Connector created but no topics appear

Check that the `mage` database has data and the replication slot exists:

```bash
make postgres-pf
# then:
psql -h localhost -U postgres -d mage \
  -c "SELECT slot_name, active FROM pg_replication_slots;"
```

If `debezium_slot` is missing or `active = false`, check the connector status for errors:

```bash
curl http://localhost:8083/connectors/postgres-connector/status
```
