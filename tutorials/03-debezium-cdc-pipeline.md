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
      │  (change events, envelope unwrapped by ExtractNewRecordState)
      ▼
Kafka Topics  (mage.public.<table>)
      │
      ▼
Any consumer (StarRocks, Flink, Spark, dbt, etc.)
```

---

## Prerequisites

- Platform running (`make up` completed)
- Postgres, Kafka, Zookeeper, and Schema Registry healthy in the `develop` namespace
- Argo CD accessible (`make argo-ui`)

---

## Step 1 — PostgreSQL: logical replication image and table setup

### Why `debezium/postgres:15`

Logical replication requires `wal_level = logical` in `postgresql.conf`. The stock `postgres:15` image defaults to `wal_level = replica`, which is not enough.

`debezium/postgres:15` ships with `wal_level = logical` pre-configured. No custom `postgresql.conf` or init script changes are needed. This is set in `apps/postgres/base/deployment.yaml`:

```yaml
image: debezium/postgres:15
```

### Init script: table and replica identity

File: `apps/postgres/base/configmap.yaml`

```sql
CREATE DATABASE mage;
\c mage

CREATE TABLE IF NOT EXISTS public.telemetry (
  device_id       VARCHAR(64),
  ts              TIMESTAMPTZ,
  energy_usage    DOUBLE PRECISION,
  temperature     DOUBLE PRECISION,
  vibration       DOUBLE PRECISION,
  signal_strength INT,
  PRIMARY KEY (device_id, ts)
);

ALTER TABLE public.telemetry REPLICA IDENTITY FULL;
```

**Why `REPLICA IDENTITY FULL`?**

By default, PostgreSQL only writes the primary key columns to the WAL for UPDATE and DELETE events. `REPLICA IDENTITY FULL` writes every column into the WAL for those operations. This means Debezium can populate the `before` image (the full row state before the change) — critical for any downstream consumer that needs to track what changed, not just what the new state is.

Without this setting, the `before` field in Debezium events will be `null` for every UPDATE and DELETE.

### Replication slot and publication

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

### postStart lifecycle hook — self-healing connector registration

The deployment includes a `postStart` lifecycle hook that registers (or updates) the connector every time the pod starts:

```yaml
lifecycle:
  postStart:
    exec:
      command:
        - sh
        - -c
        - |
          until curl -sf http://localhost:8083/connectors; do
            sleep 5
          done
          STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            http://localhost:8083/connectors/postgres-connector)
          if [ "$STATUS" = "404" ]; then
            curl -s -X POST http://localhost:8083/connectors \
              -H "Content-Type: application/json" -d @/config/connector.json
          else
            curl -s -X PUT \
              http://localhost:8083/connectors/postgres-connector/config \
              -H "Content-Type: application/json" -d @/config/connector-config.json
          fi
```

This solves the **connector-disappears-after-restart** problem (see Troubleshooting). The logic:

1. Poll `localhost:8083/connectors` until the REST API is up
2. `GET /connectors/postgres-connector` → HTTP 404: connector missing → POST `connector.json` (full registration payload including `name`)
3. HTTP 200: connector exists → PUT `connector-config.json` (config-only payload, no `name` field — the PUT endpoint rejects it)

The ConfigMap is mounted at `/config` via a volume:

```yaml
volumeMounts:
  - name: connector-config
    mountPath: /config
volumes:
  - name: connector-config
    configMap:
      name: debezium-connector-config
```

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

The ConfigMap holds **two JSON files** because the Kafka Connect REST API uses different payloads for POST (create) and PUT (update):

| File | Used by | Contains |
|---|---|---|
| `connector.json` | POST `/connectors` | Full payload including `"name"` and `"config"` wrapper |
| `connector-config.json` | PUT `/connectors/<name>/config` | Config fields only, no `"name"`, no `"config"` wrapper |

```json
// connector.json  (POST — create)
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
    "schema.history.internal.kafka.topic": "schema-changes.mage",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.add.fields": "op,ts_ms",
    "transforms.unwrap.delete.handling.mode": "rewrite",
    "transforms.unwrap.drop.tombstones": "true"
  }
}
```

```json
// connector-config.json  (PUT — update)
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  ...same fields as above, no "name" or "config" wrapper...
}
```

### The `ExtractNewRecordState` transform (unwrap)

By default, every Debezium event has a nested envelope:

```json
{
  "before": { "device_id": "d1", "ts": "...", ... },
  "after":  { "device_id": "d1", "ts": "...", ... },
  "op": "u",
  "ts_ms": 1234567890
}
```

The `ExtractNewRecordState` SMT (Single Message Transform) flattens the `after` fields to the top level:

```json
{
  "device_id": "d1",
  "ts": "...",
  "energy_usage": 1.23,
  "__op": "u",
  "__ts_ms": 1234567890
}
```

This makes the events directly consumable by StarRocks, Flink, and other tools without extra deserialization logic.

| Transform option | Value | Effect |
|---|---|---|
| `add.fields` | `op,ts_ms` | Appends `__op` and `__ts_ms` metadata to the flattened record |
| `delete.handling.mode` | `rewrite` | DELETE events keep the last known field values (from `before`) plus `__op=d` instead of emitting a null/tombstone |
| `drop.tombstones` | `true` | Suppresses the follow-up null-key tombstone Kafka uses for log compaction — avoids confusing consumers that don't expect null values |

### Field-by-field explanation (core connector fields)

| Field | Value | Why |
|---|---|---|
| `connector.class` | `PostgresConnector` | Tells Kafka Connect which plugin to load |
| `database.*` | in-cluster DNS + mage DB | Standard JDBC-style connection |
| `topic.prefix` | `mage` | Topics named `mage.<schema>.<table>` (e.g. `mage.public.telemetry`) |
| `plugin.name` | `pgoutput` | Native PostgreSQL logical decoding — no extra extensions needed |
| `slot.name` | `debezium_slot` | Postgres creates this slot; it tracks the WAL LSN so Debezium can resume after a restart without missing events |
| `publication.name` | `debezium_publication` | Postgres publication for `FOR ALL TABLES`; auto-created by Debezium on first connect |
| `schema.history.internal.*` | Kafka topic | DDL changes (ALTER TABLE, etc.) are recorded here so Debezium can replay schema history on restart |

---

## Step 5 — PostSync Registration Job

File: `apps/kafka-connect/base/connector-job.yaml`

In addition to the `postStart` hook, a Kubernetes Job runs as an Argo CD PostSync hook. This provides a second registration path that is visible in `kubectl get jobs` and produces logs you can inspect.

```yaml
annotations:
  argocd.argoproj.io/hook: PostSync
  argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

`PostSync` means Argo CD runs this Job after every sync, once all resources are healthy. `BeforeHookCreation` deletes the previous Job run before starting a new one (avoids naming conflicts).

The Job logic mirrors the `postStart` hook: wait for the REST API, then POST or skip if connector exists.

---

## Step 6 — Kustomization Wiring

`apps/kafka-connect/base/kustomization.yaml` lists all resources:

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

Placing this file in `argo/apps/` is all that's needed. The app-of-apps Application watches that directory and automatically picks up any new `*-application.yaml`.

---

## Step 8 — Port-Forward Helper

`make kafka-connect-pf` runs:

```bash
kubectl -n develop port-forward svc/kafka-connect-svc 8083:8083
```

---

## Deploying Kafka Connect in KinD — step by step

This section is a sequential command walkthrough. Follow it top to bottom on a fresh cluster after `make up` has completed.

### 1. Confirm the platform is ready

```bash
make status
```

You should see the existing apps (`kafka`, `postgres`, `schema-registry`, etc.) as `Synced / Healthy` before continuing. Kafka Connect depends on Kafka and Postgres being up.

```bash
kubectl get pods -n develop
```

All pods should be `Running 1/1`. If `kafka-0` or `postgres-*` are still starting, wait for them before proceeding.

### 2. Verify Argo CD picked up the kafka-connect Application

Argo CD watches `argo/apps/` on the `main` branch. Once the `kafka-connect-application.yaml` is merged, the Application appears automatically:

```bash
kubectl get applications -n argocd
```

You should see `kafka-connect-app` listed. If it is missing, the app-of-apps hasn't synced yet — trigger it manually:

```bash
kubectl -n argocd patch application app-of-apps \
  --type merge -p '{"metadata":{"annotations":{"kubectl.kubernetes.io/last-applied-configuration":""}}}'
# or simply wait ~30s and re-check
```

### 3. Watch the kafka-connect pod come up

```bash
kubectl get pods -n develop -w
```

You will see the pod progress through these states:

```
kafka-connect-...   0/1   Pending           0   0s
kafka-connect-...   0/1   ContainerCreating 0   2s
kafka-connect-...   0/1   Running           0   10s   ← postStart hook running
kafka-connect-...   1/1   Running           0   75s   ← readinessProbe passed
```

The gap between `Running` and `1/1 Running` is the `initialDelaySeconds: 60` on the readiness probe — Kafka Connect takes ~60 seconds to load its internal topics and start the REST API.

Press `Ctrl+C` once the pod shows `1/1 Running`.

### 4. Check that the postStart hook registered the connector

The `postStart` hook runs as soon as the REST API is up. Check the pod logs to confirm it ran:

```bash
kubectl logs -n develop deployment/kafka-connect
```

Look for lines like:

```
{"name":"postgres-connector","config":{...}}
```

or (if the connector was already present from a previous run):

```
{"connector.class":"io.debezium.connector.postgresql.PostgresConnector",...}
```

Either output means registration succeeded. If the logs show no curl output at all, the hook may have run before the log buffer flushed — proceed to step 5 to confirm via the REST API.

### 5. Check the PostSync Job

Argo CD also runs the registration Job after each sync:

```bash
kubectl get jobs -n develop
```

You should see `register-debezium-connector` with `COMPLETIONS: 1/1`. Check its output:

```bash
kubectl logs -n develop job/register-debezium-connector
```

Expected output:

```
Waiting for Kafka Connect to be ready...
Connector already exists (HTTP 200), skipping.
```

or on first install:

```
{"name":"postgres-connector","config":{...}}
```

If the Job is in `0/1` or shows errors, check the init container logs:

```bash
kubectl logs -n develop job/register-debezium-connector -c wait-for-connect
```

### 6. Port-forward the Kafka Connect REST API

```bash
make kafka-connect-pf
```

Keep this terminal open. In a new terminal:

```bash
# List registered connectors
curl -s http://localhost:8083/connectors
# Expected: ["postgres-connector"]
```

```bash
# Check connector status
curl -s http://localhost:8083/connectors/postgres-connector/status | python3 -m json.tool
```

A healthy response:

```json
{
  "name": "postgres-connector",
  "connector": { "state": "RUNNING", "worker_id": "..." },
  "tasks": [{ "id": 0, "state": "RUNNING", "worker_id": "..." }],
  "type": "source"
}
```

If `state` is `FAILED`, the `trace` field in the task entry shows the exception — see Troubleshooting.

### 7. Confirm Kafka topics exist

```bash
kubectl exec -n develop kafka-0 -- \
  kafka-topics --bootstrap-server localhost:9092 --list
```

Expected topics at this point (before any data is inserted):

```
debezium_connect_configs
debezium_connect_offsets
debezium_connect_statuses
schema-changes.mage
```

The `mage.public.telemetry` topic is created by Debezium the first time it captures a change from that table. It will not appear until you write data to Postgres.

### 8. Verify Postgres has logical replication enabled

```bash
make postgres-pf
```

In a new terminal:

```bash
psql -h localhost -U postgres -d mage \
  -c "SHOW wal_level;"
```

Expected: `logical`. If it shows `replica`, the wrong Postgres image is running — check `apps/postgres/base/deployment.yaml`.

```bash
psql -h localhost -U postgres -d mage \
  -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

You should see `debezium_slot` with `active = true`. If the slot is missing, Debezium hasn't connected yet — the connector status should be `RUNNING` from step 6; give it a few seconds.

### 9. Insert data and watch the event flow

Insert a row into Postgres:

```bash
psql -h localhost -U postgres -d mage -c "
  INSERT INTO public.telemetry (device_id, ts, energy_usage, temperature, vibration, signal_strength)
  VALUES ('device-001', NOW(), 1.23, 22.5, 0.01, -65);
"
```

Wait ~2 seconds, then list topics again — `mage.public.telemetry` should now appear:

```bash
kubectl exec -n develop kafka-0 -- \
  kafka-topics --bootstrap-server localhost:9092 --list | grep mage.public
```

Consume the event:

```bash
kubectl exec -it -n develop kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic mage.public.telemetry \
  --from-beginning \
  --max-messages 1
```

Because `ExtractNewRecordState` is active, the message is flat JSON — no nested `before`/`after` envelope:

```json
{
  "device_id": "device-001",
  "ts": "2026-05-28T00:00:00.000Z",
  "energy_usage": 1.23,
  "temperature": 22.5,
  "vibration": 0.01,
  "signal_strength": -65,
  "__op": "c",
  "__ts_ms": 1748390000000
}
```

`__op` values: `c` = create (INSERT), `u` = update (UPDATE), `d` = delete (DELETE), `r` = read (snapshot).

The pipeline is working end-to-end. Continue to Tutorial 4 to add StarRocks as the CDC sink.

---

## Quick-reference verification checklist

After any restart or re-deploy, run these in order to confirm the pipeline is healthy:

| Check | Command | Expected |
|---|---|---|
| All pods running | `kubectl get pods -n develop` | All `1/1 Running` |
| Argo sync | `kubectl get applications -n argocd` | `kafka-connect-app` → `Synced / Healthy` |
| Connector registered | `curl http://localhost:8083/connectors` | `["postgres-connector"]` |
| Connector running | `curl …/connectors/postgres-connector/status` | `"state": "RUNNING"` |
| Replication slot active | `SELECT slot_name, active FROM pg_replication_slots` | `debezium_slot` / `t` |
| Topics exist | `kafka-topics --list` | `mage.public.telemetry` present after first write |

---

## Filtering Tables

By default Debezium auto-creates `debezium_publication FOR ALL TABLES` — every table in the `mage` database streams to Kafka.

### Option A — Filter at the connector level (recommended for dev)

Add `table.include.list` to the connector config in `connector-configmap.yaml`:

```json
"table.include.list": "public.orders,public.products"
```

Debezium still reads the full WAL but only emits events for the listed tables. No PostgreSQL changes needed. Changing which tables to capture is a ConfigMap update + connector re-registration — no database downtime.

### Option B — Scope the publication in PostgreSQL

Add to `apps/postgres/base/configmap.yaml` `init.sql`:

```sql
CREATE PUBLICATION debezium_publication FOR TABLE public.orders, public.products;
```

PostgreSQL only sends those rows over the replication stream — more efficient for large schemas. Requires a DB change and recreation of the publication if you add tables later.

---

## Troubleshooting

### Connector disappears after Kafka restart

**Symptom:** After Kafka restarts, `curl /connectors` returns `[]`.

**Root cause:** In dev the internal Connect topics (`debezium_connect_configs`, `debezium_connect_offsets`, `debezium_connect_statuses`) use `replication.factor=1`. A single-node Kafka losing its PVC wipes those topics. Kafka Connect reloads connector config from its internal topics on startup — if the topics are empty, all connectors are gone.

**This is handled automatically.** The Kafka Connect Deployment has a `postStart` lifecycle hook that waits for the REST API and then registers (or updates) the connector on every pod start.

If the hook silently failed, force re-registration by restarting the pod:

```bash
kubectl rollout restart deployment kafka-connect -n develop
```

Then verify:

```bash
make kafka-connect-pf
# in another terminal:
curl http://localhost:8083/connectors
# should return ["postgres-connector"]
```

### Connector created but no topics appear

**Step 1** — Check connector status:

```bash
curl http://localhost:8083/connectors/postgres-connector/status
```

Look for `"state": "FAILED"` in either the connector or task section; the `trace` field will show the exception.

**Step 2** — Check the replication slot:

```bash
make postgres-pf
psql -h localhost -U postgres -d mage \
  -c "SELECT slot_name, active FROM pg_replication_slots;"
```

If `debezium_slot` is missing or `active = false`, Debezium lost its slot (can happen on Postgres restart with no PVC). Delete and re-create the connector to force Debezium to re-create the slot:

```bash
curl -X DELETE http://localhost:8083/connectors/postgres-connector
kubectl rollout restart deployment kafka-connect -n develop
```

**Step 3** — Verify the publication:

```bash
psql -h localhost -U postgres -d mage \
  -c "SELECT pubname, puballtables FROM pg_publication;"
```

`debezium_publication` with `puballtables = true` means all tables are published. If it is missing, restart the connector (Debezium will re-create it).

### `before` field is always null on UPDATE/DELETE

**Cause:** `REPLICA IDENTITY` on the table is the default (`DEFAULT`) — only the primary key is written to the WAL for UPDATE/DELETE.

**Fix:** Run once against the database:

```sql
ALTER TABLE public.telemetry REPLICA IDENTITY FULL;
```

This is already in `apps/postgres/base/configmap.yaml` for the `telemetry` table. For any additional tables you add, you must run the same `ALTER TABLE` statement.

### postStart hook registered the wrong config

The `postStart` hook uses PUT (`connector-config.json`) when the connector already exists. If you changed the ConfigMap but the PUT is using a stale pod, trigger a rollout:

```bash
kubectl rollout restart deployment kafka-connect -n develop
```

The new pod will run the `postStart` hook with the latest ConfigMap.

### Connector is RUNNING but events look wrong (no `__op`, nested `before`/`after`)

**Cause:** The `ExtractNewRecordState` transform is not applied — possibly the connector was registered before the transform fields were added to the ConfigMap.

**Fix:** Force a config update via PUT:

```bash
make kafka-connect-pf
curl -X PUT http://localhost:8083/connectors/postgres-connector/config \
  -H "Content-Type: application/json" \
  -d @- <<'EOF'
{
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
  "schema.history.internal.kafka.topic": "schema-changes.mage",
  "transforms": "unwrap",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.add.fields": "op,ts_ms",
  "transforms.unwrap.delete.handling.mode": "rewrite",
  "transforms.unwrap.drop.tombstones": "true"
}
EOF
```

### Job fails with "connector already exists" but connector is broken

The PostSync Job skips registration when the connector exists (HTTP 200). If the connector is in a FAILED state, delete it first:

```bash
curl -X DELETE http://localhost:8083/connectors/postgres-connector
```

Then trigger the Argo CD sync or restart the pod to re-register.

### Kafka Connect pod stuck in Init or CrashLoopBackOff

```bash
kubectl describe pod -n develop -l app=kafka-connect
kubectl logs -n develop -l app=kafka-connect --previous
```

Common causes:
- Kafka broker not yet ready when Connect starts — the `readinessProbe` delay (60s) should cover this, but during initial cluster bootstrap you may need to wait longer
- `debezium-connector-config` ConfigMap missing — verify with `kubectl get configmap -n develop`
- Volume mount fails — verify the ConfigMap name in `deployment.yaml` matches the one in `connector-configmap.yaml`
