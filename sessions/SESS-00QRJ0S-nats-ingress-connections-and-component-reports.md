---
create_time: 2026-10-16T10:48:57Z
title: "NATS ingress producer with many named connections, and a component report channel"
summary: "NATS connections named with their telemetry Source string (D1: no service prefix, no role; D2: telemetry ConnectionName new/from_source, required in ipc/logger2/TS NatsClient; D3: logger metadata of sim-gw, target-exec, event-gw, gw-mon fixed to registered sources) - implemented, uncommitted in 14 repos. D4 proposed: ingress producer takes connections [{connection_id u16, url, name, max_reconnect_attempts u16, subscriptions [{topic}]}], flat routes, statuses carry connection_id, per-connection reconnect loops. D5: the component decides what a dead connection means. Idea (not decided): ComponentReport channel (Stop, Health) read by a runtime supervisor in main instead of the control channel or context.stop(). Open Q1-Q6."
related_sessions:
  - SESS-00QKRBE
  - SESS-00QKS30
  - SESS-00PYN1M
agents:
  - claude-code:c655a3c4-9d09-4922-8d51-4323291789d7
---

# SESS-00QRJ0S: NATS ingress producer with many named connections, and a component report channel

## Trigger (2026-10-15/16)

While adding NATS monitoring to infra (Cloud Monitoring uptime check, prometheus-nats-exporter
plus the Google-built OpenTelemetry Collector on the NATS VM, PromQL alert policies; uncommitted
in infra), the live server (`nats-server-tokyo`, NATS 2.12.1, up since 2026-05-11) showed:

- 1494 slow consumers and 214k total connections since start; 14 open connections.
- No client sets a connection name, so `/connz` and the `Slow Consumer Detected` log lines only
  show an address and a `cid`. Slow consumer lines are logged at INF level and rate limited.
- The likely slow consumer is target-exec: one ipc subscriber merges its control topics and the
  whole `DATABENTO_MBO_FEED` firehose on one connection.

The user asked to name every connection, and then to let one ingress producer hold several
connections.

## Decisions

### D1: A NATS connection is named with its source's canonical string, nothing else

- Name = `telemetry::Source` string (`system.0000000000000.gateway.7W21YWQ3QQ5TA`), metadata and
  version included as `Source`'s `Display` writes them.
- Rejected: a service-name prefix (`sim-gw:...`). User: the whole point of the identifiers is not
  having to prefix them; discovery is fixed with tooling, and `telemetry/registry/sources.toml` is
  easy to search.
- Rejected: a role suffix (`:subscriber`, `:publisher`, `:logger`, `:runtime-events`). User: the
  role makes no sense on the connection name. Every connection of a process carries the same name.

### D2: `ConnectionName` lives in telemetry with `new()` and `from_source()`

- Rust: `telemetry::ConnectionName(Arc<str>)`, `new(impl Into<Arc<str>>)` (asserts non-empty),
  `from_source(&Source)`, `as_str()`, `Display`.
- TS: `ConnectionName` namespace in `@structure/telemetry`, branded string, `make()` and
  `fromSource()` (`new` is a reserved word in TS, so the agent used `make`, as `Subject.make`).
- Added `Source::system(source_type, source_id)` for the registered system sources.
- The name is required: ipc `NatsProdV2Config`, `NatsPublisherConfig`,
  `NatsPublisherWithCtxConfig::new`, `logger2_backend::NatsLogDispatcher::new`, TS
  `NatsClient.connect({ name })`. Services pass `ConnectionName::from_source(..)` of their
  registered source (SIM_GW, TARGET_EXECUTOR, EVENT_GATEWAY, REALTIME_GATEWAY, CME_DATABENTO,
  GW_MON, MARKET_INFO_SERVER, notify-gw's configured source, the deployment source for
  strategies, the process source for application-server).
- Implemented 2026-10-16, uncommitted, in telemetry, ipc, logger2, runtime, sim-gw, strats_v2,
  event-gw, gw-mon, realtime-gateway, market-info, databento-mkt-data (on its `backfill-windows`
  branch), monitoring, structure-strat-template-core, structure-web. Verified against a local
  NATS: `/connz` shows the source string. realtime-gateway does not build locally because of 51
  errors that exist without the change. Deprecated `NatsWriter` / `StxrEventSink` left unnamed.
  `runtime::get_nats_egrs_config` deleted (no callers).

### D3: Logger metadata uses the registered sources, in the same change

User's answer to "fix ResourceMeta now or separately": in this change. sim-gw (was `Monitoring`
with a nil id), target-exec (nil id), event-gw (was `Worker` with a nil id) and gw-mon (nil id)
now build `EngineInstanceMeta` from the same `Source` as the connection name. Event log rows of
sim-gw, target-exec and gw-mon change their source fields; event-gw logs to stdout only.

### D4: The NATS ingress producer takes a list of connections, each with its subscriptions

User's sketch: `connections: { nats_uri, name, max_reconnect_attempts: u16, subscriptions: [{ topic }] }`,
plus a `connection_id: u16` "so we can easily identify them when we report ready".

Proposed shape (not implemented):

```rust
pub struct NatsSubscriberConfig {            // replaces NatsProdV2Config<T>; rename open (Q3)
    pub connections: Vec<NatsConnectionConfig>,
}

pub struct NatsConnectionConfig {
    pub connection_id: u16,
    pub url: Arc<str>,
    pub name: ConnectionName,
    pub max_reconnect_attempts: u16,
    pub subscriptions: Vec<NatsSubscription>,
}

pub struct NatsSubscription {
    pub topic: Arc<str>,                     // a struct, so queue groups etc. can be added later
}
```

- The generic `T: TopicTrait` goes; every caller already passes `Arc<str>` except gw-mon
  (`NewDriftGwTopics::Response.to_str()`).
- Why one config instead of one producer per connection: routed mode numbers routes by topic
  position, and strategies index their feeds by it, so two routed producers would both start at
  route 0. Routes stay one flat numbering over every subscription of every connection, in
  declaration order; with one connection that is today's numbering.
- Why several connections: NATS closes the whole connection of a slow consumer. Putting the
  market data firehose on its own connection keeps a target-exec slow consumer from dropping its
  order and control topics.
- Statuses carry the id: `NatsStatusMsg::{Ready, Disconnected, Dead} { connection_id }`.
  event-gw and gw-mon handle these statuses today.
- Each connection runs its own loop (connect, subscribe, reconnect counter against its own
  limit) inside the one producer; one control `Shutdown` stops all of them. When one connection
  gives up, it reports `Dead { connection_id }` and only its loop stops.
- `create()` rejects: no connections, a connection without subscriptions, duplicate
  `connection_id`, the same topic on two connections (delivered twice). Same names are allowed.
- Publishers keep one connection each and would share the connection part:
  `NatsConnectionOptions { url, name, max_reconnect_attempts }`. They store
  `max_reconnect_attempts` today but never read it; async-nats reconnects without a limit
  underneath them (Q2).

### D5: The component decides what a dead connection means

User: "can't we let the component decide that?" instead of ipc choosing between stopping the
subscriber and keeping the other connections. The subscriber only reports; event-gw might stop,
target-exec might stop on a dead market data connection and carry on without another one.

Correction recorded: today a `Dead` subscriber ends its task, but the engine keeps running and
`main` keeps waiting for a signal (`sig_handler.poll(None, ..)`), so nothing restarts the
process. event-gw's `Dead` alert tells the operator to restart the worker pool. An earlier agent
statement that "the process restarts" was wrong.

## Idea: a component report channel (proposed, not decided)

The user asked why not give the component the control channel, or a dedicated component
channel, since "the component can report different information there apart from stopping".

State today:

- `EngineComponentHost::process_msg` returns `()`; the engine stops only on
  `EngineIngressMsg::Shutdown` (sent by `runtime::send_shutdown_msg` from `main`'s signal
  handler) or an internal error.
- Strategies carry a `ShutdownHandler` closure in their params that calls `send_shutdown_msg`:
  outside the engine API, and it would fire again during a replay.
- `main` only waits for signals, so an engine that ended on its own leaves the process up.

Why not the control channel: it points the other way (`main` -> managers), holds only
`Shutdown`, would stop the managers but not the engine or `main`, and is bounded (16) and read by
async manager tasks, so a send from the engine thread could block.

An earlier agent proposal, `EngineStateContext::stop(EngineStop)` checked by the engine after
`process_msg`, is replaced by the channel: no engine change is needed to stop, because the
reader of the channel uses the existing shutdown path, and the channel carries more than a stop.

Proposed shape:

```rust
// ingress-egress
pub enum ComponentReport {
    Stop { reason: Arc<str> },
    Health(ComponentHealth),
}

pub enum ComponentHealth {
    Ready,
    Degraded { reason: Arc<str> },
}

impl EngineStateContext<'_, TP, D> {
    /// Live mode only; a replay reports nothing. Never blocks the engine thread.
    pub fn report(&self, report: ComponentReport);
}
```

- One supervisor channel read by `main`, three senders: the component through
  `context.report(..)`; a signal thread forwarding SIGINT/SIGTERM; the engine thread sending
  `EngineStopped(result)` when its loop ends for any reason.
- `runtime::supervise(rx, ..)` replaces `sig_handler.poll(None, ..)`: on a signal or `Stop` it
  calls `send_shutdown_msg`, joins the threads and exits, non-zero when the stop came from a
  `Stop` or an engine error so Cloud Run restarts the instance; on `Health(..)` it updates what
  the health check port answers (a pool could stay not ready until its NATS connections are
  `Ready`).
- The context drops reports outside `IngressMode::Live`, so replaying a recorded `Dead` has no
  side effects. Bounded channel, `try_send`; a full channel drops the report and logs it.
- `EngineHandle::join()` would return the `EngineLoopResult`.
- Strategies' `ShutdownHandler` becomes `context.report(ComponentReport::Stop { .. })`.
- Cost against `context.stop()`: the engine finishes what is already queued before the
  `Shutdown` arrives, as with SIGTERM today.

Proposed order: (1) ipc connections + `connection_id` statuses, useful on its own; (2)
ingress-egress/engine: `ComponentReport`, `context.report`, `EngineStopped`; (3) runtime
`supervise`, health check fed by reports, each `main` switches; (4) components decide in their
`Dead` handlers, strategies drop `ShutdownHandler`.

## Open questions

- Q1: Does the subscriber task end when every connection is dead, or idle until shutdown? Agent
  leans to ending it.
- Q2: Publishers' `max_reconnect_attempts`: drop it or make it limit reconnects?
- Q3: Rename `NatsProdV2Config` to `NatsSubscriberConfig`?
- Q4: Health check: stays a separate ingress producer that the supervisor updates, or moves into
  the supervisor?
- Q5: `ComponentHealth`: `Ready | Degraded` only, or also `NotReady` for startup?
- Q6: Replace strategies' `ShutdownHandler` in the same change as the supervisor, or later?
