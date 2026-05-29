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

## Step 1 — Verify the SMT is active

The `ExtractNewRecordState` SMT is already configured in `apps/kafka-connect/base/connector-configmap.yaml`. On a fresh cluster the `postStart` lifecycle hook on the Kafka Connect pod registers the connector with the SMT included — no manual step required.

Confirm the active connector config contains the transform:

```bash
make kafka-connect-pf
# in another terminal:
curl -s http://localhost:8083/connectors/postgres-connector/config | grep transforms
```

You should see `"transforms": "unwrap"` in the output.

Then verify messages on the topic are flat by inserting a test row in Postgres and consuming it:

```bash
kubectl exec -it -n develop kafka-0 -- \
  kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic mage.public.telemetry \
  --max-messages 1
```

You should see a flat JSON object — no `before`/`after` wrapper, `__op` and `__ts_ms` present at the top level.

> **If the connector was registered before the SMT was added** (e.g. an older cluster), force a config update:
> ```bash
> kubectl rollout restart deployment kafka-connect -n develop
> ```
> The `postStart` hook will run a PUT with the current ConfigMap, which includes the SMT.

> **Note on existing messages in the topic:** Messages produced before the SMT was applied remain in the old envelope format. The Routine Load starts from `OFFSET_END` (only new messages), so only flat-format messages are loaded.

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

### 4a — Verify Postgres column types

The `telemetry` table is created by `apps/postgres/base/configmap.yaml` with `energy_usage`, `temperature`, and `vibration` as `DOUBLE PRECISION`. On a fresh cluster these are already correct — Debezium emits them as plain JSON floats and no decoding is needed.

To confirm:

```bash
make postgres-pf
psql -h127.0.0.1 -U postgres -d mage \
  -c "\d public.telemetry"
```

If for any reason the columns show as `bytea` (an older deployment), migrate them:

```sql
ALTER TABLE public.telemetry
  ALTER COLUMN energy_usage TYPE DOUBLE PRECISION USING NULL,
  ALTER COLUMN temperature   TYPE DOUBLE PRECISION USING NULL,
  ALTER COLUMN vibration     TYPE DOUBLE PRECISION USING NULL;
```

### 4b — Create the StarRocks database and event log table

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
  energy_usage    DOUBLE,
  temperature     DOUBLE,
  vibration       DOUBLE,
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
| `energy_usage`, `temperature`, `vibration` DOUBLE | Postgres `DOUBLE PRECISION` → Debezium emits as a JSON float number, stored directly as `DOUBLE` |
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

## Step 7 — Generate streaming data with Mage AI

The platform includes two Mage AI pipelines for generating and ingesting realistic IoT data:

| Pipeline | Role |
|---|---|
| `lambda_iot_data_generator` | Produces fake IoT sensor readings to a message queue |
| `streaming_tutorial` | Consumes those messages and writes them into `public.telemetry` in Postgres |

Once rows land in Postgres, Debezium picks them up from the WAL and they flow through to StarRocks automatically.

### 7a — Port-forward Mage AI

```bash
make mage-ui
```

This forwards `svc/mageai` port 6789 to `localhost:6789`. Keep this terminal open.

### 7b — Run the data generator

Open http://localhost:6789 in a browser.

1. In the left sidebar click **Pipelines**
2. Click `lambda_iot_data_generator`
3. Click **Run pipeline now** (the ▶ button in the top-right)
4. Wait for the run to complete — it takes a few seconds and you will see a green checkmark on the run

This pipeline generates a batch of fake IoT sensor readings (random `device_id`, timestamps, `energy_usage`, `temperature`, `vibration`, `signal_strength`).

### 7c — Run the streaming consumer

Back in the Pipelines list:

1. Click `streaming_tutorial`
2. Click **Run pipeline now**
3. Wait for the run to complete

This pipeline consumes the messages produced by the generator and inserts them as rows into `public.telemetry` in the `mage` Postgres database.

### 7d — Verify rows reached StarRocks

Allow 5–10 seconds for Routine Load to pick up the new messages, then in the StarRocks session:

```sql
SELECT COUNT(*) FROM mage_cdc.telemetry_events;

-- Break down by operation type
SELECT op, COUNT(*) FROM mage_cdc.telemetry_events GROUP BY op;

-- Most recent events
SELECT event_ts_ms, op, device_id, signal_strength
FROM mage_cdc.telemetry_events
ORDER BY event_ts_ms DESC
LIMIT 10;
```

You should see rows with `op = 'c'` (INSERT events from the batch). Running the two pipelines multiple times will accumulate more rows in the event log.

---

### Alternative — manual SQL test (quick smoke test)

If you want to trigger all three operation types (`c`, `u`, `d`) without Mage AI:

```bash
make postgres-pf
psql -h127.0.0.1 -U postgres -d mage
```

```sql
-- INSERT → __op = 'c'
INSERT INTO public.telemetry (device_id, ts, energy_usage, temperature, vibration, signal_strength)
VALUES ('test_device', now(), 1.5, 22.3, 0.7, 50);

-- UPDATE → __op = 'u'  (payload = new row state)
UPDATE public.telemetry SET signal_strength = 99 WHERE device_id = 'test_device';

-- DELETE → __op = 'd'  (payload = deleted row state, from 'before')
DELETE FROM public.telemetry WHERE device_id = 'test_device';
```

Then in StarRocks:

```sql
SELECT event_ts_ms, op, device_id, signal_strength
FROM mage_cdc.telemetry_events
WHERE device_id = 'test_device'
ORDER BY event_ts_ms;
```

Expected — three rows:

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

### `Consume offset X is greater than the latest offset Y`

The job's checkpointed Kafka offset no longer exists — the topic was likely deleted/recreated or messages expired while StarRocks FE retained the old offset checkpoint. Stop and recreate the job to reset to `OFFSET_END`:

```sql
STOP ROUTINE LOAD FOR mage_cdc.load_telemetry;

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

`ALTER ROUTINE LOAD ... FROM KAFKA` is not supported in this StarRocks version — stop + recreate is the reliable path.

---

## What's next

- **Numeric fields** — `energy_usage`, `temperature`, `vibration` are stored as `DOUBLE PRECISION` in Postgres. Debezium emits them as plain JSON floats and StarRocks ingests them directly as `DOUBLE` — no decoding required.
- **Add more tables** — For each Debezium-captured table, repeat Steps 4–5: create a `<table>_events` table and a matching Routine Load job pointing at `mage.public.<table>`.
- **SCD2 layer** — Implemented in Step 8 as an async materialized view (`mage_cdc.telemetry_scd2`).

---

## Step 8 — SCD2 Materialized View

Build a versioned dimension table on top of the event log. Each row represents one state of a device with a `valid_from_ms` / `valid_to_ms` interval. `valid_to_ms IS NULL` means the row is still current.

```sql
CREATE MATERIALIZED VIEW mage_cdc.telemetry_scd2
REFRESH ASYNC
AS
SELECT
  device_id,
  signal_strength,
  energy_usage,
  temperature,
  vibration,
  op,
  event_ts_ms                                           AS valid_from_ms,
  LEAD(event_ts_ms) OVER (
    PARTITION BY device_id ORDER BY event_ts_ms
  )                                                     AS valid_to_ms,
  CASE
    WHEN LEAD(event_ts_ms) OVER (
      PARTITION BY device_id ORDER BY event_ts_ms
    ) IS NULL AND op != 'd'
    THEN TRUE
    ELSE FALSE
  END                                                   AS is_current,
  CASE
    WHEN LEAD(event_ts_ms) OVER (
      PARTITION BY device_id ORDER BY event_ts_ms
    ) IS NULL AND op = 'd'
    THEN TRUE
    ELSE FALSE
  END                                                   AS is_deleted
FROM mage_cdc.telemetry_events;
```

| Choice | Reason |
|---|---|
| `REFRESH ASYNC` | StarRocks refreshes automatically when `telemetry_events` receives new rows — no manual trigger needed |
| `is_current = TRUE` | Latest live state per device: `valid_to_ms IS NULL` and `op != 'd'` |
| `is_deleted = TRUE` | Device was deleted: last event is a `d` row with no successor — mutually exclusive with `is_current` |
| All metric columns included | Downstream consumers don't need to join back to the event log |

Check the MV is active (allow a few seconds):

```sql
SHOW MATERIALIZED VIEWS\G
```

Look for `is_active: true`.

### Queries

**Current state of all devices:**
```sql
SELECT device_id, signal_strength, valid_from_ms
FROM mage_cdc.telemetry_scd2
WHERE is_current = TRUE;
```

**Full version history for a device:**
```sql
SELECT device_id, signal_strength, valid_from_ms, valid_to_ms, op
FROM mage_cdc.telemetry_scd2
WHERE device_id = 'device_3'
ORDER BY valid_from_ms;
```

**Point-in-time state (what was device_3's state at a given ms timestamp):**
```sql
SELECT *
FROM mage_cdc.telemetry_scd2
WHERE device_id = 'device_3'
  AND valid_from_ms <= 1779652068856
  AND (valid_to_ms > 1779652068856 OR valid_to_ms IS NULL);
```

**Manual refresh (if needed):**
```sql
REFRESH MATERIALIZED VIEW mage_cdc.telemetry_scd2;
```
