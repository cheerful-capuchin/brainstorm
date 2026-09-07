# Decision: Bucket Structure for Databento Historical Market Data

Date: 2026-09-20
Status: accepted (demo scope)
Related: [Backtest Historical Replay walkthrough](../2026-09-20-hist-replay.md)

## Context

The backtest and warmup regimes in `structure-strat-template-core` replay historical market data
through the strategy ingress. Today the data comes from hourly Apache Arrow files read by
`ArrowFileProvider` (`dsl-runtime/src/hist_data.rs`). The Arrow files are going away. The new
source is Databento historical data, and the consumer is the Databento market data feed declared
in `data-feed-definitions/.../demo/databento_mbo_feed.rs`.

Facts this decision relies on, all established in the walkthrough:

- The feed codec accepts only MBP-1 records and routes `action == T` records to the trade handler.
  MBP-1 contains every trade, so one MBP-1 stream per instrument covers both feed events.
- The feed payload is a `DbnMdUpdate` envelope: the domain instrument id plus the raw DBN record
  with `ts_out` (88 bytes, `WithTsOut<Mbp1Msg>`).
- Historical records from Databento have no `ts_out`. It exists only on the live gateway.
- A Databento request returns one schema, and a DBN file header carries one schema.
- The replayer wants one ordered stream per instrument and merges across instruments itself.

This is demo scope: the product has to work, with the least work that gets there.

## Decision

### Object path

```
gs://stxr-prop-asia-historical-data-qmdzj/databento/{dataset}/{schema}/{InstrumentId}/{YYYY-MM-DD}.dbn.zst
```

Example:

```
gs://stxr-prop-asia-historical-data-qmdzj/databento/GLBX.MDP3/mbp-1/inst_A6GTCJRH7SXHP/2026-09-18.dbn.zst
```

| Segment | Value | Rule |
|---|---|---|
| `databento` | literal | the vendor whose native format the files hold |
| `{dataset}` | `GLBX.MDP3` | Databento dataset code, spelled as Databento spells it |
| `{schema}` | `mbp-1` | Databento schema name, spelled so that `Schema::from_str` parses it |
| `{InstrumentId}` | `inst_…` | our domain instrument id, not the Databento instrument id or raw symbol |
| `{YYYY-MM-DD}` | UTC date | the day the file covers, see partition rule |

### Partition rule

One file holds the records of one instrument with `ts_recv` in `[00:00:00, 24:00:00)` UTC of the
named date. The lower bound is inclusive and the upper bound is exclusive.

`ts_recv` is the timestamp Databento's `get_range` filters on, so a request for
`start = date, end = date + 1 day` produces exactly this file with no filtering on our side. The
CME session crosses UTC midnight, so one trading session spans two files. Replay works on
timestamp ranges and does not care about sessions.

The replay provider must apply its `min_ts` / `max_ts` bounds to `ts_recv` as well, so that file
selection and record filtering agree.

### File contents

1. **Raw DBN, exactly as Databento returns it**, zstd compressed. No FlatBuffers envelope, no
   re-encoding, no synthesized fields.
2. **`ts_out` is not stored.** The replay provider synthesizes it (`ts_out = ts_recv`) when it
   wraps a record into the `DbnMdUpdate` envelope at read time.
3. **Records keep Databento's numeric `instrument_id`** in their headers. The domain instrument id
   comes from the path.

### Every requested day has a file

The download job writes an object for every (instrument, date) it requested, including days with
no records (weekends, holidays, days after expiry). Databento returns a valid DBN stream with a
metadata header and zero records for those; that stream is stored as is.

A missing object therefore means "never downloaded". The replay provider treats it as an error
and does not skip it.

### Download job

A Cloud Run job fills the bucket once per day.

- **Default run:** downloads the previous UTC day. The date is a job argument, so the same job
  backfills any past date or date range.
- **Instruments:** the CME futures known to market info. For each one the job takes the Databento
  key from `subscription_key` (`databento-mkt-data-server/src/domain/subscription_key.rs`), which
  for CME is the Globex `security_id`, and requests with `stype_in = instrument_id`.
- **Request:** one `get_range` call per (instrument, date), dataset `GLBX.MDP3`, schema `mbp-1`,
  encoding DBN, compression zstd, streamed into the object.
- **Availability check:** before requesting, the job reads the dataset's available range from the
  Databento metadata API and fails if the requested day is not fully available yet. It does not
  write a partial day.
- **Writes are all or nothing.** A GCS object appears only after its upload completes, so readers
  never see a half written file. The job uploads directly to the final name.
- **Reruns are safe.** An existing object is left alone by default. A `--force` argument
  overwrites, for the case where Databento republishes a corrected day.
- **Failure:** the job exits nonzero if any (instrument, date) failed, after attempting the rest.
  The next run with the same date fills the gaps because existing objects are skipped.
- **Secrets:** the Databento API key lives in Secret Manager and is visible only to this job.
  Strategies never call Databento.

### File resolution in the strategy

The strategy's feed routes drive replay planning. `StratTopicManager` topics no longer do.

**Routes keep the typed subject.** A `DataFeedRef` alone cannot be resolved to a path: its
`FeedId` is the feed kind digest joined with the subject digest (`compose_feed_id`), and the
instrument id cannot be recovered from a digest. `FeedRoutes::for_strategy` builds each ref from a
typed `DataFeedSubject` and then drops it. Each route keeps both from now on:

```rust
struct FeedRoute {
    feed_ref: DataFeedRef,
    subject: DataFeedSubject,
}
```

**The historical source of a route is a closed set**, matched on feed kind and subject in the same
way `FeedCodecKind::of` matches on feed kind and encoding:

```rust
/// Where a feed's history comes from.
enum HistSource {
    /// Daily DBN files in the bucket.
    DatabentoMbp1 { instrument_id: InstrumentId },
    /// Produced during the backtest by `SimExecReporter`; nothing to load.
    Simulated,
}

impl HistSource {
    fn of(route: &FeedRoute) -> Result<Self, UnsupportedFeed>;
}
```

A feed kind with no arm is an error at planning time, before any replay starts.

**Planning for one replay window `[min_ts, max_ts)`**, per route:

1. `HistSource::of(route)`. `Simulated` routes add no stream.
2. List the UTC dates that intersect the window and map each to its object path. This step is
   pure.
3. Check that every path exists under the warehouse dir. A missing file fails the plan.
4. Add one stream to the replayer with `subject = feed_topic(&route.feed_ref)`, the file list, and
   the window bounds.

Warmup and backtest use the same planning with different bounds, as they do today. The replayer
constructors keep their shape and iterate routes instead of topics.

**Priority.** There is one market data stream per instrument, so the `topic → TickDataType →
priority` table reduces to a single constant for this source. The constant keeps the ordering
that book ticks have today relative to the `SimExecReporter` stream (priority `10000`).

**The path layout lives in one shared crate.** Two pure functions, `(dataset, schema, instrument
id, date) → relative path` and `[min_ts, max_ts) → dates`, sit in a small crate that both the
download job and the strategy depend on. The date function gets a property test: the returned
dates cover the half open range exactly, with no extra day when `max_ts` falls on midnight.

## Rationale

**Feed routes drive planning.** The component rejects any replayed tick whose subject is not in
the feed routes (`component.rs:440`). When the routes produce the streams, every stream carries a
subject the component accepts. The current streams carry `md.instruments.<id>.<kind>` subjects,
which never match a route. Funding, oracle price, and spot rate topics drop out of planning on
their own, because they are not feed routes.

**A closed `HistSource` instead of a lookup table.** The alternative is a resolver that takes a
bare `DataFeedRef` and consults a reverse table from subject digest to instrument id. The routes
already hold that information at construction time, so keeping it typed is less code and cannot go
stale. It also follows the repo rule for closed sets: an unsupported feed is a compile time visible
arm or an explicit error, never a silent skip.

**Domain instrument id in the path.** Replay planning starts from the strategy's instruments, and
the envelope needs the domain id on every record. With the id in the path the provider needs no
Databento symbology lookup at replay time. The mapping to the Databento key is needed only in the
download job, where market info is already loaded.

**Dataset in the path.** One instrument implies one dataset today. The same market could come from
more than one dataset later, and renaming bucket objects is expensive. The segment costs nothing
now.

**One file per instrument per day.** It matches the replayer's stream model, and path planning
reduces to listing the UTC dates that intersect `[min_ts, max_ts)`. That replaces the hour aligned
filenames, the `MdServerTopics` parsing, and the legacy venue path probing of the Arrow layout.

**MBP-1 only.** Every MBP-1 record carries the full top of book after the event, so a file can be
read from any day boundary without a snapshot or book reconstruction. MBO would need both. Trades
come from the same stream.

**Raw DBN instead of the feed encoding.** The archive stays independent of feed revisions; a change
to the envelope or the codec does not invalidate stored data. The files stay readable with the
stock `dbn` tools. The synthesized `ts_out` is an artifact of replay and never reaches storage,
where it could later be mistaken for a real gateway timestamp.

**Empty files for empty days.** The current `probe_existing_paths` skips missing files silently.
With the Arrow layout that was tolerable. For a demo it produces a backtest that finishes with no
trades and no explanation. Making absence an error removes that failure mode.

**Scheduled download instead of fetching on demand.** Backtests stay offline and repeatable, the
API key stays out of strategies, and each day is paid for once.

## Consequences

- A new `HistDataStream` provider replaces `ArrowFileProvider` for this feed. It reads DBN, applies
  the time bounds on `ts_recv`, synthesizes `ts_out`, wraps records into `DbnMdUpdate`, and stamps
  the feed subject from `feed_topic(&DataFeedRef)`.
- The planning layer (`warehouse::get_*_hist_data_files`, `resolve_file_paths`,
  `probe_existing_paths`, `venue_for_topic`) is replaced for this feed by the route driven
  planning above.
- `FeedRoutes` changes shape: `resolve` returns a route (ref plus typed subject), and planning
  iterates routes. Callers that only need the ref read it from the route.
- A new shared crate holds the path layout. The download job and the strategy both depend on it.
- A warmup or backtest that starts in the middle of a day decodes and discards that day's records
  from 00:00 UTC up to `min_ts`. A full ES day is a few hundred MB compressed, which is acceptable
  for the demo.
- Data for day D becomes replayable after the job run that follows D. A backtest whose range
  reaches into a day not yet downloaded fails with a missing file error.
- The existing `l1_book_top` prefix in the bucket is untouched and can be removed once the Arrow
  path is gone.

## Open question: live warmup

The live regime runs the same warmup replay (`lib.rs:1790`), and its lookback reaches into the
current day. The download job only delivers the previous day, so the current day's file never
exists at live startup. Under the rule that a missing file is an error, live warmup would always
fail.

Proposed for the demo, not yet decided: the live warmup plan stops at the last downloaded day and
accepts the gap between that point and the first live tick. The backtest plan stays strict. The
alternative is to fetch the remaining part of the current day from Databento at startup, which is
more work and puts the API key into the strategy.

## Out of scope

- Funding, oracle price, and spot rate topics. Databento does not supply them. The demo strategy
  must not declare them, or planning must reject them explicitly.
- Other schemas (`mbo`, `mbp-10`) and other datasets. The path has room for them; nothing else is
  decided.
- Hourly partitioning. If daily files make warmup too slow, hourly files fit under the same prefix
  with a finer file name. That would be a new decision.
- Whether the DBN `sequence` is monotonic per instrument across a historical range. The provider
  should confirm this before relying on it for merge ordering.
