# Backtest Result Artifact Design Report

Status: Working design; not an accepted specification or decision.

Purpose: Explore a versioned DuckDB artifact that persists one complete
`BacktestResults` feed and its derived portfolio metric time series.

## Source Material

- [Original schema prompt and initial proposal](schema.md)
- [Backtest feed specification](../../../../knowledge-base/docs/specs/SPEC-backtest-feed.md)
- [Demo app backtest view decision](../../../../knowledge-base/docs/decisions/records/DEC-09GKC-demo-app-backtest-view-and-reusable-chart.md)
- [Raw economic events decision](../../../../knowledge-base/docs/decisions/records/DEC-0A5FN-backtest-feed-emits-raw-economic-events.md)
- [Strategy performance feed decision](../../../../knowledge-base/docs/decisions/records/DEC-09S6G-strategy-performance-feed.md)
- [Trade volume reference](../../../../knowledge-base/docs/references/trade-volume.md)
- [Backtest results accounting issue](../../../../knowledge-base/docs/issues/records/ISS-09K80-backtest-results-accounting.md)

## 1. Problem Statement

The backtest post-processor needs one queryable artifact containing all facts
from one `BacktestResults` feed and the portfolio metrics derived by folding
those facts in feed order. The artifact must support interactive time-range
queries, final-statistic queries, replay, and audit without reading the original
transport file or external price sources.

The feed specification defines event meaning and order but explicitly excludes
persistence and derived metrics. This report explores that missing storage
design without making it a formal contract.

### Important boundary

This report proposes the artifact shape, storage invariants, metric
sampling boundary, validation, and publication lifecycle. It does not redefine
feed events, accounting formulas, market-info semantics, or UI rendering.

## 2. Goals And Non-Goals

### Goals

- Store exactly one backtest run per artifact.
- Persist every event variant from `SPEC:backtest-feed` without
  discarding fields required for replay or audit.
- Preserve feed order through `feed_orderand`; timestamps do not
  replace feed order.
- Store compact definition references and typed, queryable event
  columns.
- Store derived portfolio metrics as an ordered time series.
- Store raw fee events and cumulative fees separately.
- Make schema, metric-semantics, writer, enum, and artifact-state
  versions discoverable before consumers query fact tables.
- Reject non-finite floating-point values.
- Publish only complete, validated artifacts.

### Non-Goals

- Defining metric formulas that are still open in §8.
- Storing multiple backtests in one DuckDB file.
- Replacing the original feed's semantic contract.
- Persisting external price data not carried by `PricesUpdate`.
- Adding live-deployment feed stitching or ClickHouse storage.
- Precomputing UI-resolution-specific chart buckets.

## 3. System Overview

### 3.1 Components

1. **Artifact Writer** — folds the ordered feed, writes raw event rows and
   derived metric snapshots to a temporary DuckDB file, then publishes it.
2. **Artifact Validator** — checks schema, envelope/subtype consistency,
   dictionary references, event order, terminal state, and metric validity.
3. **Artifact Reader** — opens only a complete artifact, checks its manifest,
   and issues bounded analytical queries.

### 3.2 Sources Of Truth

| Data | Source of truth | Artifact role |
|------|-----------------|---------------|
| Event identity, order, tracing | `feed_events` | Persisted fact |
| Event payload | Matching event subtype table | Persisted fact |
| Definition dictionaries and market info | Definition tables | Persisted fact |
| Portfolio/accounting state | Fold over persisted feed events | Derived, not authoritative |
| Metric snapshots | Fold over persisted facts | Rebuildable projection |
| Final metrics | Last metric snapshot | View, not separately stored |

### 3.3 Primary Flow

```mermaid
sequenceDiagram
    participant Feed as BacktestResults
    participant Writer as Artifact Writer
    participant Validator as Artifact Validator
    participant Reader as Artifact Reader

    Writer->>Writer: create temporary DuckDB; state = Writing
    loop until BacktestJobCompleted
        Feed->>Writer: next event in feed order
        Writer->>Writer: persist envelope + typed payload
        Writer->>Writer: fold state; append metric snapshot when required
    end
    Writer->>Validator: validate complete artifact
    Validator-->>Writer: valid
    Writer->>Writer: state = Complete; checkpoint; close; publish atomically
    Reader->>Reader: open read-only; validate manifest
```

## 4. Core Domain Model

### 4.1 Artifact

One artifact contains exactly one definition event, zero or more non-terminal
events, exactly one completion event, and no event after completion.

### 4.2 Feed Event Envelope

`feed_events` stores the common event identity:

| Field | Type | Rule |
|-------|------|------|
| `event_id` | `u32` | Unique within the run. |
| `feed_orderand` | `u64` | Unique ordering key within the feed. |
| `trace_id` | `u64` | Engine trace identity. |
| `event_kind` | `i8` | Selects exactly one payload table. |

`event_id` and `feed_orderand` remain separate even if one implementation gives
them the same numeric value.

### 4.3 Definition Dictionaries

Accounts, assets, contracts, instruments, and data feeds are stored once and
referenced through zero-based `u16` dictionary references. The writer preserves
the definition order when assigning references.

### 4.4 Metric Snapshot

A metric snapshot is the portfolio metric state after folding through one
`feed_orderand`. `sample_time` supports time-range queries, while
`as_of_orderand` is the unique ordering and audit key.

All `_abs` metric fields are expressed in the definition's valuation asset.
All ratio fields are fractions: `0.05` means five percent.

## 5. Canonical DuckDB Schema

The executable draft is
[`backtest-result-artifact-v1.sql`](backtest-result-artifact-v1.sql).
It is the complete schema proposed by this report and executes against DuckDB
v1.5.5.

### 5.1 Type Rules

- Signed integers use the `i8`, `i16`, `i32`, `i64`, and `i128` aliases.
- Unsigned integers use the `u8`, `u16`, `u32`, `u64`, and `u128` aliases.
- Stored decimal values use `f32`.
- Numerically sensitive metric folds may compute in `f64` before the final
  checked `f32` conversion.
- Simulated and wall-clock timestamps use `nanosecond`, an alias for `u64`.
- Plain closed enum projections use `i8` and are described by `enum_variants`.
- DuckDB's built-in `STRING` alias is used directly. The schema must not attempt
  to recreate it.

### 5.2 Table Families

| Family | Tables |
|--------|--------|
| Manifest | `artifact_manifest`, `enum_variants` |
| Envelope | `feed_events` |
| Definition | `backtest_definition_events`, `accounts`, `assets`, `contracts`, `instruments`, `data_feeds`, `market_info`, `spot_market_info`, `perp_market_info` |
| Lifecycle | `backtest_metrics_events`, `backtest_job_completed_events` |
| Source and strategy | `triggering_source_events`, `target_positions_events`, `target_position_items`, `runtime_events` |
| Economic facts | `fill_events`, `deposit_events`, `fee_events` |
| Venue observations | `trading_account_position_update_events`, `derivative_position_items`, `spot_position_items` |
| Prices | `prices_update_events`, `price_update_items` |
| Derived | `metric_snapshots` |
| Views | `event_timeline`, `final_metrics`, `backtest_summary` |

## 6. Storage Invariants

- Each `feed_events` row has exactly one row in the payload table
  selected by `event_kind`, and no row in any other payload table.
- Every payload row has one matching `feed_events` row.
- Definition and completion tables each contain exactly one row in a
  complete artifact.
- Definition is the lowest `feed_orderand`; completion is the highest.
- `feed_orderand` strictly increases in persisted feed order.
- Every dictionary reference resolves to its matching dictionary
  kind.
- `market_info` has exactly one row per instrument and exactly one
  matching spot or perp detail row selected by `market_kind`.
- Repeated event items use a zero-based ordinal unique within their
  parent event.
- Every persisted `f32` is finite; infinity and NaN are invalid.
- A metric snapshot's `as_of_orderand` resolves to the last feed
  event included in that snapshot.
- Rows are inserted in increasing `feed_orderand` order so DuckDB
  zone maps and compression benefit from physical ordering.
- Subtracting timestamps requires either a proven
  `later >= earlier` precondition or conversion to a signed type before
  subtraction; unsigned underflow is an error.

## 7. Metric Sampling Contract

### 7.1 Snapshot Triggers

The writer appends a metric snapshot after folding an event that can change a
displayed metric:

- `PricesUpdate`;
- `Deposit`;
- `Fill`;
- `DemoOnlyFee`;
- `TargetPositions`; and
- `BacktestJobCompleted`, which forces a terminal snapshot.

Multiple snapshots may have the same `sample_time`. They remain distinct by
`as_of_orderand`.

### 7.2 Fee Storage

`fee_events.fee` stores each raw fee fact. `metric_snapshots.total_fees_abs`
stores the cumulative total after folding through `as_of_orderand`. The terminal
total is the `total_fees_abs` value from `final_metrics`; it is not separately
stored.

### 7.3 Final Metrics

`final_metrics` returns the metric snapshot with the greatest
`as_of_orderand`. Consumers must not infer final metrics by selecting the row
with the greatest timestamp.

## 8. Open Metric Semantics

The schema is executable, but the following behaviors remain open and need a
decision before implementation:

1. `DemoOnlyFee::fee` does not declare its asset or unit. The feed must either
   add `fee_asset_ref` or require every fee to be expressed in the valuation
   asset before `total_fees_abs` can be computed soundly.
2. `target_position_change_count` must define whether it counts envelopes,
   entries, or entries whose folded target value differs from the previous
   value.
3. `return_abs` and `pnl_abs` must define their difference once non-initial cash
   flows exist.
4. High- and low-watermark ratios and absolute/ratio drawdown sign conventions
   must be fixed.
5. `turnover_ratio` needs a denominator and time-window definition.
6. Calmar and Sortino need formulas, annualization inputs, target/risk-free
   rates, and degenerate-input conventions.

Until items 5 and 6 are resolved, their columns remain nullable. `NULL` means
the metric is not defined for that prefix; it never means zero.

## 9. Artifact Lifecycle

| State | Meaning | Permitted next state |
|-------|---------|----------------------|
| `Writing` | Temporary artifact accepts ordered events. | `Writing`, `Complete`, or deletion on failure. |
| `Complete` | Validation passed; artifact is immutable and readable. | `Complete`. |

- The writer creates and mutates only a temporary artifact.
- Any ingest, fold, validation, checkpoint, or close failure prevents
  publication.
- Publication sets `artifact_state = Complete`, records the terminal
  orderand and publication time, checkpoints, closes, then atomically moves the
  file to its final location.
- Readers reject artifacts whose manifest is missing, unsupported, or
  not `Complete`.
- A complete artifact is immutable. Reprocessing creates a new
  temporary artifact and replaces the published artifact only after validation.

## 10. Replay And Audit

- Replay reads `feed_events` in `feed_orderand` order and joins each
  row to its selected payload table.
- Replaying raw tables from zero must reproduce every metric
  snapshot for the same metric-semantics version.
- Derived tables are rebuildable projections and are never the
  source of truth for economic events.
- A mismatch between replayed and stored metrics rejects the
  artifact during validation.
- Source payload bytes, compression, uncompressed size, feed
  reference, identity, trace, order, and provenance remain available for audit.

## 11. Failure Model

| Failure | Required behavior |
|---------|-------------------|
| Unsupported schema or metric version | Reader rejects before querying fact tables. |
| Duplicate or decreasing orderand | Writer rejects the event; artifact is not published. |
| Missing or mismatched payload subtype | Validation fails; artifact is not published. |
| Unresolved dictionary reference | Writer rejects before inserting the payload. |
| Non-finite `f32` or failed `f64` to `f32` conversion | Metric/event calculation fails; artifact is not published. |
| Event after completion | Writer rejects the event; artifact is not published. |
| Missing completion | Artifact remains temporary and is not published. |
| Metric replay mismatch | Validation fails; artifact is not published. |
| DuckDB write/checkpoint/close failure | Artifact is not published. |

## 12. Test And Validation Matrix

- The complete SQL executes against the
  supported DuckDB version from an empty database.
- One fixture per event kind round-trips every
  semantic field through its typed table.
- An event with zero or multiple payload subtype
  rows fails validation.
- Duplicate/decreasing orderands and an event
  after completion fail publication.
- Invalid dictionary references and invalid
  discriminated nullable-field combinations are rejected.
- NaN, positive infinity, negative infinity,
  and overflowing `f64` to `f32` conversions are rejected.
- Multiple state changes at one timestamp create
  distinct metric snapshots ordered by `as_of_orderand`.
- Cumulative fees at every snapshot equal the
  fold of raw `fee_events` through that orderand.
- `final_metrics` selects by orderand, not time.
- Raw replay reproduces stored metric snapshots
  for a hand-computed fixture.
- Failure before publication leaves no readable
  final artifact.
- A complete artifact opens read-only and its
  manifest, summary, timeline, and final-metrics views are queryable.
- Property: random valid event sequences preserve envelope/payload
  cardinality, dictionary resolution, and replay equivalence.
- Property: random valid timestamp pairs never subtract unsigned
  values without the required order proof or signed conversion.

## 13. Definition Of Done

- [ ] Canonical SQL passes an empty-database DuckDB execution test.
- [ ] All eleven `BacktestResultEvent` variants are persisted.
- [ ] Envelope/subtype exclusivity validation is implemented.
- [ ] Definition dictionaries and market-info union validation are implemented.
- [ ] Metric snapshot triggers and orderand semantics are implemented.
- [ ] Raw fee and cumulative fee storage are both implemented.
- [ ] Open metric semantics in §8 are resolved and tested.
- [ ] Replay produces byte-for-byte-equivalent keys and numerically equivalent
      derived metrics for the declared semantics version.
- [ ] Temporary artifact failure and atomic publication are tested end to end.
