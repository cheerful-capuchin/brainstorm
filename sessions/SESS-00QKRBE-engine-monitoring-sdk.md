---
create_time: 2026-10-14T15:06:22Z
title: "Engine monitoring SDK: logs, panics, metrics over a dedicated NATS"
summary: "No decisions yet. Constraints: monitor crate in monitoring/rust/crates (Sentry-like init), dedicated NATS, FlatBuffers batches, try_send, panic addresses + build id. Proposals P1-P8: land alerts-through-logs first, per-thread rings in logger2, call-site ids, typed resource/subject + key registry, JetStream capture, debuginfod bucket, atomic metrics, notify-gw rules"
related_sessions:
  - SESS-00PYN1M
  - SESS-00PYCE2
agents:
  - claude-code:d3dec06a-db6e-4a54-b36e-6bd06a41da0b
  - claude-code:f226bb41-67de-4bfe-8890-f598c2e463bd
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
