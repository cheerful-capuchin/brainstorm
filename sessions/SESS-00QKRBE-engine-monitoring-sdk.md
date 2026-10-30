---
create_time: 2026-10-14T15:06:22Z
title: "Engine monitoring SDK: logs, panics, metrics over a dedicated NATS"
summary: "monitoring-core + monitoring facade (D13), handle in LogScope not global (D9, tick() D10), two lanes logs+metrics (D2), per-severity flood budgets (D16), argus-style events with kind + revision ids (D5, D21), global u128 event id (D22), binary catalog + stdout JSON backup (D19), no JetStream, Source (D11), build id record (D15), monitoring-gw + event-gw stores all (D17), node logging out (D1), dial9 parked, staging for unknown layouts, properties as ClickHouse JSON (D27), monitoring-wire crate with Value/IntoValue (D28), self-contained alerts (D29), monitoring-gw catch-up via event-gw over NATS (D30), build pipeline as an event stream accepted, debug info export open (D31), requirements per ArtifactKind (D32), pipeline local for now, infra images only, strategies excluded (D33), this round build id only (D34). build entity apart from monitoring (D35). Notebooks monitoring-core-proposal rev 21, build-id rev 3; Abandoned 1h configurable (D36), image tied both ways (D37), BuildId+schemas in platform-core (D38-39), one build = one image (D40), build id sole identity (D41), builders file (D43), TS CLI (D44); agents are the main users (rev 4 proposal), one builds CLI (D46), timeline from revision create time (D47). build-id notebook rev 5; build service all Rust, http->handler->service->repository, no zod, TS only I/O (D48); no Port suffix (D49), platform-core rust/crates layout (D50), contracts crate in application-server (D51), no V1 Avro types per SESS-00RRP6T D24 (D52); reads open to stxr.io (D53), build-contracts (D54), builds program TS + wasm (D55), StatementId catalog (D56); ts/packages/platform-core (D57), argus naming in Rust (D58), typed ObjectOp with generic ObjectRef (D59), host entropy (D60), Rust snowflake own instance id (D61); drizzle hand-written (D62), orderand per feed, no global sequencer (D63), Avro stored + mapper (D64), no as_of_ (D65); typed assembler (D66), copy table revision idea (D67), event sourcing go (D68), single domain_events table (D69), tail_cursor (D70), create request_id (D71), core instance id 2 (D72), application-server/AGENTS.md (D73); load returns Result (D74), Read Committed + docs/decisions records (D75), 128-bit ULID event ids not uuid (D76), builder list Avro (D77), Rust source of truth for event schemas, D39 revised (D78), feed mapper in application-server-core (D79); platform-schema crate (D80), Platform orderand scope (D81), event_audits actor + trace_id, no origin (D82), optional Rust builders CLI (D83), review closed, build-service-implementation rev 8 final (D84), handed to implementer (D85)"
related_sessions:
  - SESS-00PYN1M
  - SESS-00PYCE2
  - SESS-00R0FYF
  - SESS-00RRP6T
agents:
  - claude-code:d3dec06a-db6e-4a54-b36e-6bd06a41da0b
  - claude-code:f226bb41-67de-4bfe-8890-f598c2e463bd
  - claude-code:c94d0c2d-117f-4ce6-b0ca-236daa4304e1
  - omp:01a18c64-7d2a-7538-a02f-e9be30b20142
  - omp:01a18e01-cf13-76c1-bbb6-b117b6dbbc9c
---

# SESS-00QKRBE: Engine monitoring SDK: logs, panics, metrics over a dedicated NATS

## Context (2026-10-14)

Recent incidents went unnoticed: services in crash loops, databases down,
error and warning spam, doom loops (see the memory on the alerting pipeline:
event-gw crash-looped ~3,000 times, a target-exec/sim-gw order loop ran 37 h,
2026-10-13/14). The user says infra changes from that rework are probably not
pushed yet.

The user wants proper monitoring for engine applications. logger2 already has
a partial version. Design discussion only in this session so far; no code.

## Constraints and intent stated by the user (2026-10-14)

### C1. One monitoring crate, initialised in main

- A crate in `monitoring/rust/crates/` owns the sink for logs, alerts,
  outgoing messages, panic capture and stack unwinding.
- The app initialises it at the start of `main` (Sentry-like:
  `let _guard = init(...)`, explicit `capture_error`, automatic panic
  capture). Logs, traces, telemetry and metrics all go through it.
- Goal: full visibility into the state, metrics and logs of each engine app.

### C2. HFT: never interfere with trading

- A separate NATS instance used only for monitoring (user's assumption).
- Pack many events into one message with FlatBuffers; the backend sorts and
  dispatches them, like Cloudflare's single observability platform
  (https://blog.cloudflare.com/one-observability-platform/).
- The channel from the app threads is bounded and written with `try_send`.
  A slow consumer must never block the main thread.
- Plain NATS for most traffic; JetStream only where durability is needed.

### C3. Backend split

- event-gw (`event-gw/README.md`) stores.
- notify-gw (`monitoring/README.md`, SESS-00PYN1M) alerts.

### C4. Panics

- Global panic hook: put the panic into the monitoring buffer and flush
  immediately.
- Capture the stack as raw addresses only; symbolise in post-processing.
- The user assumes a build id per binary, with the debug-info binary kept in
  a bucket or inside the Docker image (one stripped prod binary plus one with
  debug symbols, read through the container filesystem).

### C5. Metrics

- Optional config setting: on a timer, emit the state of the things we care
  about.
- Possibly accept a collector supplied by the app that returns the metrics it
  cares about.

## Open questions raised by the user

- Q1. Source keys. `messaging/msg-schemas/proto/structure/event_log.proto`
  separates subject and source, but source keys are free strings, so naming
  drifts ("strategy_revision" vs "revision" vs "strat_revision"). The user is
  not sure how to fix it.
- Q2. Overall: thoughts, suggestions, how to implement.

## Findings (2026-10-14, read from code; not decisions)

- logger2 producer path: one global byte channel behind a spinlock held for
  the whole encode; global logger is always `unbounded(16MB)` and grows
  (alloc + copy) under the lock on the producer thread; `bounded()` drop
  count is never exposed; macro ignores `prepare` errors; `&str` args
  allocate; `commit()` wakes the consumer (possible syscall per log);
  timestamp is taken on the consumer side. Formatting is already deferred to
  the backend thread (static format + raw args + decoder thunk), which is
  the part worth keeping.
- `NatsLogDispatcher`: protobuf `EventLog`, one publish per record on
  `stxr.events`, no batching, errors `eprintln!`. Logs share the trading NATS
  VM (`infra/infra/nats.ts`, single VM `nats-server-tokyo`).
- Apps pass `SourceId::nil()`; no deployment id, no build id anywhere.
- Panics: runtime `alerts-through-logs` 7801b1a `log_panic` logs EMERG and
  drains logger2 (341ae60) for 2 s; no backtraces, no addresses. Release
  profile: `panic = "abort"`, `debug = false`, `strip = "debuginfo"`.
- No metrics code in the workspace.
- event-gw already stores `event_logs` in ClickHouse (properties
  `Map(String,String)`, source columns, subject children `Array(Tuple)`);
  `feed_events` has a `flatbuffers` encoding. notify-gw feed set is closed
  (`FeedKind {Alerts, CloudMonitoringIncidents}`); feed-ingress has NATS.
- `dev-docs/code-standards/observability-events.md` sets event and key naming
  (dotted lower_snake_case, `_err` suffix) but nothing enforces it.
- KB: DEC-0CHAM (program-events catalog + alert policies), ISS-0CK0R (no
  shutdown snapshot on thread panic), ISS-07WFX (event-gw never acks).

## Proposals awaiting the user (2026-10-14, not decided)

- P1. Land the `alerts-through-logs` branches and infra (be64e42 order)
  first; the SDK is weeks away and that path closes the blind spot now.
- P2. Keep logger2's call-site API and deferred formatting; replace its
  channel with per-thread bounded SPSC rings, `try_push`, per-thread drop
  counters, producer-side timestamp. New crate `monitoring/rust/crates/monitor`
  is the facade: `init(config) -> Guard`, one monitor thread off the trading
  cores, panic hook, heartbeat, metrics, drain on drop.
- P3. Wire carries call-site ids + typed values; text and key names come
  from the link-time catalog (program-events grows into it).
- P4. Typed identity (Q1): resource is a typed FlatBuffers table sent once
  per batch (service SourceId, deployment, strategy, strategy revision,
  build id, git revision, instance/boot id); subject child kind becomes an
  enum; shared field keys come from a registry generated into Rust consts
  (like `sources.toml`), event-local keys stay free but linted.
- P5. Separate monitoring NATS VM; producers use core NATS publish; a
  JetStream stream on that server captures the subjects for durability
  without changing producers; event-gw and notify-gw read durable consumers.
- P6. Panic hook: capture raw return addresses into a fixed array, send
  them relative to the module base with the ELF build id; reserved panic
  slot (not the ring), flush with deadline, stderr fallback. Build with
  debug info, split it out (`objcopy --only-keep-debug`), upload to a bucket
  keyed by build id (debuginfod layout) rather than shipping it in the image.
- P7. Metrics: statically declared counters/gauges/histograms as
  single-writer atomics read by the monitor thread on its timer; optional
  collector runs on the monitor thread; SDK self-metrics (drops, ring high
  water, publish latency, reconnects, RSS/CPU).
- P8. Detection rules in notify-gw: any panic, alert/emergency level,
  heartbeat missing, process starts per window (crash loop), error rate per
  deployment, app rate thresholds (doom loops), dropped events.

## Second agent f226bb41 (2026-10-14): extra findings and position on P1-P8

Independent read of the code; agrees with the findings and proposals above.
Facts not listed above:

- The event name parsed from the format string (event site, `linkme`
  registry, program-events.json) is never written into the channel entry;
  `build_event_log` uses the dispatcher's `default_event` ("gw-mon.log") as
  `event`. Trace id is a random UUID per record; subject is never set.
- Eleven binaries each wire logger2 by hand and differently (gw-mon, sim-gw,
  notify-gw, target-executor, strategy live, strategy backtest, event-gw,
  realtime-gateway, market-info-server, databento server + download job,
  backtest-post-processor). The panic hook is installed only in gw-mon and
  event-gw; sim-gw and target-executor `eprintln + exit(1)`; the rest none.
- Release profile keeps the symbol table (`strip = "debuginfo"`) but no line
  tables (`debug = false`). Only `realtime-gateway-instrumentation` has
  metrics (Gauge + interval reporter printed as log lines).
- Today's alert path is stdout -> Cloud Logging -> policy from
  program-events.json -> Pub/Sub `monitoring-incidents` -> notify-gw; minutes
  of latency and it only sees what reaches stdout.
- The Cloudflare post is a product announcement with no architecture detail.

Position on the proposals above (not decisions):

- P1 agree: ship the `alerts-through-logs` branches first.
- P2 agree on the facade and the producer-side timestamp. Difference: keep
  `log-channel` for the first iteration but construct it `bounded`, expose
  the drop counter and use `recv_batch`; per-thread SPSC rings only if the
  spinlock shows up in measurements (the engine logic is one thread).
- P3 agree; add: the event-site id goes into `LogHeader` so the wire carries
  the real event name, and metric names register at link time next to event
  sites so program-events.json lists metrics too.
- P4 agree; concrete form for the key registry: `EntityKind`
  (`#[repr(u16)]`) in the telemetry crate generated from a toml like
  `sources.toml` into Rust + TS, u16 on the wire, name in ClickHouse.
- P5 agree; add: a Panic or alert-severity record flushes its batch at once
  and is also published singly on an alert subject, so notify-gw never
  unpacks full batches on the hot path.
- P6 agree; the `backtrace` crate's `trace_unsynchronized` fills a fixed
  `[usize; N]` without allocation; `--build-id` link arg in the shared
  Dockerfile; symboliser as a CLI first.
- P7 agree; add: a `process.start` record on every init (build id, git
  revision, config digest) so crash loops are counted from the stream.
- P8 agree; keep Cloud Monitoring policies for OOM kills and CPU, which a
  process cannot report about itself.
- Phasing suggestion: (1) wire crate + `monitor` facade with stdout sink,
  (2) logger2 header/channel changes, (3) event-gw unpack + metrics and
  panics tables, (4) notify-gw alert subject + liveness rules, (5) infra
  (second NATS, build id, bucket), (6) migrate the eleven binaries.

## Constraint C6 and proposal P9: log floods (2026-10-20)

### C6. User intent (stated, mechanism not decided)

- Ideally no logs are lost. If sending cannot keep up, the user suggested
  "digesting" logs instead of dropping them.
- A hot loop that logs on every iteration must not send everything over the
  wire. Example: sim-gw failed to parse a message and logged a warning per
  request, ~200 GB (231 GB on 2026-10-13..15, see SESS-00R0FYF).
- This questions P2's plain "drop when the ring is full".

### P9. Proposal (not decided)

- Budget per call site, checked in the log macro before encoding: each call
  site gets a `static` state (registered with linkme next to the event site),
  with a burst budget per window (default e.g. 20 per second, overridable per
  call site and by config at runtime).
- Over budget: no encode; the call site's suppressed counter goes up (relaxed
  atomic). Exponential sampling inside the flood: occurrence 2^k still goes
  through, so N repeats cost about log2(N) records with real arguments.
- The monitor thread sweeps the call-site states on its tick and emits one
  digest record per flooding site (event, count, first/last time in window).
  Counts are never lost; only repeated payloads are.
- Window check reads a coarse clock the monitor thread updates (atomic u64),
  not a syscall.
- Applies before every sink, stdout included (Cloud Logging volume).
- Ring capacity reserved by severity: debug/info cannot take the last part of
  the ring, so warn and above survive a flood of low levels; panics use the
  reserved slot from P6.
- What can still overflow: many distinct call sites at once. Those drops are
  counted per thread and reported as a record.
- Monitor thread under NATS backpressure coalesces by severity (info first).
- notify-gw rule: a flooding call site is itself an alert ("sim_gw.x
  suppressed 1.2M in 1 s"); this would have caught the sim-gw case at once.
- Why at the producer and not only when sending falls behind: storage and
  stdout volume are the cost even when NATS keeps up, and behaviour should
  not depend on network health.

## TigerBeetle comparison (2026-10-20, asked by the user; findings, not decisions)

Read from ~/work/gh/tigerbeetle at 47aeb2212 (2026-08-31): `src/trace.zig`,
`src/trace/event.zig`, `src/trace/statsd.zig`, `src/tigerbeetle/main.zig`,
`docs/operating/monitoring.md`.

- Logs are plain: formatted on the calling thread, synchronous buffered write
  to stderr per line, runtime level filter (`log_level_runtime`, info by
  default; debug compiled in). No rate limiting, dedup or async. Floods are
  avoided by discipline: per-request detail is debug, and anything that
  happens per operation is a metric, not a log.
- Metrics/timings are a closed tagged union `Event` with typed payloads; the
  payload fields used for aggregation are enums (tree, operation, zone,
  commit stage). Comptime gives every (event, enum value) a slot index in a
  fixed array allocated at init (`slot_limits`, `slot_bases`, `slot_count`).
- `count`/`gauge`/`timing` update the slot in place (saturating add; timing
  keeps min, max, sum, count). No channel, no strings, no allocation.
- The replica emits on its own timer from its tick (`emit_metrics`): StatsD
  UDP packets, sizes derived at comptime (max line size, packets per emit),
  buffer allocated at init, sent open-loop. If packets are still in flight
  it logs and skips the emit ("Busy") without resetting, so the slots keep
  aggregating into the next window: backpressure lowers resolution, counts
  are not lost. Comment: avoid "metrics killing the whole system".
- Identity is typed (`ProcessID` union: cluster u128, replica u8), sent as
  tags; `tigerbeetle inspect metrics` prints every metric and its
  cardinality from the code. State is a gauge (`replica_status` enum value;
  non-zero = alert).
- Spans are separate (start/stop, Perfetto JSON behind a flag); slow timings
  also warn-log as redundancy with metrics.

Agent's reading (proposal, not decided): the per-call-site budget in P9 is
the same idea as a TigerBeetle slot (call site = slot, suppressed count =
aggregate); add enum-typed labels to the slot key, let the owning thread
fold its slots into one record on its own timer (no cross-thread atomics
for single-threaded engines), and on transport backpressure skip and keep
merging instead of dropping.

## C7. Lossy vs lossless (2026-10-20, user's direction, tentative)

- The user thinks passing important, durable information through a logger is
  a bad strategy, and suggested separating a lossy logger from a lossless one.
- Lossy: "transitioned to running", "parse error"; missing one is fine.
- Lossless: e.g. trades made for an account must not be lost. The user
  suggested TigerBeetle-style accumulation there: if it cannot be sent now,
  keep accumulating.
- Also asked (open, answer pending code survey): strategy graph node values
  (logging policy, structure-strat-template-core) reuse the same logger
  today; does that need a different approach or a separate buffer for the
  graph state?

### Agent's answer to C7 (proposal, not decided)

Three lanes, not two:
1. Ops logs (lossy): budget per call site, sampling, digests, counted drops
   (P9). Monitoring NATS.
2. Aggregates (lossless totals, lossy resolution): counters, sums, gauges,
   TigerBeetle slots; when the transport is busy, keep merging. Works only
   for values that merge (count of trades, volume, PnL sum), not for
   individual trades.
3. Records that must each arrive (trades, fills, account events): not a log
   and not an aggregate. A domain feed with a per-producer sequence number,
   a durable store (JetStream / Pub/Sub), consumer gap detection and replay
   from a retained buffer or the source of truth (venue / gateway). Bounded
   memory cannot be lossless forever: past the buffer, spill to a local
   append-only file, and if that is also exhausted the strategy stops
   opening positions (trading without a record is worse than not trading).
   Runs on the trading data path, never on monitoring NATS.

## Strategy graph node logging (2026-10-20; findings, then proposal P10)

### Findings (from code)

- DSL 2 native runtime parses and validates `strategy.logging_policy` and
  ignores it (DEC-0BQ6R item 34, PLAN-0BRQ8, stxr-client-app
  `docs/dsl-2-native-execution.md:35`). DSL 2 emits only
  `strategy.graph.node_error` (plain `log_error!` live; collected in
  backtest).
- The full node logging pipeline exists only in the disconnected DSL 1.1
  codegen (`dsl-processor-core/src/versions/v1_1/codegen/`): per-graph
  requested bitsets, written bits, 35 B fixed records in logger2 chunks,
  events `strategy.graph.{node,memory_slot}.recorded`, `state.changed`.
- Live 1.1 path used logger2 as a transport: marked records were picked off
  on the logger thread by `RuntimeEventsFeedDispatcher`
  (structure-strat-template-core `src/runtime_events_feed.rs`), re-encoded
  as protobuf and published to the deployment runtime events feed; values
  stored as text in ClickHouse `event_logs.properties["chunk_N"]`.
- Backtest path renders text and allocates on the strategy thread
  (`format!`, String per chunk, Vec of properties) into the BacktestResults
  outfile -> DuckDB `feed.runtime_events`.
- DSL 2 codegen keeps node values as stack locals; no per-subgraph state
  struct or written set (DEC-096S8, DEC-09K6K are proposed only).
- Tick Navigator is not built; its data source and schema are open.
- No volume measurements. Estimate: 30 nodes, every tick, all nodes ~1 KB
  binary per tick.

### P10. Proposal (not decided)

- Node values are a strategy deployment feed, not logs (follows C7): not
  through logger2 and not through the budgeted lane.
- One SPSC ring per strategy, strategy thread -> egress thread, allocated at
  startup; capacity derived after policy resolution (selected nodes x fixed
  record size x headroom ticks).
- Generated DSL 2 code reserves the worst-case record at tick start, writes
  selected locals straight into it (monomorphised recording / non-recording
  variants, as 1.1 did with CAPS), then commits or aborts once the emit rule
  is known. The ring slot is the buffer; no separate graph-state copy.
- Record: deployment feed orderand from `DeploymentEventClock`, trigger time,
  effective state, then values keyed by slot index (u16) plus strategy
  revision; slot -> canonical id from the generated graph layout. Typed
  values, no text.
- Same encoder live and backtest (live publishes to the deployment feed,
  backtest writes the results file) so Tick Navigator reads one shape.
- Ring full: drop whole ticks, count them, next record carries
  `ticks_dropped`; strategy never blocks. Bytes per tick known at policy
  resolution, so a policy over a bandwidth cap can be refused at startup.
- Strategy ops logs (node_error, transitions) go through the monitor lane;
  ticks processed / ticks dropped as aggregates.

## D1. Strategy graph node logging out of scope (2026-10-20, user decision)

- The user: DSL 2 has no node logging, so skip it.
- Node value logging (logging policy, P10) is not part of the monitoring SDK
  work. P10 stays as a parked proposal, not pursued. The SDK only needs to
  carry strategy ops logs (e.g. `strategy.graph.node_error`) like any other
  engine app.
- C7 lanes (lossy logs / aggregates / must-arrive records) remain open.

## Decisions (2026-10-20, second round)

### D2. Two lanes: logs and metrics
The user: durable facts (trades, account updates) already travel as engine
egress messages published to NATS, not through the logger. The monitor SDK
has two lanes only: logs (lossy, budgeted, P9) and metrics (aggregates,
TigerBeetle-style merge when the transport is busy). Rejects the third
"must-arrive records" lane from the C7 answer as part of the SDK. The rule
"if losing it makes an account, position or PnL wrong, it does not go
through the logger" stands as the boundary.

### D3. Budget per call site with a default, overridable from config
Answer "Yeah, I would say so" to: default budget per log line, and config
can override it at runtime. Exact defaults (per severity or one number)
not chosen.

### D4. Build id links everything
Answer "Yeah" to item 4 (typed key registry, debug files in a bucket keyed
by build id, stdout alert path kept as backup), with a requirement: the
build id must be the same everywhere and connected: in the binary that
runs, in the Docker image, in the bucket where the debug info is stored,
and in the database next to the events.

### Open: logger2 context (user question)
The user does not understand the `pub event` field in
structure-strat-template-core `src/log_ctx.rs` (`BacktestLifecycleLogCtx`).
Explained (finding): the event name has two sources that disagree. The
first token of the format string is parsed at compile time (program-events,
alert policies, GCP JSON sink `event`); a context field named `event`
(`EVENT_CONTEXT_KEY`, logger2-backend `event_conversion.rs`) is promoted to
`EventLog.event` only on the NATS/Pub/Sub path, which otherwise uses the
dispatcher default ("strategy.log"). `BacktestLifecycleLogCtx` and
`HelpersLogCtx` use only the context field, so those sites are Unnamed in
program-events and the name is a runtime value nobody checks. Proposed (not
decided): one mechanism, the name at the start of the format string; drop
the `event` context override; contexts carry only fields shared by many
lines (sn, regime, phase).

### D5. Log events follow argus: static event, typed properties, catalog description (2026-10-20)

The user: follow `structure-web/packages/api/src/argus/argus.ts`
(`argus.warn(event, properties, { description })`):
- The event is a static str, given explicitly, so it can be extracted
  cleanly and assigned a numeric identifier.
- Properties are separate and clearly marked as the event's properties.
- An optional description, also a static str, says what the event means.
  It is not sent over the wire; it lives in the same catalog as the event
  name.
- A context may pass additional typed parameters; that is fine.
- Rejected: the `event` context override and dispatcher default event names
  ("I hate this override and defaults"). Replaces the "two sources" state
  described under "Open: logger2 context".

Agent's proposed details (not decided): description as the `///` doc
comment (already required on log_alert!/log_emergency! by DEC-0CHAM, today
refused on other levels); no free-text format string, sinks render
`event key=value`; numeric id = compile-time hash of the event name, with
the catalog rejecting collisions; the catalog checks that every site of one
event has the same keys and types and that context keys do not collide with
property keys; cross-service concepts (strategy revision, deployment,
instrument) live in typed context structs or the resource, so property
keys are event-local (answers Q1 drift).

## Decisions (2026-10-20, third round)

### D6. Description is an optional explicit argument, not a doc comment
The user does not like doc comments for this; prefers an optional explicit
argument. Rejects the agent's `///` proposal. Open: whether alert levels
still require it (DEC-0CHAM requires a doc comment on
log_alert!/log_emergency! today; that mechanism would change).

### D7. The event string is the event name, verbatim
Whatever is passed as the event is the event name; it does not need dots.
Drops logger2's rule that a name is two or more dot-joined segments
(`event_name()` returns None otherwise and the site is Unnamed). No
separate free-text message follows from this (agent's reading).

### D8. New monitoring core crate, reusing logger2
A new monitoring core crate in `monitoring/rust/crates/` that reuses a lot
from logger2 (macros, derive, Loggable encoding, program-events registry).
Not a complete rewrite. Supersedes P2's "keep logger2 and replace its
channel" framing.

### Finding: static strings are passed by pointer
Answer to the user's question. logger2 copies a `LogHeader` per log
(`&'static str` format, `&'static [Placeholder]`, named-arg keys: fat
pointers into the binary's read-only data, ~64 B with level/n_args);
`StaticStr` encodes as its 16 B fat pointer (default `Loggable`, bitwise
copy); only non-static `&str` copies (`to_string()`, allocation) and moves
the String into the buffer. Proposed: one `static` event site per call
site (name, id, level, description, key/type list, budget state) and the
record carries a single 8 B pointer to it plus timestamp and values; the
monitor thread turns the pointer into the numeric id; pointers never go on
the wire.

## Context use cases and macro expansion (2026-10-20, user questions; findings + proposal)

Findings (logger2-macros `src/lib.rs` `generate_log_macro`, logger2-derive
`LogContext` impl):
- Expansion: link-time event-site registration; `static` placeholder and
  named-key tables; `global_logger()`; context evaluated once; args bound by
  `match`; sizes summed; `LogHeader` built; `prepare(total)` (spinlock,
  may grow buffer); `reserve_bytes`; per segment `[u16 len]` then header
  memcpy, context `encode_context`, each arg `encode_to_unchecked`
  (decoder fn pointer + raw bytes); `commit()` (unlock + wake). Errors from
  prepare/reserve are silently ignored. Below compile-time `LOG_LEVEL` the
  call only registers the site and discards.
- Derived context: per log and per field a 16 B key fat pointer, u16 length,
  8 B decoder pointer, value bytes; each field is `clone()`d (allocates for
  String fields).
- Context uses found: shared fields per scope (StratLogCtx sn, regime,
  phase), engine time (StratLogCtx.timestamp from the engine time provider,
  sim time in backtest), feed stamping for durable runtime events
  (Logger2EventSink; out per D2), event name override (rejected in D5).
- argus's context (`ArgusContext`) carries trace id, time provider and id
  maker, not properties.

Proposal (not decided): record header filled by the crate = site pointer,
timestamp from a per-thread clock the engine registers (wall clock live,
replay clock in backtest), trace id and engine sn when present; resource
= who (per batch); properties = what (per event); typed context kept only
for extra typed fields shared by a scope, described by one static
descriptor per context type (not a key pointer per field per log). Site
descriptor holds value types/decoders, so values carry no decoder pointer.

### D9. No global logger; the handle travels in the context (2026-10-20)
The user would rather not use a global logger: pass a pointer (or similar)
to the logger in the context, so code is easy to test. Replaces logger2's
`global_logger()` lookup in the macro for the new crate. Agent's reading
(proposal): the first macro argument is a scope that yields the thread's
emitter handle, clock, sn and typed fields; the engine context implements
it; budget and metric slots live in the handle, not in statics; the panic
hook stays the one process-wide registration (std requires it).

dev-env notebook with the full proposal: session `sess-00qkrbe`, notebook
`monitoring-core-proposal` (2026-10-20).

## Decisions from the notebook review (2026-10-20, dev-env annotations on `monitoring-core-proposal`)

### D10. Scope exposes `tick() -> u64`, no Options
Rename `sn` to `tick`: a single u64, maybe a monotonic counter. Not tied to
the engine. The user: no Options in the trait. (Engine sn becomes the
engine scope's tick; a plain emitter counts its own records.)

### D11. Resource is called Source
Both in "what goes where" and the wire format (`Batch.source`). Agent note:
reuse/extend `telemetry::Source`, replacing its free-string metadata with
typed fields.

### D12. Description is never required
Not required on alert levels either. Supersedes the open question from D6.

### D13. Crate names: `monitoring-core` plus a `monitoring` facade
`monitoring` is the nicer name to import and call; `monitoring-core` holds
the implementation.

### D14. No JSON
The user hates JSON. Local/structured output uses Apache Avro or
FlatBuffers; a viewing tool serves agents and humans. Humans rarely read
raw output; agents and event-gw are the main readers. Supersedes the
user's earlier annotation "sinks should be JSON or any human readable
structured format" and the agent's text rendering. Open conflict: the D4
stdout backup alert path relies on Cloud Logging matching text/JSON lines
(infra fb80886); binary stdout is not indexed.

### D15. Domain build id minted by the pipeline
The user wants one internal build record as the single entry point from
code to deployed instance: a domain build id that links linker build id,
git sha, Docker digest, Cloud Run instance, etc. A pipeline builds
everything beforehand and passes the domain build id into the instance;
everything else is found from it. Catalog delivery: produced by that
pipeline (sending it from the process "could be interesting", not
chosen). Refines D4.

### Restated earlier decision: no JetStream
JetStream was rejected on 2026-09-29 (SESS-00P9RZK 8b: it adds logic to
handling a massive number of events). The P5 JetStream capture proposal is
withdrawn; monitoring uses core NATS only.

### Questions in the review, answered in replies (findings/proposals)
- Thread count: not known up front; one ring per emitter created at thread
  setup, fixed registration table (`threads_max`), shared locked lane for
  threads without an emitter (tokio pools, third-party).
- Trace id: no trace exists in most engine apps (logger2 mints a random
  UUID per record). Proposal: no trace in the record header; a trace id
  is a typed context field when the code handles a message that has one.
- `telemetry::EventId` (u128, one event instance) differs from the site
  id (one event kind). Proposal: call ours `EventKindId`, u32 (collisions
  checked per binary at catalog build; backend keys by build id + kind
  id); instance identity = (instance id, batch seq, record index), filled
  by event-gw.
- Metrics over lossy core NATS: send cumulative counters since process
  start (not deltas), so a lost batch loses resolution, not totals.
- Panic stack over 64 frames: keep the innermost 64, count the rest.
- notify-gw scope ("then it's a monitoring gw? who stores GCP
  incidents?"): today nobody stores incidents (SESS-00R0FYF D4 open).
  Proposal: event-gw stores everything (monitoring batches, alerts feed,
  incidents feed); notify-gw evaluates rules and notifies.

### dial9 (user asked what to take; findings, not decisions)
Read dial9-rs/dial9 at 4f2c7ce0 (v0.5.5, 2026-10-16). Not trading-safe:
thread-local buffer behind a mutex, ~1 MB allocation on first event (plus a
global lock) and on every flush on the recording thread, interning hash maps
reset per batch, stream-local type ids and no frame lengths in its format,
tokio telemetry needs tokio_unstable and tokio >= 1.51. Proposal: no
dependency on the engine path; copy epoch drain, drop-oldest with counter,
u24 timestamp deltas, lazy event construction, frame-pointer walk with a
startup self-test; avoid its global allocator profiler, perf_event/SIGPROF,
SIGSEGV handler, lazy TLS init, on-host symbolisation. Notebook section
"What to take from dial9".

## Decisions from the second notebook review (2026-10-20)

### D16. Default flood budget per severity
One default per severity; config overrides per event.

### D17. `monitoring-gw`; event-gw stores everything
notify-gw becomes `monitoring-gw` ("a better name indeed"). event-gw stores
everything (monitoring batches, alerts, Cloud Monitoring incidents);
monitoring-gw handles health checks, alerts, etc.

### D18. Panic stack: 64 frames is ok
Innermost 64, rest counted.

### D19. The catalog is a binary file; JSON on stdout only as a backup
Clarifies D14: the list of all events, ids, descriptions, types collected at
link time must be a binary file (not JSON like program-events.json). JSON
logs on stdout are fine as a backup when NATS cannot be reached.

### D20. dial9 parked
"Let's ignore this for now." Notebook section removed.

### D21. Event kinds have a revision id
The user: the event name may stay while its fields change; we must know
what is inside and how to decode it from a revision id. Agent's proposal
(not decided): revision = compile-time hash of the property layout (keys,
types, order, enum definitions), sent next to the kind id; decoding keyed
by (kind, revision), independent of the build.

### D22. Globally unique event id required
"We have to build a globally unique event id." Agent's proposal (not
decided): u128 = instance id (u64, minted per process start, time-ordered
plus random) | batch_seq (48 bits, per instance, from 0) | index in batch
(16 bits); matches `telemetry::EventId` (u128); derivable on both sides.

### User requests and questions answered in replies (proposals)
- Opt-in blocking log (not default): proposed as a per-call-site option with
  a bounded wait (the monitor thread never blocks on NATS, so the wait is
  short); it guarantees the record left the thread, not that it is stored.
- Sampling configurable: yes, per-severity budget and the sampling base in
  config, per-event overrides.
- Trace id lives in the scope's `Fields` type: yes.
- Header size: logger2's `LogHeader` is 72 B (repr(C), padding), not a
  cache-line choice. SPSC does not thrash; head/tail indices go on separate
  cache lines; smaller records touch fewer lines and fit more per ring.
- Statics and tests: site descriptors are immutable; mutable state lives in
  the emitter, so no test interference.
- Metrics: deltas + periodic snapshots vs cumulative. Proposed hybrid: send
  only slots changed since the last send, as cumulative values, plus a full
  snapshot every N intervals.
- NATS reconnects metric = the monitor's own connection; trading NATS
  reconnects are the app's metric. RSS/CPU read on the monitor thread from
  kernel counters every interval; nothing runs on the trading thread.
- Build record practicality (user: Pulumi deploys infra locally, maybe a
  local binary file; strategies/backtests are many and tracked in the app
  server; app-server endpoint called by Pulumi creating structure.Build?).
  Findings: strategy images are built by Cloud Build from the activity
  worker (trigger-build / complete-build, `strategy_images`,
  `strategy_runtime_revisions`), one image per template + runtime revision;
  infra images are built by hand with `just bake` (infra/docker-bake.hcl),
  digests pinned in `docker-repository.ts`. Proposal: mint the build where
  the image is built, never at deploy: app-server `builds` record created by
  the TriggerBuild activity (BUILD_ID build arg, completed by
  complete-build) and by `just bake` through an internal endpoint; the
  build id is written into the image (file + label), Pulumi/app server only
  read it and record which build each deployment runs.

## Decisions from the third notebook review (2026-10-20)

### D23. Rings for owned threads, shared lane for the rest
"I like this better. For our trading use-case we have the best infra. If
you have a general application with tokio running around the threads and
you don't care, you pay a small cost of perf." Accepts emitter rings with a
fixed `threads_max` table plus the locked shared lane.

### D24. Event id layout accepted
EventId (u128) = instance_id 64 | batch_seq 48 | index 16; instance id
minted per process start (time + random); batch_seq per instance. ("kk")

### D25. Revision = compile-time hash of the property layout
Accepted ("agreed"): keys, types, order, enum definitions; sent next to the
kind id; decode by (kind, revision).

### D26. Opt-in blocking accepted
`on_full = wait(timeout)` per call site, not default, bounded. User asked
how the timeout works (std thread-blocking timeout?). Answered (proposal):
spin briefly, then `std::thread::park_timeout` in a loop bounded by an
`Instant` deadline; producer sets a waiting flag and unparks the monitor,
monitor drains that ring and unparks the producer; no Mutex/Condvar.

### Open: release when the application server is broken
User scenario: the app server has a bug, no build id can be created, but a
release must go out. Proposal (not decided): mint the build id locally
(time + random, no coordination); the build writes the build record,
catalog and debug info to the bucket under that id itself (bucket = source
of truth); the app-server `builds` table is an index fed from it,
retried/backfilled later. Backend lookups (symbolisation, catalog) read the
bucket by build id, so they work with the app server down. Replaces the
earlier "app server creates the Build" proposal.

## Build id cardinality and storage (2026-10-21, user questions; findings + proposal)

User questions: is a build id per strategy or per strategy template? Would
event-gw load lots from the bucket? Store u32 hashes in ClickHouse and
post-process strings, or send strings over the wire? How do querying and
filtering work; does the description need to be stored per row?

Findings: strategy -> revisions -> template (content addressed, spec
without parameter values; revisions differing only in values share it) ->
images, one per (template, runtime revision), key
`sha256(templateId + runtimeRevisionId)` (activity-worker
`trigger-build.ts`); strategies are compiled per template, parameter
values arrive as runtime config; one image runs many deployments and
backtests. `event_logs` (timeseries-db `clickhouse/schema.sql`) has
`event LowCardinality(String)`, `properties Map(String, String)`,
`description String` per row; local ClickHouse 25.3, Cloud version not
pinned.

Proposal (not decided):
- One build id per image build: per (template, runtime revision) for
  strategies; deployments and backtests share it and differ by Source.
- event-gw decodes by (kind, revision), loads an `event_kinds` table
  (name, level, description, keys, types) at startup, and reads a build's
  catalog from the bucket only for a (kind, revision) it has never seen;
  undecodable batches go raw to `undecoded_batches` and are decoded later.
- Ids on the wire, not strings: values carry no keys, so the layout is
  needed anyway and holds the name; self-describing records would roughly
  double record size.
- ClickHouse: event-gw writes the name at insert (`LowCardinality`, about
  1-2 B per row before compression), plus `kind`, `revision`, `build_id`;
  description removed from the row, read from `event_kinds` via a
  dictionary; properties as the ClickHouse `JSON` column type (typed
  subcolumns per key), `Map(LowCardinality(String), String)` as fallback.
Notebook `monitoring-core-proposal` revision 5.

## Staging for unknown layouts (2026-10-21, user proposal)

Terminology (user): "strategy template" = the user's strategy template
(hundreds); our `structure-strat-template` repo commit = "runtime
revision". Build id per (strategy template, runtime revision); builds may
reach thousands.

User: all (kind, revision) layouts fit in RAM; event-gw must load new
definitions dynamically and must not hold records in memory waiting for
them (no unbounded wait). Insert without waiting for metadata: without the
layout the keys are unknown, so records with an unknown (kind, revision) go
to a staging table; a background job looks up `event_kinds` and commits
them from staging to `event_logs`. Delay possible, no data lost. Replaces
the agent's "undecoded_batches" bullet.

Findings: program-events.json today: event-gw 114 events, Databento
download job 72, sim-gw 63. Layouts grow with code changes, not with
strategy templates (shared runtime event sites), unless generated strategy
code gets its own sites.

Agent details on the user's proposal (not decided): catalog loader fed by
bucket object notifications on Pub/Sub (layouts normally known before the
image runs); staged row = event_id, build_id, kind, revision, time, tick,
source, instance_id, batch_seq, ingestion_time, raw values; promoter every
few seconds inside event-gw: fetch the catalog for pairs missing over a
minute, decode + insert with insert_deduplication_token
(instance_id, batch_seq, kind, revision), then delete from staging;
staging never expires, monitoring-gw alerts on staged rows older than ten
minutes. Notebook revision 6.

## ClickHouse JSON storage (2026-10-21, user question; findings)

User asked how JSON properties of different types are stored. Checked on
ClickHouse 26.3 local: each key is a Dynamic subcolumn (per-row type
discriminator + one packed stream per type); max_dynamic_paths 1024 per
part, overflow into shared data (32 buckets); max_dynamic_types 32. JSON
text inserts infer types (Int64, Float64, DateTime); RowBinary with
input_format_binary_read_json_as_string = 0 keeps exact types (UInt32,
Decimal(18,4)). 2 M synthetic rows, 402 keys: JSON 0.9 MB vs
Map(String, String) 12 MB on disk; one-key filter reads 5 KB vs 12.6 MB.
clickhouse-rs support for the binary JSON encoding not checked. Notebook
revision 7.

## D27. Properties stored as the ClickHouse JSON type (2026-10-21)
"okay, then JSON it is." Replaces `properties Map(String, String)`.

User questions: how to build a JSON value in Rust; how properties travel in
FlatBuffers (what bytes `Record.values` holds, how to read them).
Findings: ClickHouse RowBinary JSON = varuint key count, then per key
varuint-length key, binary type tag, value (UInt64 04, Int64 0a, Float64
0e, Bool 2d, String 15, DateTime64(9,'UTC') 14 09 03 'UTC', Decimal(18,4)
1a 12 04); fixed-width values are the same LE bytes as the wire; verified
end to end on 26.3 (33 B wire record → 93 B JSON value, exact types kept).
event-gw encodes rows with vendored `serialize_row_binary` +
`insert_formatted_with`; the crate supports JSON only as a string.
Proposal (not decided): `values` = properties then context fields in
layout order, no keys/tags/padding; fixed width LE, enum u16 index,
string u16 length + UTF-8, optional = presence byte; event-gw builds a
per-layout plan (prefix bytes + value reader) and converts with one walk;
mismatched records go to staging with the error; vendored fork gets a raw
RowBinary passthrough type, insert sets
input_format_binary_read_json_as_string = 0. Notebook revision 8.

## Format stability (2026-10-21, user question; proposal)

User: how is the stability of what is sent and received ensured, so nobody
accidentally breaks the format; rkyv? Agent's answer (proposal, not
decided): no rkyv (needs the same Rust type on the reader; event-gw only has
layouts at run time). Own fixed width format pinned by: encodings in one
`monitoring-wire` crate with a sealed `Value` trait (domain types convert
at the call site); macro emits layout type and write from the same written
type; revision hash changes on any layout change; explicit frozen type ids
(new encoding = new id) enforced by golden byte table tests; property test
emitter → event-gw plan round trip plus ClickHouse round trip; catalog build
rejects same name with different layouts and kind collisions; `flatc
--conform` on the envelope in CI; event-gw validates every record and
stages + alerts on mismatch.

Gap found: D5's call site `{ key = value }` has no types, and a proc macro
cannot learn `req.id`'s type for a link-time `static` descriptor. Proposed
syntax `{ request_id: u64 = req.id }` (open, needs the user's decision).
Notebook revision 9.

## Unsupported property types (2026-10-21, user question; proposal)

User: does the type have to implement a trait; how does a developer learn
their type cannot be serialized? Proposal (not decided): sealed `Value`
(encodings, only in monitoring-wire) + open `IntoValue { type Value: Value }`
that domain crates implement next to their type (blanket for every
`Value + Copy`); layout records the encoding's TYPE. Unsupported type =
compile error at the call site with `#[diagnostic::on_unimplemented]` text
listing supported types and the IntoValue route. Verified with rustc 1.97 in
a two-crate test (/tmp/valdiag2): coherence accepts the blanket impl plus a
downstream impl; the custom message shows. Notebook revision 10.

## D28. `monitoring-wire`: a separate crate with no I/O, sealed `Value` + open `IntoValue` (2026-10-21)
"like it, write it into the session and note book. It's a separate crate
with no i/o." Accepts the proposal under "Unsupported property types":
- `monitoring-wire` is its own crate, no I/O (no sockets, files, threads,
  clocks; no ClickHouse or NATS dependency). Holds value types and their
  ids, `Value`, `IntoValue`, the encoders the macro calls, and the decoder
  that validates a record against a layout and walks its values.
- `Value` is sealed: only monitoring-wire defines bytes.
- `IntoValue { type Value: Value; fn into_value(&self) }` is open: domain
  crates map their type onto an encoding next to the type; blanket impl for
  every `Value + Copy`. The layout records the encoding's TYPE, so changing
  a mapping changes the revision.
- An unsupported type is a compile error at the call site with
  `#[diagnostic::on_unimplemented]` text naming the supported types and
  the IntoValue route.
Agent's reading: event-gw turns the decoded values into ClickHouse
`RowBinary` bytes itself, so monitoring-wire stays free of storage
concerns. Still open from the same round: types named at the call site
(`{ request_id: u64 = req.id }`), see "Format stability".

## monitoring-gw without the catalog (2026-10-21, user question; proposal)

User: monitoring-gw cares about process state and health; for alerts it
would also have to load all event kind definitions to report issues. How?

Findings: notify-gw (monitoring/rust/crates/notify-gw) reads the alerts
feed (protobuf: event, description, properties map<string,string>,
service, tags) and Cloud Monitoring incidents from Pub/Sub; it reads no
catalog, the strings travel in the message. Infra builds one log-match
policy per alerted event from program-events.json at the image revision
(infra/infra/lib/program-event-alerts.ts), matching textPayload
`[ALERT] ev.name` or severity=ALERT + jsonPayload.message; notification
rate per deployment in infra. logger2 alert levels are ordinary levels
(GCPLogSink JSON line); alerts reach Discord only via Cloud Logging →
policy → incident topic → notify-gw. Throttle/digest files untracked.

Proposal (not decided): monitoring-gw never loads a catalog.
- Health: ProcessStart and Panic are fixed FlatBuffers tables in the
  envelope schema (panic message + file:line from the hook, addresses for
  the symboliser); every batch is a heartbeat, at least one every 5 s.
- Alerts: the monitor thread sends alert/emergency records twice, in the
  batch (event-gw stores) and as a self-describing `Alert` (name,
  description, location, properties as key + ValueType id + bytes, enums as
  variant names) on the alert subject; rendered with monitoring-wire.
- Rules: `level_counts` per batch (level known from the site), digests
  carry the event name, rules by name hash the name to the kind/metric id
  with monitoring-wire's hash (name → id needs no lookup).
- Loss: monitoring-gw catches up from ClickHouse on start (alert rows since
  the last posted, dedup by event id); stdout JSON fallback matched by one
  generic Cloud Logging policy on severity ALERT/EMERGENCY; per-event
  policies and program-events.json go away, their rate limits become
  monitoring-gw throttle config by event name. Answers open question 3.
Notebook revision 12.

## D29. Alerts are fat, self-contained messages (2026-10-21)
"because we assume that the number of alerts is going to be small, we can
use fatter messages to send the alerts, so the monitoring gw has to do less
work. I guess it's fine." Accepts the `Alert` message: name, description,
location, properties with strings; monitoring-gw gets the fully contained
record and loads no catalog.

## D30. Catch-up through event-gw over NATS, not ClickHouse (2026-10-21)
"I think it should be a request via NATS to the event gw, not a direct
database query." On boot monitoring-gw requests the missing events from
event-gw, builds a digest, and publishes it to Discord or any other
notification sink. Replaces the agent's ClickHouse catch-up.

User's summary of the monitor thread's sinks, confirmed: (1) NATS batch
feed (event logs + metrics), (2) NATS alerts feed, (3) JSON on stdout when
NATS does not work. Agent's details (proposal): the alert subject also
carries Panic and ProcessStart; the stdout fallback carries every record
within budgets, one generic Cloud Logging policy on ALERT/EMERGENCY; the
panic hook always writes one stderr line; event-gw knows "since the last
alert published" from the alerts feed monitoring-gw publishes (D17),
answers with full Alert messages built from rows + event_kinds, capped;
dedup by event id; monitoring-gw retries with backoff while event-gw does
not answer.

Open: which deployments monitoring-gw expects heartbeats from after a boot
(it learns sources only from traffic). Candidates: ask event-gw for sources
seen recently in the same catch-up request, or the app server's live
deployments.

## One event shape, metrics for monitoring-gw, control lane (2026-10-21, user questions; proposal)

User: why are panic and process start a different kind of message?
monitoring-gw should read the metrics as well. Later, monitoring-gw should
talk to services to check health or run some logic; how?

Agent's answer: no reason beyond the reserved panic slot. Proposal (not
decided):
- One event shape. `runtime.panic` (emergency; thread, message, location,
  addresses as an array of u64, frames_omitted) and `process.start` (info;
  build id, git sha, Cloud Run revision) are ordinary events defined in
  monitoring-core; the panic hook only writes into the reserved slot.
  Restarts = a new instance_id for the same source on the metrics lane.
  New value type: array of a fixed width type (u16 count + elements;
  ClickHouse `1e <elem>`, checked on 26.3).
- Lanes as subjects `mon.<source_type>.<source_id>.<instance_id>.{logs,
  metrics,alerts,control}`. Batch shrinks to source, batch_seq, records;
  level counts, suppressions, drops and thread idle time become built-in
  metrics (`monitoring.records{level}`, `monitoring.suppressed{event}`,
  `monitoring.dropped{thread}`, `monitoring.thread.idle_ms{thread}`).
- monitoring-gw reads the metrics lane in full: heartbeat (no message for
  3 intervals), restarts, crash loops, error counts, floods, app metric
  rules by name; snapshots carry the slot table (index, name, kind, labels
  as strings), so no catalog.
- Control: NATS request/reply on the instance's control subject, answered
  by the monitor thread. `Request { op, args: [Property], deadline_ns }`,
  reply is an `Event`. Built-ins: monitoring.ping, monitoring.health,
  monitoring.snapshot, monitoring.budget.set. App ops registered at setup:
  `on_request` (runs on the monitor thread, atomics only) or
  `forward_request` (bounded queue drained by the engine between messages;
  full = busy; no answer before the deadline is a health signal). Only
  monitoring-gw may publish on control (NATS permissions per user).
Notebook revision 14.

## D31. Event logs and metrics are separate messages (2026-10-21)
"I think it's reasonable to separate a batch of the event logs from the
metrics. They have different lifetimes and, probably, different logic
associated with them." Separate messages, subjects, tables and retention.

User questions answered (notebook revision 15): what the built-in metrics
are (counters monitoring-core keeps itself: records per level, suppressed
per event, dropped per thread, thread idle time, RSS/CPU/uptime); where
instance_id is (in `Source`, first field of every message; the subject
token is only for subscribing); what MetricSample/MetricSlot are. Proposal
(not decided): `Source` table = parent_type, parent_id, source_type,
source_id, instance_id, build_id; MetricSlot dropped from the wire: each
`MetricSample` carries name, labels as strings, kind (counter/gauge),
value (counter total since start, gauge current); `Metrics` = source, seq,
time_ns, snapshot flag, samples; timing sent as four samples; in-process
slots never leave the process.

## TigerBeetle metrics (2026-10-21, user question; findings)

Read ~/work/gh/tigerbeetle at 47aeb2212 (2026-08-31): src/trace.zig,
src/trace/event.zig, src/trace/statsd.zig, docs/operating/monitoring.md.
Closed tagged union `EventMetric`/`EventTiming`, enum-typed label fields,
comptime slot = base + enum index, exhaustive no-collision test; count
saturating add, gauge last value (i65), timing min/max/sum/count. Every
10 s (trace_emit_timeout) DogStatsD text lines over UDP to a local agent,
packets <= 1400 B, `tb.<name>:<v>|c|g|#cluster:…,replica:…,<label>:…`;
names and tags in every line; timing = 5 lines. Max line size computed at
comptime, buffers fixed. Open loop; if packets still in flight, skip the
emit and log. Slots cleared after emit: counters are deltas (lost packet
loses the increase). No instance id; restart visible via `replica_start`
gauge. No alerting in TB; states as gauges (`replica_status`,
`replica_sync_stage`), docs say alert when not 0. `tigerbeetle inspect
metrics` lists metrics and cardinality.
Agent's takeaways (proposal): compile-time max Metrics message size, skip
send while previous in flight, slot no-collision test, app states as
numbered gauges; keep totals (not deltas) because NATS is lossy. Notebook
revision 16.

## Counter overflow (2026-10-21, user question; proposal)

User: what happens when total counters overflow? Agent's answer
(proposal, not decided): counters are u64 totals since process start,
`saturating_add` (release `+` wraps silently); a u64 lasts 584 years at one
increment per ns, 58 years at 10 GB/s of bytes, so overflow means a bug.
Monitor thread emits `monitoring.metric.saturated` once per slot at
u64::MAX and counts `monitoring.saturated`; debug assert per `count()` add
< 2^48; readers compute increases only within one instance id (new
instance = new baseline, no wrap logic), a decrease within one instance is
counted as a bug; gauges i64, set not added, `u64` above i64::MAX clamped
and counted. Wire: MetricSample gets `counter: uint64` and `gauge: int64`
fields instead of one `value: int64`. Notebook revision 17.

## D32. Saturating counters (2026-10-21)
"okay, saturating add is fine." Counters are u64 totals since process
start, added with saturation; details as in "Counter overflow".

## D33. `AmountSemantics` enum, no boolean flags (2026-10-21)
"let's use the enum instead of a boolean. Call it 'amount semantics' with
snapshot/increment. Don't use boolean flags." `Metrics.snapshot: bool`
becomes `amount_semantics: AmountSemantics` with `Snapshot` (every metric)
and `Increment` (only metrics changed since the last message). Agent note:
in both, a counter's value is its total; `Increment` names which metrics
the message holds, not that values are increases. Notebook revision 18.

## D34. Metrics: full snapshots only, not stored for now (2026-10-21)
User asked why not send all values. Agent: changed-only saved bandwidth
that is not worth it (~20 KB per process per 10 s); full messages make a
lost message free and let a reader starting mid-way see everything.
User: "I'm not planning to store those in clickhouse right now. Let's send
snapshots only for now." Every metrics message carries every metric
(counter totals, gauge values); `AmountSemantics` and `snapshot_every`
removed (D33's no-boolean rule stays general). Metrics are read only by
monitoring-gw for now; event-gw does not store them. Agent details: a
timing with no calls in the interval sends count and sum only; closed
label sets give a compile-time max message size; control op renamed
`monitoring.metrics` (send a metrics message now). Notebook revision 19.

## Build pipeline as an event stream (2026-10-21, user proposal; findings + proposal)

User's proposal: the build pipeline is one function on a Platform API like
Heimdall (`function* build_pipeline(p: Platform.Trait)`), so all steps are
followed locally. A build combines git, image, toolchain, binaries, linker,
monitoring registry (catalog), debug info. Event sourced: first command
`builds.create`, then events with the build id and an orderand, then
`builds.commit`. Application server primary (stores the event stream and a
materialised build record, assigns a snowflake id); bucket as redundancy
when the app server fails, and a job pulls bucket builds into the database
once the app server is back. Avro schemas of the events stored in the
database and the bucket. Catalog and debug info files in a bucket, events
hold references. Step latency from the events. Endpoints internal, callers
must be in the structure org. Offline id: u64 from time and randomness.
The build id is embedded in each binary. Unsure about the API and how to
handle docker bake. This reverses the earlier "bucket as source of truth"
proposal.

Findings:
- `just bake` labels the image with one repo's commit (`source_revision`
  from `io.stxr.source-repo`), but the Docker context is the whole
  workspace (`COPY . ./`) and `.cargo/config.toml` patches point at local
  checkouts: the binary is built from every reachable repo at the laptop's
  state, uncommitted changes included.
- The builder stage cross compiles (`--platform=$BUILDPLATFORM`); on an
  arm64 host the amd64 binary cannot run, so a catalog printed by the
  binary with a flag does not work in the build.
- Target dir is a cache mount, release has no debug info; only binaries
  leave the builder. `just bake` already reads the digest from buildx's
  `--metadata-file`.
- App server already has snowflake ids (41 ms since 2026-01-01 | 10
  instance | 12 sequence; api uses instance 1), the append-only
  `avro_schemas` table and Avro single object encoding (app-db
  `src/avro/`). Strategy images go through the `build-strat` workflow
  reducer (Validate, PrepareTemplate, TriggerBuild, PollBuild, …).

Agent's proposal (not decided):
- Pipeline reads the source before the build (every repo in the context
  with its commit, refuse dirty trees), not from the image label after.
- Enforcement in four layers: receipts from every step, `commit` takes all
  (type error if a step is missing); the host records `Failed { step }` and
  step start/end itself; the server refuses commit unless the record has
  every part its kind requires; deploy refuses a digest without a committed
  build, and `process.start` carries the build id plus the linker build id
  read from the process's own ELF note, monitoring-gw alerts on unknown or
  mismatch.
- One Avro `BuildEvent` schema, union body (Created, SourceSnapshotted,
  ToolchainResolved, BinariesLinked, DebugInfoStored, CatalogStored,
  ImagePushed, Committed, Failed); envelope build_id u64, seq u32
  (orderand, assigned by the pipeline as single writer), started_at, time;
  server adds receive_time and origin enum {Direct, BucketImport}; identity
  (build_id, seq), append accepts seq = last + 1, identical resend is a
  no-op; `builds` row folded in the same transaction; app server deploys
  before writers use a new branch.
- Write every event to both the app server and the bucket on every build
  (a path used only in outages is untested when needed); event recorded if
  either accepts; bucket objects create-only (`ifGenerationMatch=0`) at
  `builds/<id>/events/<seq>.avro`; import job runs on a schedule and on
  app server start and appends missing seqs.
- Offline id: a snowflake with an instance id from a reserved range (e.g.
  512-1023, random) and a random sequence; same column, time ordered,
  recognisable as offline.
- Bake stays the build definition; the pipeline replaces the `just bake`
  shell. `BUILD_ID` build arg embedded with `env!` in the binary crate
  (only that crate recompiles), replacing the `/etc/stxr/build-id` file;
  explicit `--build-id`; debug info split in the builder stage; catalog
  read from a link section of plain-byte descriptors (`objcopy
  --dump-section`), not by running the binary; a `<service>-artifacts`
  target exporting debug files, catalogs and a manifest, built in the same
  bake call as the image.
- Strategy images: the existing workflow writes the same events
  (TriggerBuild creates, Cloud Build uploads artifacts, CompleteBuild
  appends and commits); shared contract is the schema and commit rule, not
  the generator.
- The infra pipeline runs as a local CLI implementing `Platform` natively
  (no sandbox for our own code); could run in Heimdall later.
Notebook revision 20 (section "Build record" rewritten).

## Required build facts per artifact kind (2026-10-21, user question; findings + proposal)

User: how is it defined that a set of events/steps is required? TS
services have no linker or debug metadata.

Findings: application-server and activity-worker images are a rolldown
bundle compiled with `bun build --compile` (infra `images/structure-web`
Dockerfile, package justfiles); the application-server image also ships
Rust-built WASM (application-server-core, id, DSL compiler); status-board
runs `bun run src/server/main.ts` from source; Rust services are ELF from
the `rust-engine` Dockerfile.

Agent's proposal (not decided):
- Requirements follow the artifacts a build produces, not the service.
  Closed `ArtifactKind`: ElfExecutable (GNU build id, DWARF, monitoring
  catalog, toolchain), BunExecutable (bundle sha256, source map,
  toolchain; no catalog yet), WasmModule (sha256, toolchain), ScriptSource
  (sha256 of sources + lockfile, toolchain).
- One exhaustive requirements table in an app-server TS module (`satisfies
  Record<ArtifactKind, …>`), imported by the pipeline; receipt types
  derived from it. Not applicable = field absent from the variant, never
  optional. Commit parses the open record into the committed type and
  answers `missing: [{ artifact, fact }]`. Table has a revision stored at
  commit; rule changes apply to new builds only.
- Guards against under-declaring: after push, scan the image filesystem for
  ELF/WASM magic outside base image paths, every hit must be declared; at
  run time the process reports its identity (GNU build id, or bundle hash
  compiled in via rolldown `define`) and monitoring-gw alerts if the build
  has no such artifact.
- Events keyed by artifact index: ArtifactDeclared, ArtifactIdentified
  (GnuBuildId | Sha256), ToolchainRecorded (Rust | Bun | WasmPack |
  BunRuntime), DebugDataStored (Dwarf | SourceMap), CatalogStored; replace
  BinariesLinked/DebugInfoStored. Committed carries the requirements
  revision.
Notebook revision 21.

## D31. Build pipeline as an event stream accepted, except debug info export (2026-10-29)
User accepts the "Build pipeline as an event stream" proposal (2026-10-21)
up to and including the offline id: read every repo's commit before the
build and refuse dirty trees; four enforcement layers (step receipts,
server refuses incomplete commit, deploy refuses a digest without a
committed build, `process.start` reports build id + GNU build id);
one Avro `BuildEvent` schema with identity (build_id, seq), seq = last + 1;
write every event to both the app server and the bucket; offline id = a
snowflake with an instance id from a reserved range.
Open: the bake / debug info export part (BUILD_ID via `env!`, split debug
info in the builder stage, catalog read with `objcopy`, the
`<service>-artifacts` target). The user is not familiar with how debug
info is exported and asked for an explanation before deciding.
The pipeline runs locally for now (local CLI), no CI server.

## D32. Required build facts follow the artifact kind (2026-10-29)
User accepts the "Required build facts per artifact kind" proposal
(2026-10-21) as written: closed `ArtifactKind` (ElfExecutable,
BunExecutable, WasmModule, ScriptSource), one exhaustive requirements table
in an app-server TS module with a revision stored at commit, image scan +
run-time identity reports against under-declaring, events keyed by
artifact index.

## D33. First scope: infra images only, one problem at a time (2026-10-29)
The build pipeline covers only the images our infra deploys
(`infra/docker-bake.hcl` targets: Rust services from `_rust_service`,
status-board, `_web_service` application-server/activity-worker, etc.).
Strategy images (activity-worker `build-strat` workflow, Cloud Build) are
excluded for now; the earlier proposal bullet that the strategy workflow
writes the same events is deferred, not rejected.
Finding (verified 2026-10-29, buildx 0.37 / Docker 29.8): two bake targets
in one `docker buildx bake` call that share a builder stage run it once;
one can export to a local folder (`type=local`) while the other is the image.
User question raised: whether `env!("BUILD_ID")` stops builds without a
build id (answer: only if unset; an empty `ARG` still sets it), see reply.

## D34. This round handles the build id only (2026-10-29)
User: "We're only handling the build id here." Scope of the current design
round is the build identity end to end (create, embed, record image,
commit, process reports it, monitoring-gw checks it). Debug info export,
the monitoring catalog and strategy images stay out of this round (D31's
open debug info part stays open). The user asked for a Fable 5.1 advisor
review of the build id suggestions and a dev-env notebook on the design.

## Build id notebook and advisor review (2026-10-29; proposals, not decided)
Notebook `build-id` (revision 2) in dev-env sess-00qkrbe covers only the
build id. A Fable 5.1 advisor reviewed it; folded in as proposals:
compile-time parse of BUILD_ID into `Pipeline(BuildId) | Development`
(empty ARG gives `Some("")`, malformed id = compile error) via a macro
expanded in the bin crate; Dockerfile guard; existing build.rs files lack
`rerun-if-env-changed=GIT_REVISION` (separate bug); first slice drops GNU
build id, artifact events, import job and liveness; run-time check compares
`K_REVISION` → Cloud Run image digest with the build's digest; OCI label
`io.stxr.build-id` read by Pulumi at deploy; TS: rolldown `define` for Bun
executables, `ENV BUILD_ID` for status-board; `Abandoned` status for Open
builds of killed runs; source snapshot must cover every repo cargo reaches;
requirements table revision 1 requires no artifact facts.

## D35. The build entity stands on its own, apart from monitoring (2026-10-29)
User: "forget a bit about the monitoring sdk and monitoring gw when it comes
to the build entity." The build design is not tied to monitoring-core,
monitoring-gw, `process.start` or `Source.build_id`. Monitoring is at most a
later consumer of the build id. The run-time check through monitoring-gw
(K_REVISION → digest) and the `Pipeline | Development` wire shape in
`Source` are dropped from the build design. The user also said the agent
is not on the same wavelength and asked for more context and examples in
the `build-id` notebook (rewritten as revision 3).

## Decisions from the build-id notebook review (2026-10-29, dev-env annotations on revision 2)

### D36. Abandoned builds, one hour, configurable
An `Open` build with no event for a fixed time is marked `Abandoned` by the
application server ("yeah, sounds good"). One hour is fine as the default;
the timeout is configurable in the application server.

### D37. Image tied to the build both ways
Agreed: `ImagePushed` records the digest (build → image) and the image
carries the `io.stxr.build-id` label plus the compiled id (image → build).

### Not now: monitoring-gw, process.start, Source.build_id
"let's not think about the monitoring gw yet" (restates D35). The user did
not recognise `process.start` or `Source.build_id`: both exist only in the
monitoring-core-proposal notebook, not in code (`telemetry::Source` has no
build_id). Dropped from the build notebook.

### Questions raised (answered in the notebook, revision 3)
- Events table "too vague and abstract": wants concrete schemas and examples.
- Where `BuildId` is defined; does it follow the `DomainId` derive of
  entity-core / strategy-core?
- Is having both GIT_REVISION and BUILD_ID as env vars wrong; is
  GIT_REVISION still needed once a build id exists?
- Can the Cloud Run revision be linked to the build id, e.g. as an attribute
  in the Cloud Run config?
- Is the CLI in Rust?
- "deploy check also in the application server": unclear to the user.

## Decisions from the build-id notebook review, revision 3 (2026-10-29)

### D38. `BuildId` lives in a new `platform-core`
"Okay, fine": `BuildId` (`#[derive(DomainId)] #[domain(prefix = "bld")]`,
server-minted snowflake like `BacktestId`) goes in a new `platform-core`
repo in the accounting-core layout (Rust entities + build.rs codegen + ts/).

### D39. Build Avro schemas live in platform-core
"platform core, for sure": the CLI and the application server share the
build event schemas from platform-core's TS package; app-db registers them
from there. Rejected: keeping them in app-db (infra would depend on app-db).

### D40. One build = one Docker image
Explicit rule asked for by the user: a build produces exactly one image.
(An image may hold several binaries, e.g. backtest-post-processor ships
`backtest-post-processor` and `backtest-runner`; still one build.)

### D41. The build id becomes the only build identity
"Ideally, build id is the only thing remaining that is a sole
responsibility for everything build related." Keep GIT_REVISION for now,
drop the unread `git.revision` label, move readers to the build id one at
a time, alert policies last. End state: no GIT_REVISION.

### D42. Assumptions confirmed
A build records our source and the image, not Pulumi config, secrets or
Cloud Run settings. "What runs now" = Cloud Run revisions joined to builds
("simplest approach right now"). Builds run from the workspace layout (bake
context at the workspace root). Failed and abandoned builds are kept.

### D43. Allowed builders: a Pulumi-managed file, no server redeploy
Like the invite list (application-server admission, GCS file reread on
generation change): the people allowed to call the build endpoints are in a
file managed by Pulumi; changing it must not need an application server
redeploy. Replaces the agent's "add people to
internal_oidc_allowed_service_accounts".

### D44. The CLI is TypeScript
"okay" to TypeScript on Bun in infra.

### D45. Repos named by name and origin, not workspace path
"how the repository is called and where its origin is" matters, not its
folder in the workspace.

### Preferences / questions from the same review
- `time` → `elapsed_time` (user suggestion, applied in revision 4).
- `service` by name or telemetry source ids? (answered in revision 4)
- what is `requirements_revision`, what is `build_sources`, do dirty trees
  include unstaged/untracked files, is the bake HCL still needed, can the
  build id also be a service-level label (answered in revision 4).
- NEW DIRECTION: the primary users of build info are AI agents debugging
  problems; asked which optimizations to make for them, and whether there
  is a platform API in infra for agents to browse builds, images and repos
  or only a shared skill.

## D46. One program for building and reading builds (2026-10-30)
"agent and build cli can be the same program": one `builds` tool in infra
with subcommands, `builds run <target>` (the pipeline) next to `resolve`,
`show`, `diff`, `timeline`, `checkout`.

## D47. Timeline from revision create time, for now (2026-10-30)
"use create time for the services for now": the per-service timeline uses
each Cloud Run revision's create time as the moment it went live. Holds
because infra sends all traffic to the latest revision
(`TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST`; worker pools run their latest
revision). Cloud Run audit logs (exact traffic switches) only when rollbacks
or traffic splits start.

Agent explanation given, not contested: one pipeline for every infra image
(snapshot → create → define → bake + push → commit); per-image differences
live in the bake HCL target and the Dockerfile's ignore file. It is not an
activity-worker workflow; it runs locally (D31).

## D48. The build service is Rust end to end; TypeScript only does I/O (2026-10-30)
User direction for the application server side of builds, going further
than email sign-in (SESS-00RRP6T D6): the core is Rust and only the I/O is
TypeScript; because the build service is new, build it completely in Rust
with the same adapter and handler pattern. Layers: http -> handler ->
service -> repository, "where the handler is independent from transport
protocol" (the user likes this pattern). No zod schemas describe the
requests any more: validation happens in Rust entities; TypeScript passes
the data in and executes I/O ("parse the HTTP response and execute I/O").
Affects: application-server-core (new builds module), platform-core,
structure-web api (thin host), the infra `builds` program.

Notebook `build-service-implementation` in dev-env sess-00qkrbe holds the
agent's plan; all of it is proposal, not decided. Main proposals: async Rust
services that pause at host effects (Query, ReadObject, MintId, Log) with a
synchronous `step` wasm call and a 64 effect bound, instead of
wasm-bindgen-futures or hand-written phases; SQL statements in a Rust
Postgres adapter run through the existing `stxr.pg_client.query` RPC, tables
still in drizzle, a PREPARE test over every statement; platform-core split
into `platform-core` (entities) and `platform-wire` (Avro schema derived from
Rust, JSON request shapes); ids minted by the host's snowflake generator;
authentication (Google ID token) in TS, builder-list authorization in Rust;
tables without foreign keys or create_time, a `state` column. Revises D39
(schemas from Rust, not platform-core TS) pending the user. Open: driver
choice, read access, builder list format, the program's split.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 1)

### D49. No `Port` suffix
"Let's get rid of 'Port' in the name, I don't like it"; "Let's just call it
repository if that's what it is." Traits are `BuildRepository`,
`BuilderList`; adapters `PostgresBuildRepository`, `GcsBuilderList`.
Replaces dev-docs naming-conventions' `*Port` for this service; the agent
proposes amending that line in the same PR.

### D50. platform-core crate layout
`platform-core/rust/crates/platform-core` + `platform-core/rust/crates/platform-wire`.

### D51. Request/response contracts are not in platform-core
User: keep the wire and the contracts separate; the create-build request
belongs to the build service, not platform-core. Create a crate in the
application server ("build contracts or platform contracts") holding the
requests and responses and, later, the protocols and codecs. Name open:
the agent proposed `build-contracts`; the user offered both names.
platform-wire keeps only the stored event format.

### D52. SESS-00RRP6T D24 applies to build events
"stop this v1 bs": no V1/V2 record types; one set of Rust types
(`BuildEventRecord`), acceptance by `can_read(writer, current)`, as the user
settled for the invite file and template bundle.

### Questions answered in revision 2 (proposals, not decisions)
The user asked which I/O model tigerbeetle, tina, turso and Zig use and
whether theirs beats async/await; whether the Effect design was the best
possible; how drizzle and Rust SQL stay in sync; whether BuildsError matches
the TS repos. Two advisors (claude-fable-5-1 and gpt-5.6-sol at xhigh,
agent definitions advisor-fable / advisor-gpt-sol in ~/.omp/agent/agents)
reviewed. Revision 2 proposes: keep async fn paused at host effects (turso's
JS binding runs the same stepSync loop; fibers have no wasm32, callbacks need
an in-core loop); one effect at a time, numbered; SQL by StatementId catalog
with a Statement trait; typed host failures; clock and id as inputs; logs on
Step; 40001 restarts in the host; drizzle owns tables, Rust owns statements,
checked by PREPARE + pg_prepared_statements types; single-object decode
looks the writer schema up by fingerprint in avro_schemas; reasons
registered per service, FAILED_PRECONDITION for NOT_A_BUILDER, canonical
ENTITY_NOT_FOUND, internal errors answered by the host. Open: read access,
builder list format, contracts crate name, program split, D39 revision.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 2)

### D53. Reads open to stxr.io
"let's do open to stxr.io": get/list need any verified stxr.io Google
identity; writes (create, append) need the builder list (D43).

### D54. The contracts crate is `build-contracts`
Settles D51's name: `application-server/crates/build-contracts`.

### D55. The builds program is TypeScript + the core's wasm
Keeps D44; the program's decisions come from Rust through wasm.

### D56. SQL statements referenced by `StatementId`
The user likes the closed statement catalog ("quite elegant", "very good
decision") and the PREPARE + pg_prepared_statements type check ("smart").

### Direction and questions from the same review (not decided)
- Clock and ids: the user would let business logic mint ids and inject time
  (and a crypto randomness source) through an I/O-like interface, not read
  the clock once in the host, so time can be simulated later; asked whether
  the snowflake generator should move into Rust with the host passing time.
- Bucket access: ReadObject vs an HTTP request built in Rust (tagged GCP so
  the host adds the token) vs a typed GCS op the host maps to HTTP/gRPC.
- Logs: catalog ids like SQL statements, as in the monitoring SDK.
- Query builder instead of plain SQL strings; drizzle interop?
- Does tina restart work like "host drops the operation and restarts"?
- User view: async's real problem is hidden control flow; explicit effects
  avoid hand-written state machines.
- Asked for a rule or skill in application-server capturing the I/O model.
- Asked whether `ts/` means `ts/packages/platform-core`.
Second advisor round (advisor-fable, advisor-gpt-sol) answered; notebook
revision 3 proposes (not decided): an injected `Runtime` (host writes the
clock on every step, Rust snowflake twin in stxr-domain that carries instead
of spinning, own instance id 2, `Entropy` trait with getrandom on wasm);
retries re-mint (reverses rev 2); `ObjectOp::{Head, Get}` on a closed
`ObjectId` mapped by the host to the gcp client (GPT Sol preferred a
Rust-built HTTP effect with a GCP auth tag); a numbered `LogEvent` catalog
with a compile-time-checked `log!` macro, records on each Step, host renders
via argus (linkme is off on wasm); table/column constants plus a small query
assembler (GPT Sol preferred SQL text in a `statement!` macro; drizzle
interop rejected); restart contract like turso (only 40001, fresh tx, fresh
operation, bounded); "What async still hides" rules and clippy denies; a
ten-point draft for a new application-server/AGENTS.md; reads check the
token's `hd` claim, new `NOT_IN_ORGANIZATION` (PERMISSION_DENIED). Open:
bucket op vs HTTP, assembler vs statement!, getrandom vs host bytes, core
instance id, rule home, builder list format, D39.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 3)

### D57. platform-core TS package at `ts/packages/platform-core`
After the agent said the other cores use `ts/` as the package root, the user
chose "let's do ts/packages/platform-core" anyway.

### D58. Argus naming in Rust
"maybe let's stick to the argus naming in the rust part as well": the Rust
log API is argus (`argus::info!`, `argus::{level}!`), mirroring the
monitoring SDK interface, not a separate `LogEvent`/`log!` vocabulary.
Rejected: revision 3's hand-written `LOG_CATALOG` array and `LogEvent` enum
("I don't like that. WASM has no static memory? There is nothing we can do
in compile-time?").

### D59. Bucket access: Fable's typed object operation, generic object names
"Fable" (typed `ObjectOp` Head/Get mapped by the host to the gcp client, not
an HTTP request built in Rust), but "not have the object id as a number and
allow some generic behaviour": the object is a string or a structured value,
not a closed `ObjectId` enum ("this is a step too far").

### D60. Randomness: Fable's suggestion
"I would go with whatever Fable suggests": random bytes are a host input;
the core does not call getrandom.

### D61. Snowflake in Rust with its own instance id
"smart" (carry instead of spin, never regress) and "full support" (the core
gets its own instance id; TS repositories move to the core's generator
later). The user questioned placing the generator inside the Runtime: he
expects one generator created once as wasm module state and injected as an
argument to whatever needs it, with the generator taking the runtime clock.

### Questions raised (not decided)
- SQL: "sea-query I think is a good lib, no?"; evaluate sea-query against the
  hand-made assembler; "if the schema changes, I want a type error in rust";
  idea: a revision id per table, verified against the database at program
  start, like notify-gw's ClickHouse startup check (SESS-00R0FYF).
- Event sourcing (new direction to explore): build the feature fully event
  sourced: an event per operation stored in Postgres (Avro, avro_schemas),
  views derived from events, all mutations through the event pipeline, each
  mutation with its own orderand so a caching client asks for everything
  after its last orderand. Focus on domain events first; audit and activity
  events (brainstorm/prompts/domain-events/classification.md) later. Relates
  to ISS-0BBJ6.
Third advisor round (advisor-fable, advisor-gpt-sol) answered; notebook
revision 4 proposes (not decided):
- Logger: `argus::{level}!(ctx, "name", { key: Type = expr }, description = …)`
  mirroring the monitoring SDK; one pointer-free static descriptor per call
  site in a wasm custom section `argus.catalog` (cfg_attr wasm32; verified by
  both advisors through wasm-bindgen + wasm-opt with the release flags; Bun
  reads it with `WebAssembly.Module.customSections`); kind/revision from
  const fn hashes (D21, D25); records carry kind, revision, values; host
  compiles the module, reads the section, then instantiates; flood budgets
  in the host by kind (GPT Sol preferred in-core). `linkme` has no wasm
  target; `inventory` works but is a runtime registry. Crate
  `application-server/crates/argus`.
- Event sourcing for builds: only write = append events; `builds` and
  `build_sources` are projections written by the event store in the same
  transaction; pure `decide(stream, command, now)`; `BuildEventStore {load,
  append, idle}`, `BuildReads {get, list, changes, events}`; orderand from a
  `feed_heads(feed, head, published)` row advanced inside the writing
  transaction and locked last (streams first, ascending ids), the turso
  commit-timestamp idea; snowflake and sequences rejected as cursors
  (visibility gap); xid8 watermark named as the scaling path; `builds:changes`
  with full summaries, `list` returns `as_of_orderand`, filters on immutable
  fields only; `build_events` doubles as outbox, `publish` operation with a
  `Publish` effect, at least once, dedup by `event_id`; server-assigned
  fields in columns, not in the Avro bytes; rebuild operation; no snapshots.
  GPT Sol differed: separate outbox table, command receipts with a stable
  CommandId, a typed `:apply` endpoint instead of appending encoded events.
- Tables: Rust owns the build tables (`Column<T>`), drizzle definitions
  generated from Rust, per-table `TableRevision` checked at startup (refuse
  to start), aligned with event-gw's uncommitted ClickHouse TableRevision;
  typed assembler kept over sea-query (sea-query builds for wasm32 but does
  not type values; switch point named). GPT Sol preferred vendoring sea-query.
- Runtime holds clock and host-provided entropy only; `SnowflakeGenerator`
  is module state injected into services, `next(&clock)`.
Open: event sourcing go/no-go, assembler vs sea-query, create idempotency
key, Avro encoding on the event-gw feed, core instance id, rule home,
builder list format, D39.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 4)

### D62. Drizzle schema hand-written, not generated from Rust
"generating drizzle sounds like a bad plan. Let's not do that. I guess if we
have an issue, the tests will catch it and, furthermore, the revision of the
table will catch it, so, I guess, we're fine for now"; then "just hand roll
drizzle schema, I guess we'll take the pain for now of maintaining copies".
Rejects revision 4's drizzle definitions generated from Rust `Column<T>`.
The build tables exist twice: hand-written drizzle in structure-web app-db
(drizzle-kit keeps writing the migrations) and the Rust column declarations
the statements use; drift is caught by the tests and the startup table
revision check. Affects application-server-core (no drizzle codegen),
structure-web app-db.

### D63. One orderand per feed, no global sequencer
"I don't think we need a global sequencer, but we do need an orderand per
feed." Rejects a sequencer service (event-gw's ingestion sequencer style) in
the write path and any orderand shared across feeds. The builds feed has its
own orderand.

### D64. Avro is the stored event format; a mapper produces the feed encoding
"I think avro is superior for storage because it already handles revisions
and versioning. I don't think flatbuffers or protobuf has this capability
built-in? There would probably be a mapper from avro to whatever the feed is
needed". Answers revision 4's open item 4 in direction: events stay Avro in
storage; whatever encoding the event-gw feed needs is produced by a mapper
from the stored event. Where the mapper lives and which feed encoding are
still open.

### D65. No `as_of_` fields
"I don't like this `as_of_` pattern, I think google in their
https://google.aip.dev/ are also against it". Rejects revision 4's
`as_of_orderand` on the list response; the replacement name and shape are
open.

### Direction and questions from the same review (not decided)
- `decide(stream: Option<&Stream>, …)`: "The moment I see an option<> it's a
  smell to me, something is off." Asked for research into event sourcing
  techniques, with advisors, for "an elegant solution"; "The more ideas you
  generate and collaborate on, the better".
- "Does it make sense to store the commands in the database to have a clear
  provenance or is it too much?"
- Asked what a feed head is.
- Asked how turso, tigerbeetle and foundationdb solve out-of-order
  visibility of commit numbers ("similar to CME and HFT architecture").
- "are we calling the table the build_events or do we have a global events
  table with all the events there? … in the future, I assume, we can put
  others in there"
- Whether the create command id copies tigerbeetle's request number.
- "u64 is not a bigint?" (argus host rendering u64 as a decimal string).
Fourth advisor round (advisor-fable on claude-fable-5-1; GPT-5.6 Sol via a
copy of advisor-gpt-sol routed through github-copilot, advisor-gpt-sol-copilot,
because openai-codex hit its usage limit). Notebook revision 5 proposes (not
decided):
- No `Option` in the write path: `Build::create` takes no state;
  `Stream::decide_append` / `Build::decide_idle` take a loaded stream and
  return closed `AppendDecision {Append, AbandonThenRefuse, Resend}` /
  `IdleDecision`; views computed from the folded `Build` (`builds_row`,
  `source_rows`), removing `Projection::project(Option<Row>)`, `BuildCommand`,
  `decide`, `EventBatch`. Both advisors ranked this first. Split: GPT Sol
  `load -> Result<Stream, NotFound>` with separate store `create`/`append`
  (chosen in the notebook); Fable `find -> Option` + `ok_or` and an
  `Expected {NoStream, After(Seq)}` enum. Option stays on reads by id.
- No command table; refusals are argus records; the create request id is
  the only command datum stored.
- One `domain_events` table for all feeds: PK (feed, stream_id, seq),
  unique (feed, orderand), feed smallint closed set; views per entity.
- "Feed head" renamed `feed_orderands (feed, last_orderand)` (GPT Sol);
  publish position split into `feed_publications`; publish reads and sends
  outside a transaction, then a guarded update.
- Ordering explained as two families: single writer (tigerbeetle, CME) vs
  early numbers + watermark (FoundationDB, turso, event-gw sequencer); the
  counter row is family 1; rev 4's turso analogy corrected.
- Writes at Read Committed (both advisors) instead of the api's default
  Serializable; sweep locks all its streams in one statement first (Fable);
  restarts on 40001 and 40P01.
- Catch-up: `builds:changes?cursor=` from empty cursor answering
  `{list, tail_cursor, more}` like positions:poll (GPT Sol, chosen); Fable's
  `sync_token` from the list shown as the alternative; opaque HMAC Cursor;
  `after`/`after_seq` removed (AIP-140 prepositions, AIP-158 opaque tokens).
- Feed stays protobuf: builds feed + codec in data-feed-definitions,
  `FeedKind::BuildEvents`, mapper BuildEvent -> prost in the core next to
  feed.rs (GPT Sol; Fable: in platform-wire). event-gw decodes protobuf only.
- Create idempotency: AIP-155 `request_id` (UUID) stored in `BuildCreated`
  and unique `builds.create_request_id` (GPT Sol; Fable: column beside the
  seq 0 event); resend returns the first build; other body ->
  `REQUEST_ID_REUSED` 409. Not tigerbeetle request numbers (sessions,
  eviction) but its client-chosen ids (`exists_with_different_*`).
- argus host decodes u64 as bigint; sinks render text via serialize_json.
- Startup column check by name via pg_attribute/format_type, order ignored,
  undeclared columns must be nullable or defaulted; runs in structure-web
  tests; event-gw's revision idea copied, not shared (GPT Sol; Fable: share).
Open: event sourcing go/no-go, NotFound vs Option at load, one events table,
Read Committed, catch-up shape, create request_id, feed mapper location,
assembler vs sea-query, core instance id, rule home, builder list format, D39.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 5)

### D66. Typed statement assembler, not sea-query; revisit with joins
"Okay, use the fable suggestion. If we have joins, we'll revisit"; on the
open item: "let's go with the recommended option". Statements are built by
the small typed assembler over `Column<T>` constants in the core. sea-query
is rejected for now (it does not type values); the switch point is the first
need for joins.

### D67. Copy the table revision idea; do not share a crate with event-gw
"copy the revision idea". application-server copies event-gw's
TableRevision/startup column check idea instead of depending on a shared
crate (repos stay independent).

### D68. Build service goes event sourced as in revision 5
On the open item (event sourcing with split rules, event store, views from
the folded build, one counter row per feed, `builds:changes`): "I like your
recommendatation". Replaces revision 3's direct writes. Read Committed and
the load/NotFound shape are not part of this decision (still open).

### D69. One events table for every feed; its structure is open
"singe table, the question is the structure of that table". Also asked
what identifies a feed ("what's a feed -> u256?", "or is it the feed kind
and feed subject id from the data feed ideas in the brainstorm sessions?").

### D70. Catch-up through `tail_cursor`
"let's do tail_cursor": `builds:changes` answers `{ list, tail_cursor, more }`
like `positions:poll`, starting from an empty cursor. Fable's `sync_token`
rejected.

### D71. `create` idempotency by request id
"recommended option": a `request_id` the caller sends with `create`, kept in
`BuildCreated` and unique on `builds`; a resend returns the first build.

### D72. The core's snowflake generator has its own instance id
"yeah, for sure. different instance id" (2, from config, as proposed).

### D73. The rule lives in application-server/AGENTS.md
"agents file is fine". The SPEC promotion was not addressed.

### Questions from the same review (not decided)
- Read Committed: "Isn't read committed a dangerous way to handle postgres?
  Isn't there something in between that satisfies our needs?"
- "puts it in core - which core?" and "I'm not sure what core means here and
  how is the mapping going to be done" (the feed mapper).
- `load` answering NotFound vs `find -> Option`: "I didn't understand this
  part".
- Builder list format: "what's this for?"
- D39: "i don't know what d39 is, explain the full context".
Fifth advisor round (advisor-fable, advisor-gpt-sol-copilot; both ran
experiments in a throwaway database on the local Postgres 18). Notebook
revision 6 proposes (not decided):
- Read Committed for create/append/abandon_idle/rebuild, safe because a
  write transaction only locks, reads locked rows, reads append-only tables
  or writes; enforced by a per-statement `Access` closed set and a
  `TransactionNeed {None, Write, SnapshotRead}`. Measured: Repeatable Read
  and Serializable abort the counter-row update with 40001 even as first
  statement or after pg_advisory_xact_lock; LOCK TABLE first works but
  serializes all feeds; in-host serialization holds on one instance only.
  Commit visible before lock release verified in xact.c (Fable).
- domain_events structure: `feed_kind smallint` (StoredFeedKind, the data
  feed kind), `stream_id` = subject id (BuildId), orderand per feed kind,
  128-bit event_id/trace_id as uuid (ULID minted from clock + host entropy;
  GPT Sol; Fable kept the snowflake widened on the wire), no type or feed
  revision column; FeedId (u256) = kind id ‖ subject id computed at publish,
  not stored; DataFeedSubject::Build(BuildSubject) in data-feed-core.
- Mapper in application-server-core builds/infrastructure/feed.rs behind a
  `BuildFeed` trait: pure function filling the prost BuildDomainEvent,
  FeedEncoder::encode_build_domain_event (Fable; GPT Sol: trait view +
  codec producer). Publish effect carries feed_kind, feed_subject,
  feed_revision, encoding; ordering key = feed_subject.
- Fixes: rebuild takes `lock table builds, build_sources in exclusive
  mode`, upserts, no delete-reinsert, no counter lock; counter is an upsert
  (first event of a feed); extra select for AlreadyCreated; sweep `for update
  skip locked`; demo feed revision ids hash the seed (no revision bump on
  content change).
Open: Read Committed, domain_events structure, load NotFound vs Option,
mapper style, builder list format, D39 revision.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 6)

### D74. The write path loads with `Result`, not `Option`
"Result<>, not Option": `BuildEventStore::load -> Result<Stream,
BuildsError>` with `NotFound` inside (GPT Sol's side). Rejected: Fable's
`find -> Option<Stream>` + `ok_or` per use case.

### D75. Read Committed for the build writes; its reasons go into decision records
"okay, then it's fine to use read committed. I think there should be a list
of the decision documents in the application-server/docs/decisions
explaining why it's safe". Writes run at Read Committed under the lock rule
(a write transaction only locks, reads locked rows, reads append-only
tables, or writes). application-server gets a `docs/decisions` folder whose
records explain why it is safe; the list of records is part of the plan.
(Convention not chosen by the user: sim-gw uses local `ADR-NNNN`,
stxr-client-app uses KB-generated `DEC-<id>` with KB pointer entries; an
earlier version of this entry wrongly attributed ADR-NNNN to both.)

### D76. Event ids are 128 bits, minted as ULIDs; not typed as UUID
"128 bits - yes. UUID -> no, I think there may be multiple different
approaches we take for the event ids. Unless uuid here means 128 bit
number. I think ulid is fine". The id is a 128-bit number; ULID minting is
fine; the column must not claim UUID semantics (storage type open).

### D77. Builder list is Avro
"AVRO", answering JSON vs Avro for the Pulumi-managed builder list (D43).
Rejected: the JSON file proposed for Pulumi's convenience.

### D78. D39 revised: Rust is the source of truth for build event schemas
"yeah, we're moving to rust and it's the source of truth"; "we go away from
typescript and rust is the source of truth". The schema is derived from
Rust types in the platform-core repo's Rust crate (today named
platform-wire); the core registers it in avro_schemas at startup. Replaces
D39's TypeScript package and app-db registration.

### D79. The feed mapper lives in application-server-core
"I think application server core is a fine place for that". Placement only;
how it fills the message (by hand vs a codec producer) is not stated.

### Questions and direction from the same review (not decided)
- Rename platform-wire: "maybe instead of -wire, we call it schema, so it
  removes the confusion from contracts and data feeds?"
- domain_events structure rejected as proposed: orderand must not be tied
  to the feed kind ("I don't think that all the trading accounts feeds will
  share the same orderand, probably all the trading accounts that belong to a
  parent like user or project or org"); feed revisions will change while
  "the orderand must be kept"; "check that first [the data feed catalog
  brainstorm sessions] and be sure that our schema will not end up fucked up
  and needed migrations"; "The caller, origin, is probably something that
  should stay away from that table. This is more of an audit log than the
  domain event"; "feed descibes many events, here we store a single one. So,
  we need some very clear naming and decisions here".
- "Does tigerbeetle have a similar feature where it notifies on changes?"
  (publishing).
- "well, we could send avro within feeds if you think that's better".
Sixth advisor round (advisor-fable, advisor-gpt-sol-copilot). Notebook
revision 7 proposes (not decided):
- Events table from the data feed catalog material (catalog never names who
  scopes our orderands; every catalog id is a hash that may change):
  `domain_events(entity_kind, entity_id bytea 8..32, seq, scope_kind,
  scope_id bytea, orderand, event_id bytea16, trace_id bytea16, event_kind,
  record_time, record)`, PK (entity_kind, entity_id, seq), unique (scope,
  orderand), unique event_id; `orderand_scopes(scope_kind, scope_id,
  last_orderand)`; `event_audits(event_id, caller, origin)` same tx, no view
  reads it; no feed kind/subject/revision stored. Orderand scope stored per
  event, chosen by the entity's rule (`Builds`; later
  `TradingAccountsOf(parent)`), `Lineage {First, Replaces(scope)}` floor so
  moved entities keep increasing orderands. Names: entity (GPT Sol) over
  stream (Fable); event_kind kept (Fable) vs omitted (GPT Sol).
- Publish position `event_publications(publication, scope_kind, scope_id,
  published)` (GPT Sol) over Fable's `event_outbox`; post-commit trigger +
  scheduler backstop, single publisher, replay op (from tigerbeetle CDC,
  which is a poller, not push); no Avro on the feed (catalog D5 FlatBuffers).
- Event ids bytea(16) (both measured); request_id stays uuid.
- Rename platform-wire: platform-schema (user's word, Fable) recommended vs
  platform-avro (GPT Sol).
- Avro body as a tagged record with one optional field per variant
  (apache-avro 0.22 cannot resolve unions into Rust types; GPT Sol
  experiment); refuse events whose writer schema is newer than the binary's.
- Decision records: stxr-client-app DEC convention, twelve records listed.
- Builder list written by a `builders` CLI command next to `invites` (core
  wasm), not Pulumi; sweep batch 10 (effect bound); entropy sized per op.
Open: events table, publish position, crate name, mapper style, builder
list writer, decision records + KB pointers.

## Decisions from the build-service-implementation review (2026-10-30, dev-env annotations on revision 7; review closed)

### D80. The stored format crate is `platform-schema`
"platform-schema". Replaces `platform-wire` (the `*-wire` name means
protobuf messaging crates in this workspace). Rejected: GPT Sol's
`platform-avro`.

### D81. Orderand scopes: `Platform`, later organization → project → user
"I was thinking of having it be "Platform" as the global scope for
everything that belongs to structure, then for other entities we can go
with organization -> project -> user, etc". `ScopeKind::Platform = 1`;
builds draw orderands from the Platform scope (shared with any other
platform-owned entity). Organization/project/user scopes are added with the
entities that need them. Replaces revision 7's `ScopeKind::Builds`.

### D82. `event_audits` holds the actor and the trace id; no origin
"no need in restriction on varchar length"; "I would call it actor. with
actor type and actor id, where actor id is a string"; "let's remove the
origin column for now, but add the trace_id column". Table: `event_audits
(event_id bytea16 pk, trace_id bytea16, actor_type smallint, actor_id text)`.
`trace_id` also stays on `domain_events` (feed contract), per the notebook.

### D83. A builders CLI is optional and may be Rust
For the implementer: "If it sees it reasonalbe to implement the builders CLI
for testing, it can. I think now it makes sense to do that in rust, since
there is a lot of logic already in rust. However, I'm not too picky with the
CLI, I care more about application server and the rust impl." Affects the
builder list writer (D77); the `builds` program itself stays as D44/D55.

### D84. Review closed; recommended options are the plan
"okay, it seems we are set". Where revision 7 offered a choice, the
recommended option stands: the events table as in "The events table" with
`event_kind`; publish cursor per publication and scope
(`event_publications`); mapper filled by hand in application-server-core;
builder list written by a `builders` command; decision records in the
stxr-client-app convention (KB pointer entries still need the user's OK).
Notebook revision 8 is final. Questions answered in replies: what
`event_kind` is; `seq` vs `orderand`.

### D85. Implementation is handed to an implementer agent
The user asked for a handoff: implement the application server part
following this session and notebook revision 8; "The agent should use
workflows and advisor agents. If it needs inspiration, I think tigerbeetle
is quite a good codebase."
