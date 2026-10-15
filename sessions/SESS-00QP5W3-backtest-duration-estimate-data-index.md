---
create_time: 2026-10-15T13:09:23Z
title: "Backtest duration estimate and downloaded market data index"
summary: "Backtest estimate: ~30 us/tick; per-file count facts aggregate like an event log, not a shared counter. Databento coverage/empty/missing index storage and transport remain open."
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
