---
create_time: 2026-10-15T13:09:23Z
title: "Backtest duration estimate and downloaded market data index"
summary: "Backtest estimate = ticks x 30 us (cloud logs). D1 record_count in object metadata; D4 app-server validates + alerts, client AI agent API; D5 download job counts ticks + coverage; D6 30-min buckets; D7 ClickHouse event log via event-gw; D8 Pub/Sub; D9 alert from app-server validation; D10 planning in application-server-core (Rust/WASM). Open: coverage for self-recorded streams."
related_sessions:
  - SESS-00PYCE2
  - SESS-00QE2QN
  - SESS-00QNZ2Y
  - SESS-00QGNFK
agents:
  - claude-code:18bf329f-b1dc-4a1f-a6e1-e35acb453117
  - claude-code:21f40ea2-707d-445d-950a-33b98333029b
  - codex:01a13fae-7ad6-7aa2-a879-378ff8fb0847
---

# SESS-00QP5W3: Backtest duration estimate and downloaded market data index

## Context (user, 2026-10-15)

- Goal: show users an estimated backtest run time, and improve our own
  estimates (ties to the per-backtest job timeout in SESS-00QNZ2Y).
- Measured by the user: about 30 µs per backtest tick.
- Historical files are already downloaded, so the amount of data is known.
- Proposed formula: ticks in the requested time range x 30 µs + a buffer for
  initialization and post-processing.
- Needed: an index of downloaded files with
  - which time ranges were downloaded,
  - which of them are empty (no market activity),
  - which time ranges are missing (not downloaded),
  - how much data each file holds (record count).
- User's starting ideas, not decided:
  - extend `databento-mkt-data-download-job` to count records while it
    downloads and write the count somewhere;
  - not one shared index file in the bucket (locking and races);
  - a WAL plus a single merging process, or a NATS message per uploaded file
    plus a collector that keeps a file or a database.

## Findings (2026-10-15, research agents; facts, not decisions)

- Bucket layout (REF:databento-market-data, DEC-0BPWJ R14):
  `data/databento/{dataset}/{schema}/{InstrumentId}/{YYYY-MM-DD}.dbn.zst`,
  one object per (dataset, schema, contract, UTC day). Uploads are
  create-only (`ifGenerationMatch=0`), so objects are immutable. No custom
  object metadata today; listing reads only `items(name)`.
- The three states already exist in the bucket: object with records = data,
  header-only object (62 bytes, no symbol) = no activity, no object = not
  downloaded (replay planner fails with `HistPlanError::MissingFile`).
  "Missing" has no stored form; the job's planner derives expected
  (market, schema, day) from market-info per run.
- The job copies bytes and decodes only the DBN header. Databento's batch API
  gives byte size + sha256 per file, record_count only per job, so per-file
  record counts need a decode pass.
- Writers: scheduled `databento-download-job` (1 task, 8 workers, */30 6-14),
  `databento-backfill-job`, local `just backfill` driver (up to 10k tasks).
  Day sharding within an execution; scheduled and backfill jobs may race on
  the same key, safe only due to create-only uploads.
- Backfill counted 892,458 objects (1.41 GB), ~60% header-only.
- No JetStream (core NATS only, DEC-08T3R), no GCS Pub/Sub object
  notifications, no BigQuery. Postgres belongs to application-server only
  (REF:application-db). ClickHouse (timeseries-db) has no file table.
- Tick = one DBN record in the window, k-way merged across routes by
  timestamp; mbp1 and trade source events share one MBP-1 file per
  instrument. Whole first day is decoded from midnight even when the start is
  mid-day; reading stops at the stop time. Status seed reads up to 7 prior
  days.
- `strategy.backtest.summary` logs `feed_ticks`, `replay_elapsed_ms`,
  `avg_ns_per_feed_tick` (run.rs). PLAN-0BRQ8 local measurement: ~1.9 µs per
  tick (ESU6 MBP-1, 2 days, macOS arm64), vs the user's 30 µs (cloud).
- structure-web `BacktestService.create` knows identities/sourceEvents but
  not the Rust route-to-schema plan (`plan.rs`, `hist_replay.rs`).

## Decisions

### D1: `record_count` lives in the object metadata of each day file (2026-10-15)

The user: "Put record_count into the GCS metadata". Applies to every
`{dataset}/{schema}/{InstrumentId}/{YYYY-MM-DD}.dbn.zst` object written by
`databento-mkt-data-download-job` (and the backfill job). Header-only files
carry `record_count = 0`.

Constraint given with it: "We're probably going to use the Backblaze B2 as
the primary storage for our historical data." So the metadata must work on
B2 too. Researched (not decided): B2 supports custom file info (native API
`X-Bz-Info-*`, S3 API `x-amz-meta-*`), 7000 bytes with the name (2048 with
SSE or Object Lock); it is set at upload, and changing it means a
server-side copy with `metadataDirective=REPLACE` (new file version).
`b2_list_file_names` returns `fileInfo` per file (1000 per billed call);
S3 `ListObjectsV2` does not return user metadata. B2 Event Notifications
(GA) POST to a webhook, at least once. Consequence: the agent's earlier
"upload, then patch metadata" proposal does not carry over to B2.

### D2: Record and coverage data are needed soon, for two consumers (2026-10-15)

The user: "I need the data about the records and coverage as soon as we can
get it, since the ai agent on the client that runs the backtests needs to
know what it can use and the application server has to validate". Consumers:
the client AI agent (what data it can use for a backtest) and
application-server (validation at backtest create). This makes a queryable
coverage view a near-term need, not a later option.

## Open questions (proposals put to the user, nothing decided)

- Where per-file stats live: GCS custom metadata on the object itself
  (proposed) vs a database/index file.
- Who counts: download job tees the stream through a zstd/DBN decoder and
  patches metadata after finalize (proposed) vs a separate indexer fed by GCS
  object notifications.
- Granularity: per-day total plus 24 hourly counts (proposed) for mid-day
  windows.
- Whether a queryable index (e.g. ClickHouse table) is needed now, or later
  as a rebuildable projection of the bucket.
- Where the estimate is computed (TS server lacks the Rust plan).
- Per-tick cost: one global 30 µs vs calibrated from actual runs per strategy.

## Note on agents (2026-10-15)

Several research agents work on this topic at the same time and share this
record. Each agent appends its own sections and re-reads the file before
writing. Agent claude-code:21f40ea2 joined for the brainstorm below.

## Context (user, 2026-10-15, agent claude-code:21f40ea2)

- Goal: an estimate of a backtest's run time, for the UI and for our own
  planning. Measured cost about 30 µs per replayed tick. Estimate = ticks in
  the selected files x 30 µs + a buffer for initialization and
  post-processing.
- Needs an index of the downloaded Databento objects: which time ranges are
  downloaded, which of them are empty (no activity), which ranges are
  missing, and how much data (ticks) each file holds.
- User's first thoughts: extend `databento-mkt-data-download-job` to count
  while downloading and write the count somewhere; not one shared file in
  the bucket (locking, races). Candidates: per-writer WAL entries merged by
  one process; a NATS message per stored file consumed by a collector that
  keeps a file or a database.
- Known state (SESS-00QE2QN): done per object (market, schema, UTC day),
  markers removed; empty days are 62 byte header-only DBN files; ohlcv-1m
  backfill holds 892,458 objects, about 60% empty; a full `gcloud storage
  ls` of one schema takes 20 minutes.

## User clarification (2026-10-15, Codex)

- Reports should describe each file written, whether daily, hourly, or by
  minute, and aggregate to the correct count. The user described this as
  an event log, not a direct mutation of a counter.
- The question about partial-day estimates was misunderstood as referring
  to the current day's data. Codex clarified that it concerns a requested
  interval cutting through an existing file (10:00–11:00 within a daily
  file). No preference about approximate boundary counts has been decided.
- Storage, transport, collector ownership, and count granularity remain
  open; no implementation authorized.

## Codex research coordination and findings (2026-10-15)

- Joined the existing record; three concurrent research agents inspected
  downloading, replay semantics, and catalog/storage options. Other harness
  research agents also share this record. No production code or knowledge
  base artifacts changed.
- Downloader already produces header-only DBN objects for empty days and
  uses per-object completion. Currently it reads only DBN metadata before
  forwarding compressed bytes; counting requires full streaming decoding.
- GCS JSON resumable uploads support custom metadata on the final request
  (X-Goog-Meta-*). This permits publishing file and computed count together.
  Source: https://docs.cloud.google.com/storage/docs/performing-resumable-uploads
- Proposal, not accepted: per-object statistics + GCS OBJECT_FINALIZE to
  Pub/Sub + rebuildable Postgres catalog. Native notifications remove the
  downloader's upload-then-publish crash window. Duplicate/out-of-order
  events require idempotency and current-version handling; GCS generation
  is identity, not a monotonic ordering. Reconcile from bucket metadata.
- BacktestSummary already exposes replay_elapsed, total_feed_ticks, and
  avg_ns_per_feed_tick. Setup/shutdown are excluded. File record counts
  require replay-aware range/filter handling (status snapshots excluded,
  bars timestamped at close); 30 us is an initial calibration assumption.

## Findings (agent claude-code:21f40ea2, 2026-10-15)

Download job (`databento-mkt-data-download-job`, main):
- `core/transfer.rs` streams each Databento file in 8 MiB pieces straight
  into a GCS resumable upload; SHA-256 and CRC32C are updated per piece.
  Only the DBN header is decoded (dataset, schema, one id, one UTC day).
  No record is decoded or counted; no custom object metadata is set
  (`adapters/gcs.rs` POST carries only content length and type).
- The DBN header has no record count: dbn 0.68 writes `NULL_RECORD_COUNT`
  (u64::MAX) and decoders skip it. Databento's batch job carries a total
  `record_count` per job, not per file. Counting needs the decompressed
  bytes.
- Listing uses `fields=items(name)` only; `for_instrument_days` lists one
  (schema, instrument) prefix per call; at most 8 pages of 1000.
- Uploads are create-only (`ifGenerationMatch=0`). Empty day = header-only
  zstd DBN, 62 bytes, same name shape as a data file.
- The job publishes nothing to NATS or Pub/Sub. Per file it logs
  `download_job.transfer.file_done object= outcome=` with no sizes.
- `bin/costs.rs` and `bin/backfill.rs` compute no data statistics.

Backtest side (`structure-strat-template-core`):
- `hist_replay.rs::plan_hist_streams` lists every UTC day file of each route
  (`databento/{dataset}/{schema}/{InstrumentId}/{day}.dbn.zst`) from
  `min_ts - bar_interval` to `max_ts`; status seeds look back 7 days;
  `definition` is never replayed. Every target adds MBP-1 for its instrument.
- Files are read through the Cloud Run GCS volume mount (FUSE), not the
  API. Each file in the window is decoded in full; records before `min_ts`
  are decoded then dropped. So the cost unit is the whole day file, even
  when the window starts mid-day.
- The only presence check is `path.exists()` inside the job (first missing
  file only, `HistPlanError::MissingFile`). The API checks nothing before
  launching.
- Measured per-tick cost already exists: `strategy.backtest.summary`
  logs `feed_ticks`, `replay_elapsed_ms`, `avg_ns_per_feed_tick`
  (`backtest.rs:105-119`, `backtest/run.rs:116`). PLAN-0BRQ8 recorded
  1,917 ns per tick locally (ESU6 MBP-1, two days, 17.6M ticks). The 30 µs
  figure appears only in the user's prompt. The results feed carries
  `BacktestMetrics.input_events_processed_total` + `elapsed_wall_clock`
  every 10 s of simulated time; structure-web surfaces no progress or ETA.
- No KB record covers a data index or an estimate (DEC-0BPWJ R14 and
  REF:databento-market-data describe the layout and the done rule).

## Proposals (agent claude-code:21f40ea2, 2026-10-15, no decisions yet)

P1. Count in the transfer pass: feed every piece into a streaming zstd
decoder and walk DBN record headers (`length` in 4-byte units, `ts_event`
at bytes 8..16). Yields record count, first and last ts_event per file for
every schema, no dbn decode, no extra read. Alternatives rejected: zstd
frame content size (absent in streamed frames), Databento
`metadata.get_record_count` per file (one API call per object).

P2. Truth stays in the bucket: write the counts as custom metadata on the
object itself (`record_count`, `first_ts`, `last_ts`, `counter_version`,
`dbn_version`) in the same create-only upload. Atomic with the object, no
second writer, no race; a listing with `fields=items(name,size,metadata)`
returns the whole index for a prefix in one call. Header-only files get
`record_count=0`. Existing objects get a one-off backfill job (62-byte
objects need no read; PATCH metadata only).

P3. Materialized index as a derived snapshot: a scheduled indexer job lists
every (schema, instrument) prefix in parallel (about 6,000 calls, minutes)
and writes a single SQLite (or Parquet) snapshot under `index/` plus a
`latest` pointer swapped with a generation precondition. Rebuildable from
scratch, single writer by construction, no deltas to merge, no lost
updates. "Missing" is not stored: it is expected set (market-info
activation..termination x the job's schema and product policy) minus
present rows; the policy is copied into the snapshot as a config record.

P4. Per-(schema, instrument) manifest objects kept by the download job with
read-modify-write under `ifGenerationMatch` (retry on 412). No merger,
cheap for the estimate (N GETs), readable through the FUSE mount by the
runner. Contention is rare (scheduled job vs backfill on one contract).

P5. Delta files per task + merger (user's WAL idea): works, but adds a
merger process and a "merged up to" cursor for no gain over P2 + P3,
because the bucket already is the append-only log.

P6. NATS event per stored file + collector + database: deferred. The job
has no NATS client, Cloud Run jobs would need the network path, at-least-
once delivery forces idempotent upserts, and the collector's database
drifts from the bucket unless rebuilt from a listing anyway. Revisit when
the engine monitoring NATS (SESS-00QKRBE) exists and live consumers need
the "file stored" event.

P7. Estimate model: T = setup (plan + channels ready, measured by
`backtest.channels.ready`) + sum over planned day files of ticks x c +
post-processing. c calibrated per strategy revision (or globally) from the
`strategy.backtest.summary` numbers of finished runs, stored in
results_summary; MBP-1 dominates, bars and status are at most 1,440 and a
few records per day. Count whole day files, as the replay does. Surface it
as `estimated_duration` on the backtest at create time and as progress
(input_events_processed_total / expected ticks) while running.

Open questions for the user: whether P4 or P3 serves the app server
(TS) and the runner (FUSE) better; where the per-strategy calibration
constant lives; whether the estimate should block or warn on missing files
at create time (today the job fails at plan time).

## Decisions from the refined brief (2026-10-15, agent claude-code:18bf329f)

Source: the user's restated brief in conversation 18bf329f. Numbered D3+
after D1-D2 above.

### D3: 30 µs per tick is a cloud measurement

The user saw about 30 µs per tick in the logs of the Cloud Run backtest jobs
(resolves "appears only in the prompt" above). Estimate = ticks of all data
files in the backtest's time range x 30 µs.

### D4: Two consumers, with behaviour

- application-server validates before submitting a backtest that every
  requested data feed has data. If not: return an error AND publish an alert
  so customer success follows up and decides whether to download the data.
- The client AI agent gets an API to ask about data availability.

### D5: Count while downloading, store ticks and time coverage

`databento-mkt-data-download-job` computes the tick count and the time
coverage of each file as it downloads ("we could have some additional work
done apart from just copying buffers"). Files are immutable once downloaded.

### D6: 30-minute aggregation granularity

Counts are aggregated in 30-minute buckets, because users run backtests on
custom time ranges and 30 minutes gives a close enough estimate. (Replaces
the hourly-count proposal above; that was never decided.)

### D7: Event log + derived values, in ClickHouse, consumed by Rust (event-gw)

- Rejected: a single file in the bucket that everyone mutates ("a lock and
  race condition disaster"). This rules out per-contract manifests with
  read-modify-write (P4 above).
- Wanted: full traceability. Store the event log; derive computed values
  from it. Analytical database; ClickHouse is the candidate.
- Aggregations need not be stored; ClickHouse computes them on the fly.
- Pure Rust implementation, probably in event-gw.
- The user is unsure whether ClickHouse can do gap detection (open).
- D1 (record_count in object metadata) is not mentioned in this brief and is
  not withdrawn; whether to keep it as a recovery path is open.

### Open: transport from the download job to the event log

User's two candidates: (1) WAL files written to the bucket, collected by a
process; (2) events published to Pub/Sub, consumed directly by event-gw.

## Findings for D4/D7 (agent claude-code:18bf329f, 2026-10-15)

- event-gw consumes Pub/Sub via `ipc` (`gcloud-pubsub`), routes by
  subscription (`pubsub-feeds`, closed `PubSubFeed` enum), acks only after
  ClickHouse replies Persisted/BackedUp; prod sub `event-log-sub` has DLQ
  (5 attempts), no exactly-once, default retention. No dedupe on ingest.
- event-gw writes ClickHouse with vendored `clickhouse` 0.15.2; no insert
  dedup tokens. Feed tables are ReplacingMergeTree; `event_logs` plain
  MergeTree; reads dedupe with `LIMIT 1 BY`. Schema:
  `timeseries-db/clickhouse/schema.sql` (submodule `event-gw/crates/db`);
  nothing applies it in prod (manual on ClickHouse Cloud).
- event-gw has no read API. application-server already queries ClickHouse
  directly (`@clickhouse/client`: logs, positions). No gap-fill or window
  SQL anywhere yet.
- event-gw market-info repo keeps markets only (no schedules); futures have
  `activation_time`, `trading_termination_time`, `trading_schedule_id`.
- Alerts from application-server: `argus.alert(...)` -> alerts feed ->
  notify-gw -> one Discord webhook (structure-web#183, unmerged; main still
  uses Topic.Alerts). No customer-success channel exists; tags only colour.
- Client AI agent: `stxr-client-app/src/vs/platform/stxrAgent/`, single
  tool `execute_platform_code` over capabilities (Markets: list, search,
  getByInstrumentId, ...; Backtests: create, run, ...). A new op needs a
  common type, browser impl, skill doc, app-server route, regenerated client.
- Download job has no Pub/Sub dependency; production Rust publishers use
  `gcloud-pubsub` 1.5.1. New event kind = feed module in
  data-feed-definitions + filtered subscription + IAM grant for
  `databentoDownloadJobAccount`.

## Proposals (agent claude-code:18bf329f, 2026-10-15, not decided)

- Q1 Event: `MarketDataFileStored` per stored day file: dataset, schema,
  instrument_id, day, object key, size, sha256, record_count, first/last
  replay ts, 48 half-hour counts keyed by replay timestamp (ts_recv for
  MBP-1/status, bar close for OHLCV), counter_version, producer.
- Q2 Transport: Pub/Sub -> event-gw (ack after insert) over WAL objects in
  the bucket (polling, cursor, listing cost, storage credentials in
  event-gw). Crash window between upload and publish closed by a reconcile
  run that re-emits events from object metadata (D1) - also backfills the
  ~900k existing objects.
- Q3 Table: plain MergeTree append-only log (every delivery kept for
  traceability), dedupe at read with `LIMIT 1 BY (dataset, schema,
  instrument_id, day)`.
- Q4 Gaps: request validation = day range generated in SQL anti-joined with
  stored files (no expected set needed). Catalog coverage = islands of
  consecutive stored days (gaps-and-islands with row_number). "Missing
  within contract life" = intersect with market-info activation/termination
  in application-server.
- Q5 Reads: application-server queries ClickHouse (existing pattern) for
  validation, estimate, and a new Markets op for the client agent; event-gw
  stays write-only.
- Q6 Alert: `argus.alert("backtest_service.create.data_missing")`; CS
  channel needs routing in notify-gw (open).

## Decisions (agent claude-code:18bf329f, 2026-10-15, continued)

### D8: Transport is Pub/Sub

`databento-mkt-data-download-job` publishes one event per stored file to
Pub/Sub; event-gw consumes it into ClickHouse. Rejected: WAL objects in the
bucket collected by a process (user picked "pubsub" over it; the agent's
reasons were polling, cursor, listing cost, storage credentials in
event-gw). Proposal Q2 above (reconcile from object metadata, D1) was put
with it; not separately confirmed.

### D9: application-server raises the missing-data alert during backtest validation

The alert is published by application-server while it validates a backtest
(before submitting the job). The customer-success channel/routing question
(notify-gw has one Discord webhook) was not answered.

### D10: The feed/file planning for validation lives in application-server-core (Rust)

The logic mapping a strategy's feeds to (schema, instrument, time range)
(today `plan.rs` / `hist_replay.rs` in structure-strat-template-core) is
used by application-server through `application-server/crates/
application-server-core` (Rust compiled to WASM, no I/O, loaded with the
market-info archive). Rejected implicitly: porting it to TypeScript.

### Open: coverage for our own recorded (streamed) data

User asked how a 5-minute recorder downtime (nothing written) would be
detected if we record historical data ourselves from the live stream, or
whether that is irrelevant while only whole Databento day files are
ingested. Agent proposal (not decided): carry an explicit covered interval
[covered_from, covered_to) on every event now (Databento files = the UTC
day), so coverage is a positive claim by the producer and gaps are computed
over intervals; a recorder would claim only periods it was connected and
gap-free (heartbeats, sequence numbers, periodic checkpoints).

### Findings on "how do we know a period is covered" (agent claude-code:18bf329f)

- Databento historical: `metadata.get_dataset_condition` gives per day
  `available | degraded | pending | missing` plus `last_modified_date`
  (databento 0.60 `DatasetCondition`). The download job checks only
  `get_dataset_range` (`available_range`), not the condition, so today a
  stored file is taken as full coverage without the vendor's quality claim.
  `last_modified_date` means Databento can regenerate a day after we stored
  it (our files are create-only).
- Databento live: heartbeat SystemMsg when no data (interval 5-1800 s);
  `SlowReaderWarning`; with `slow_reader_behavior=skip` (default for MBP-1
  from 2026-04-26 per Databento blog) the gateway drops records and sends
  ErrorMsg `SkippedRecordsAfterSlowReading` (code 7); `EndOfInterval` for
  interval schemas.
- Proposal (not decided): coverage is a claim made by the producer from
  evidence; Databento files: vendor condition `available` for the day + our
  sha256 match; recorder: an unbroken session (subscription ack, no
  disconnect, no message gap above heartbeat interval + slack, no code 7 /
  slow-reader skip) whose records are durably stored before the claim.
- Databento `degraded` has no time range: the API row is (date,
  condition, last_modified_date) for the whole dataset on that UTC day, not
  per schema or instrument. Details live only as free text in Databento's
  issues tracker (issues.databento.com, e.g. "Degraded GLBX.MDP3 data on
  2024-08-09", "Degraded dates prior to 2024-12-09 can have stuck orders").
  Proposal (not decided): store the condition as a day-level quality flag on
  the coverage (covered but degraded), warn rather than block; our own
  30-minute counts against the trading schedule can hint where in the day.
