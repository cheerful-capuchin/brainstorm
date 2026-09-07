# Decision: Backtest Feed Transport Between the Backtest and the Post-Processor

Date: 2026-09-22
Status: accepted (demo scope)
Related:
- [Backtest Output: Where It Is Produced and Written](../2026-09-22-backtest-feed.md)
- [REF:backtest-feed](../../../../knowledge-base/docs/references/backtest-feed.md)
- [SPEC:backtest-feed](../../../../knowledge-base/docs/specs/SPEC-backtest-feed.md)
- [DEC-0A5FN: Backtest Feed Emits Raw Economic Events](../../../../knowledge-base/docs/decisions/records/DEC-0A5FN-backtest-feed-emits-raw-economic-events.md), section 8

## Context

The backtest runs as a Cloud Run job. The post-processor, which derives metrics from the
`BacktestResults` feed and writes them to a database, runs as a sidecar container in the same job
instance. Both are Rust programs. The feed has to get from one to the other while the backtest is
running.

Cloud Run gives containers in one instance three ways to communicate: an in-memory shared volume,
an ephemeral disk volume, and the loopback network. An outside proposal recommended streaming
Arrow IPC `RecordBatch`es over loopback TCP and using the volumes only for scratch. This decision
records why that proposal is rejected and what is used instead.

The backtest will be rewritten later. This decision covers only what the demo needs.

Facts this decision relies on:

- DEC-0A5FN section 8 already decided the transport: the backtest appends events to a file, the
  post-processor tails it using OS file events (`notify` crate), the file is the durable replay
  artifact. Its revisit trigger is a consumer on another machine. A sidecar is not one.
- Both halves of that design exist. `dsl-runtime/crates/dsl-backtest-runtime/src/btest_controller/feed_writer.rs`
  holds `BacktestFeedWriter`, which writes a header line, one JSON frame per event, a terminal
  `JobCompleted` frame, and a sibling `.eof` marker. `backtest-post-processor/src/ingress/file_tailer.rs`
  holds `FileTailerProducer`, written for "the two-container shape": `notify` driven, tolerates a
  partial trailing record, handles the file not existing yet, and resolves an exit disposition
  from the `.eof` marker, a producer silence watchdog, or SIGTERM.
- Neither half is wired to the backtest. `BTestControllerEgress::write_action_to_file` still emits
  the old `SimReport` JSONL of account snapshots; nothing calls `BacktestFeedWriter`.
- The feed is one totally ordered stream of eight event families (`BacktestDefinition`,
  `BacktestMetrics`, `TargetPositions`, `Fill`, `PricesUpdate`, `TradingAccountPositionsUpdate`,
  `RuntimeEvent`, `BacktestJobCompleted`), ordered by `BacktestFeedOrderand`. The
  `BacktestDefinition` carries the dictionaries that later events reference by index.
- Every feed in `data-feed-definitions` is a protobuf `oneof` envelope with one generated codec
  crate under `rust/crates/codecs/`. The generator (`data-feed-codegen`, in the `data-feed-core`
  repository) emits protobuf. `data-feed-definitions-ts` derives TypeScript types and zod schemas
  from the same definitions. `demo/backtest_feed.rs` exists and is empty.
- The current JSON wire types (`FeedTextFrame`, `FeedTextFileHeader`, `BacktestResultEvent`) are
  hand-written in `dsl-runtime-contracts::results_feed`, outside the definitions repository. The
  post-processor decodes the payload as `serde_json::Value` and interprets it in a second step.
- `PricesUpdate` carries every valuation price in-feed (DEC-0A5FN). The post-processor's
  multiplexed market-data streams and demux (`stream_idx`, `FeedRoleResolver`) exist to obtain
  prices from a separate source and are no longer needed for that.
- Writes to a Cloud Run in-memory volume are charged to the memory of the container that writes.
  The volume `sizeLimit` and the container memory limit are separate settings.
- `structure-web` launches the backtest with `--outfile=<results bucket>/…`, a Cloud Storage
  volume mount. gcsfuse turns an append into a rewrite of the whole object and does not raise
  inotify events.
- A `prost` message has `encode_length_delimited` and `decode_length_delimited`.

## Decision

### Transport: append-only file on a shared `emptyDir` volume

The backtest appends the feed to one file on a volume shared by both containers. The
post-processor tails that file with `notify`. No network listener, no socket, no startup ordering
between the containers: the tailer already handles a file that does not exist yet.

The live file never lives on a Cloud Storage mount. After the run the post-processor copies the
finished feed file and its results artifact to the results bucket.

### Encoding: protobuf, generated from `data-feed-definitions`

The feed is defined in `data-feed-definitions/rust/crates/data-feed-definitions/src/demo/backtest_feed.rs`
with `encodings: &[EncodingKind::Protobuf]`, following `sim_venue_feed.rs`. One
`BacktestResultEvent` envelope holds a `oneof` with one variant per event family. The generator
produces the codec crate; both the backtest and the post-processor depend on it.

`dsl-runtime-contracts::results_feed` is retired once the codec crate exists.

### Framing: length-delimited records, single stream

Each record is `[varint: message length][protobuf bytes]`, the record DEC-0A5FN section 8
describes, written with `encode_length_delimited`. The file holds exactly one stream. There is no
file header: the first record is the `BacktestDefinition` event, which is the feed's header by
spec. The `stream_idx` frame field and the demux are removed from the post-processor.

### Termination: the terminal event, no marker

The last record is `BacktestJobCompleted`. The post-processor stops when it decodes it. The `.eof`
marker is dropped: `BacktestFeedWriter::finalize` writes the marker and the terminal event
together, so there is no state the marker signals that the event does not. A run that ends
without the terminal event (crash, kill) resolves through the tailer's producer silence watchdog,
as it does today. A truncated last record is detected by the length prefix and waits on the same
watchdog.

The post-processor's async pump no longer needs a file-level end signal. The component that
decodes `BacktestJobCompleted` stops the pump over the control channel it already has.

### Flush policy

The writer keeps a `BufWriter`. It flushes on every `BacktestMetrics` event and on
`BacktestJobCompleted`; fills and prices ride the buffer. The post-processor therefore sees
progress once per metrics interval, with one inotify wakeup per buffer rather than per event.

### Volume choice

In-memory `emptyDir` with an explicit `sizeLimit`, and the backtest container's memory limit
raised by the same amount, because the feed bytes are charged to the writer. A feed of a few
hundred thousand events at protobuf sizes is tens of megabytes; `sizeLimit: 512Mi` covers the demo.
If a configuration is expected to produce more than a few hundred megabytes, the volume becomes
ephemeral disk. Nothing else changes.

### Container lifetime

A Cloud Run job task finishes when its main container exits, at which point sidecars are stopped.
The backtest container must therefore not exit until the post-processor has written and uploaded
its results. The backtest waits on a done signal from the post-processor (a file on the shared
volume or a localhost health endpoint) before exiting. Confirm the sidecar termination behavior
against the Cloud Run jobs documentation when writing the job YAML.

## Rationale

**The transport was already decided and half built.** DEC-0A5FN section 8 chose a tailed file
for the reasons that still hold: the file is the replay artifact, there is no IPC to maintain, and
the post-processor can be re-run against it. The tailer and the writer exist. Replacing them with
a socket protocol adds a second sink (the proposal itself concedes it would still write files for
replay) and removes the exit and liveness semantics already implemented.

**A file decouples the backtest from the consumer.** The backtest is deterministic and expensive;
the post-processor is a cheap pure consumer. With a socket, the consumer must be up before the
producer connects, a consumer crash either stalls the strategy thread on a blocking write or
kills it with a broken pipe, and "blocking writes as backpressure" ties the simulation's wall
clock to the metrics consumer. With a file, the backtest never waits on or knows about the
post-processor, and a failed post-processor is re-run against the file.

**Arrow does not fit the data.** An Arrow IPC stream carries one schema. The feed is a
heterogeneous ordered event log with a dictionary-bearing header. Modelling it in Arrow means a
sparse wide schema with nullable columns for every family, a union column, or one stream per
family, which loses the single ordering the spec and the consumer's fold depend on. Batching into
`RecordBatch`es also adds a buffering layer and latency the demo does not need. The proposal's
advice ("one schema for the whole stream, nullable extra columns") describes a tick table, not
this feed.

**Protobuf over JSON.** The definition has to be written in `data-feed-definitions` regardless,
and the generator gives the codec, the typed messages, and the TypeScript types for free. A
`oneof` envelope models a heterogeneous ordered stream exactly. Records are roughly five to ten
times smaller than the JSON lines the current writer emits, which is what makes the in-memory
volume comfortable, and the post-processor gets typed events instead of a `serde_json::Value`
decoded twice. Keeping the hand-written JSON contract would keep a second source of truth for
the feed shape, against the definitions repository's rule.

**One stream, no header, no marker.** Each of these was a convention from the earlier
post-processor design where prices came from separate market-data streams and the pump could not
parse. Prices are in-feed now, the codec decodes on the consumer side, and the terminal event is
the end signal by spec. Fewer shared conventions across two repositories.

**Not the Cloud Storage mount.** The bucket mount is where the artifact ends up, not where the
live file can be tailed.

## Consequences

- `data-feed-definitions` gains the backtest feed definition and its generated protobuf codec
  crate. The `data-feed-codegen` tool must be available to run; it is not checked out in this
  workspace.
- `dsl-backtest-runtime`: `BacktestFeedWriter` writes length-delimited codec messages instead of
  JSON frames, drops the header and the `.eof` marker, and flushes on metrics and completion.
  `BTestControllerEgress` routes events into it instead of `write_action_to_file`. The producer
  side of `Fill`, `PricesUpdate`, and `BacktestDefinition` is the bulk of the work.
- `backtest-post-processor`: `LineBuffer` becomes a varint-length framer with the same partial
  record buffering; the codec crate replaces `serde_json::Value`; the demux and `stream_idx` are
  removed; prices come from `PricesUpdate` through the `FeedRoleResolver` seam; the `.eof` branch
  of the tailer is removed; the component stops the pump on `BacktestJobCompleted`.
- `structure-web`: the launch path stops passing a bucket path as `--outfile`. The Cloud Run job
  definition gains a second container, the shared volume, its `sizeLimit`, the raised memory
  limit on the backtest container, and the wait-for-sidecar exit.
- `structure-strat-template-core/strats/flip-positions/tests/backtest_e2e.rs` reads the old
  JSONL shape and must be updated with the writer change.
- DEC-0A5FN section 8 is confirmed, not amended. Its provenance table can record that the demo
  implements it with the generated protobuf codec and without a file-level end marker.

## Out of scope

- The content of the feed events and the producer-side derivation of fills and prices. SPEC and
  DEC-0A5FN cover them.
- The post-processor's metric derivation and its results database.
- Compression of the feed file. Not needed at demo volumes.
- Multiple consumers or a consumer on another machine. That is the DEC-0A5FN revisit trigger, and
  the file remains the artifact such a consumer would read.
