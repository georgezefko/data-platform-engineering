# StarRocks Routine Load — CDC Event Log

This tutorial wires the Debezium CDC stream into StarRocks as an **append-only event log**. Every INSERT, UPDATE, and DELETE from Postgres lands as its own row. Downstream transformations (SCD Type 2, aggregations, etc.) read from this log — StarRocks itself does no merging or deduplication.

## Why an event log instead of upsert?

The upsert / Primary Key approach collapses history: an UPDATE overwrites the old row, a DELETE removes it. You lose the ability to answer questions like "what was the value at time T?" or "how many times did this record change?".

An append-only event log preserves every state transition. SCD Type 2, point-in-time snapshots, and audit trails are all straightforward queries on top of it.

## How it fits in the platform

```
PostgreSQL WAL
      │  (Debezium + Kafka Connect)
      ▼
Kafka Topic  mage.public.telemetry
      │  (flat JSON — ExtractNewRecordState SMT applied)
      ▼
StarRocks Routine Load
      │  (DUPLICATE KEY table — all rows kept)
      ▼
mage_cdc.telemetry_events
      │
      ▼
Downstream: SCD2 / aggregations / BI queries
```

---

## The message format problem

Without any transformation, Debezium emits the full CDC envelope:

```json
{
  "before": null,
  "after": { "device_id": "device_3", "ts": "...", "signal_strength": 74, ... },
  "op": "c",
  "ts_ms": 1779615549783
}
```

This envelope format creates two problems for an event log:

1. **Delete events have `after: null`** — the actual row data is in `before`. A static `jsonpath` can't switch between `after` and `before` based on the operation.
2. **`op` is at the top level**, separate from the payload fields.

The fix is the **`ExtractNewRecordState` SMT** (Single Message Transform), configured on the Debezium connector. It runs inside Kafka Connect before messages reach the topic and:

- Flattens the envelope — `after` fields become top-level fields
- For DELETE events, uses `before` as the payload (so the row data is never null)
- Appends `__op` and `__ts_ms` metadata fields

The result is a consistent flat message for every event type:

```json
{
  "device_id": "device_3",
  "ts": "2026-05-24T09:39:10.382694Z",
  "energy_usage": "WA==",
  "temperature": "AOs=",
  "vibration": "Aw==",
  "signal_strength": 74,
  "__op": "c",
  "__ts_ms": 1779615549783
}
```

| `__op` | Meaning |
|---|---|
| `c` | INSERT (create) |
| `u` | UPDATE — payload is the **new** row state |
| `d` | DELETE — payload is the **deleted** row state |
| `r` | Snapshot read (initial load) |

---

## Step 1 — Apply the SMT to the running connector

The `ExtractNewRecordState` SMT has already been added to `apps/kafka-connect/base/connector-configmap.yaml` in the GitOps config. The Argo PostSync Job will apply it automatically on the next sync.

To apply it immediately without waiting for a sync, use the Kafka Connect REST API directly:

```bash
# In a separate terminal
make kafka-connect-pf
```

Then in another terminal:

```bash
curl -X PUT \
  http://localhost:8083/connectors/postgres-connector/config \
  -H "Content-Type: application/json" \
  -d '{
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
  }'
```

Verify the SMT is active by consuming a new message from the topic — it should now be flat:

```bash
kubectl exec -it -n develop kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic mage.public.telemetry \
  --max-messages 1
```

You should see a flat JSON object (no `before`/`after` wrapper, `__op` present).

> **Note on existing messages in the topic:** Messages produced before the SMT was applied remain in the old envelope format. The Routine Load will start from `OFFSET_END` (only new messages), so only flat-format messages are loaded. The old messages stay in Kafka until the topic's retention period expires — they are not consumed by StarRocks.

---

## Step 2 — How the connector update is persisted (GitOps)

The `connector-configmap.yaml` already contains the SMT config. The `connector-job.yaml` (PostSync hook) now uses:

- **POST** `/connectors` — if the connector doesn't exist yet (fresh cluster)
- **PUT** `/connectors/{name}/config` — if it already exists (update path)

This means on every Argo sync, the connector config is reconciled to match the ConfigMap. No manual step required after the initial apply above.

---

## Step 3 — Connect to StarRocks

```bash
# In a separate terminal
make starrocks-pf
```

```bash
mysql -h127.0.0.1 -P9030 -uroot
```

---

## Step 4 — Create the database and event log table

```sql
CREATE DATABASE IF NOT EXISTS mage_cdc;
USE mage_cdc;
```

If you previously created a `telemetry` table with the Primary Key model, drop it first:

```sql
DROP TABLE IF EXISTS telemetry;
```

Create the event log table using the **Duplicate Key** model:

```sql
CREATE TABLE IF NOT EXISTS telemetry_events (
  event_ts_ms     BIGINT,
  op              VARCHAR(1),
  device_id       VARCHAR(64),
  ts              VARCHAR(40),
  energy_usage    VARCHAR(20),
  temperature     VARCHAR(20),
  vibration       VARCHAR(20),
  signal_strength INT
)
DUPLICATE KEY(event_ts_ms, op, device_id)
DISTRIBUTED BY HASH(device_id) BUCKETS 1
PROPERTIES("replication_num" = "1");
```

### Table design notes

| Choice | Reason |
|---|---|
| `DUPLICATE KEY` model | Appends every row without deduplication — all events are preserved |
| `event_ts_ms` | Unix millisecond timestamp from Debezium (`__ts_ms`). First key column for efficient time-range queries |
| `op` VARCHAR(1) | Stores `c` / `u` / `d` / `r` — the operation type from Debezium |
| `ts` VARCHAR(40) | The device timestamp as an ISO 8601 string. Stored as-is; cast to DATETIME(6) in views or downstream if needed |
| `energy_usage`, `temperature`, `vibration` VARCHAR | Postgres `bytea` → base64 strings. Decode with `from_base64()` downstream |
| `replication_num = 1` | Required — only one BE in the dev cluster |

---

## Step 5 — Create the Routine Load job

```sql
CREATE ROUTINE LOAD mage_cdc.load_telemetry ON telemetry_events
COLUMNS(event_ts_ms, op, device_id, ts, energy_usage, temperature, vibration, signal_strength)
PROPERTIES (
  "format"                    = "json",
  "jsonpaths"                 = "[\"$.__ts_ms\",\"$.__op\",\"$.device_id\",\"$.ts\",\"$.energy_usage\",\"$.temperature\",\"$.vibration\",\"$.signal_strength\"]",
  "desired_concurrent_number" = "1"
)
FROM KAFKA (
  "kafka_broker_list"              = "kafka-svc.develop.svc.cluster.local:9092",
  "kafka_topic"                    = "mage.public.telemetry",
  "property.group.id"              = "starrocks-telemetry-loader",
  "property.kafka_default_offsets" = "OFFSET_END"
);
```

`OFFSET_END` starts consumption from the current end of the topic — only messages produced after the SMT was applied (flat format) are loaded. This avoids parse failures on old envelope-format messages already in the topic.

---

## Step 6 — Verify

Check the job state (allow 5–10 seconds):

```sql
SHOW ROUTINE LOAD FOR mage_cdc.load_telemetry\G
```

Look for `State: RUNNING`. Then check rows:

```sql
SELECT COUNT(*) FROM mage_cdc.telemetry_events;

-- Sample events by operation type
SELECT op, COUNT(*) FROM mage_cdc.telemetry_events GROUP BY op;

-- Most recent events
SELECT event_ts_ms, op, device_id, signal_strength
FROM mage_cdc.telemetry_events
ORDER BY event_ts_ms DESC
LIMIT 10;
```

---

## Step 7 — End-to-end test with all operation types

```bash
# Port-forward Postgres
make postgres-pf
```

In a separate terminal run the following SQL against Postgres to trigger each operation type:

```bash
psql -h127.0.0.1 -U postgres -d mage
```

```sql
-- INSERT → __op = 'c'
INSERT INTO public.telemetry (device_id, ts, energy_usage, temperature, vibration, signal_strength)
VALUES ('test_device', now(), '\x01'::bytea, '\x02'::bytea, '\x03'::bytea, 50);

-- UPDATE → __op = 'u'  (payload = new row state)
UPDATE public.telemetry SET signal_strength = 99 WHERE device_id = 'test_device';

-- DELETE → __op = 'd'  (payload = deleted row state, from 'before')
DELETE FROM public.telemetry WHERE device_id = 'test_device';
```

Then in StarRocks, all three events should appear as separate rows:

```sql
SELECT event_ts_ms, op, device_id, signal_strength
FROM mage_cdc.telemetry_events
WHERE device_id = 'test_device'
ORDER BY event_ts_ms;
```

Expected result — three rows:

```
event_ts_ms        op   device_id    signal_strength
1779615600000      c    test_device  50
1779615601000      u    test_device  99
1779615602000      d    test_device  99      ← the state at deletion time
```

---

## Querying the event log

### Current state of each device (latest event)

```sql
SELECT *
FROM (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY event_ts_ms DESC) AS rn
  FROM mage_cdc.telemetry_events
  WHERE op != 'd'
) t
WHERE rn = 1;
```

### Full history for a device

```sql
SELECT event_ts_ms, op, signal_strength
FROM mage_cdc.telemetry_events
WHERE device_id = 'device_3'
ORDER BY event_ts_ms;
```

### SCD Type 2 — valid intervals per device per state

```sql
SELECT
  device_id,
  signal_strength,
  event_ts_ms                                         AS valid_from_ms,
  LEAD(event_ts_ms) OVER (
    PARTITION BY device_id ORDER BY event_ts_ms
  )                                                   AS valid_to_ms,
  op
FROM mage_cdc.telemetry_events
ORDER BY device_id, event_ts_ms;
```

---

## Managing the Routine Load job

```sql
-- Pause
PAUSE ROUTINE LOAD FOR mage_cdc.load_telemetry;

-- Resume
RESUME ROUTINE LOAD FOR mage_cdc.load_telemetry;

-- Stop (permanent — create a new job to restart)
STOP ROUTINE LOAD FOR mage_cdc.load_telemetry;

-- List all jobs
SHOW ALL ROUTINE LOAD FOR mage_cdc\G
```

---

## Troubleshooting

### `State: PAUSED` immediately after creation

```sql
SHOW ROUTINE LOAD FOR mage_cdc.load_telemetry\G
```

Read `ReasonOfStateChanged` and `ErrorLogUrls`.

**"failed to fetch kafka partition offset"** — BE cannot reach the Kafka broker. Confirm the pod is healthy:
```bash
kubectl -n develop get pods | grep kafka
```

**"JSON path does not exist"** — The SMT may not be active yet. Consume a raw message and confirm it is flat (no `before`/`after` wrapper):
```bash
kubectl exec -it -n develop kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic mage.public.telemetry \
  --max-messages 1
```
If it still shows the envelope format, re-apply the connector update from Step 1.

### Rows appear but `op` column is always null

The `__op` field is missing from the messages — the SMT `add.fields` config wasn't applied. Re-run the `curl -X PUT` from Step 1 and verify the connector config:

```bash
curl -s http://localhost:8083/connectors/postgres-connector/config | grep transforms
```

### `Routine load job already exists`

Stop the existing job and recreate:
```sql
STOP ROUTINE LOAD FOR mage_cdc.load_telemetry;
-- Then re-run the CREATE ROUTINE LOAD statement
```

### `replication_num = 3 is invalid`

Always add `PROPERTIES("replication_num" = "1")` to `CREATE TABLE` in dev — only one BE is available.

---

## What's next

- **Decode binary fields** — `energy_usage`, `temperature`, `vibration` are base64 strings. Use `from_base64()` in a view or in the COLUMNS clause of the Routine Load to get the raw bytes, then interpret them according to your Postgres column type.
- **Add more tables** — For each Debezium-captured table, repeat Steps 4–5: create a `<table>_events` table and a matching Routine Load job pointing at `mage.public.<table>`.
- **Build the SCD2 layer** — Use the window-function queries above as the foundation for a materialized view or a scheduled StarRocks transform that produces the versioned dimension table.
