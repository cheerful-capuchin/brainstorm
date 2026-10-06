---
create_time: 2026-10-06T15:01:08Z
title: "Rust monitoring service replacing the TypeScript alert-service"
summary: "notify-gw (Rust engine app, stxr-prop/monitoring) replaces TS alert-service; multihost component, StaticAllocator, Program/run in lib, FeedTransport, single-task timers, e2e via testcontainers; OPEN handoff: graceful drain (Draining state) so shutdown does not re-post in-flight alerts"
related_sessions:
  - SESS-00PYCE2
---

# SESS-00PYN1M: Rust monitoring service replacing the TypeScript alert-service

## Context (2026-10-06)

The user wants to delete the Bun alert-service
(`structure-web/packages/alert-service/src/main.ts`) and write a proper Rust
service "to normalize all our APIs". It reads the alert feeds described in
SESS-00PYCE2 D5/D9 (alerts feed, Cloud Monitoring incidents feed, legacy
`alerts` topic) and posts to a Discord webhook. Design only in this session:
no Rust code yet.

## Constraints set by the user (2026-10-06)

### C1. Repository and layout

- Code lives in `https://github.com/stxr-prop/monitoring`, Rust crates under
  `monitoring/rust/crates/`.
- The justfile uses the table/matrix setup from `entity-core/justfile`.
- Configuration follows `dev-docs/frameworks/configuration-loading.md`.

### C2. Engine architecture

- Built on the engine framework (`dev-docs/frameworks/engine-*.md`).
- `state.rs` FSM with a single marker state, `Running`.
- The logic only builds the Discord payload and emits an egress message to
  publish it.
- `on_feed_msg` follows the examples in event-gw and sim-gw.

### C3. Ingress is the feed message; one Feed Ingress Producer

- The ingress message is the feed message. Because the service knows what it
  subscribes to, it knows the data feed.
- Rejected: a "pubsub ingress producer" and a "nats ingress producer".
- Instead: one Feed Ingress Producer that takes the mapping between feed and
  topic (where to read the data from). Pub/Sub (and NATS) are only modules
  behind it.
- Consistent with SESS-00PYCE2 D9: one feed + encoding per subscription, no
  byte sniffing.

### C4. I/O as data, I/O as an interface

- Keep I/O logic as small as possible. Build each request as pure data, then
  send it over a client. Prior art the user pointed at:
  `gcp/ts/gcp/src/cloudtask/mod.ts` (build request -> send -> parse response);
  a more ergonomic Rust shape is welcome.
- I/O is taken as an interface, like Zig's `Io` parameter.

### C5. Allocation (Tiger Style)

- Follow Tiger Style as far as possible: no allocation after initialization.
- The user suggested the allocator API (rust-lang/rust#156882) with a bump
  arena such as `blink-alloc`.

### C6. Bounded request pool

- Use the event-gw approach: a bounded pool of in-flight requests where the
  pool assigns the correlation id, not the caller and not a random value.

### C7. Logging

- logger2 with the NATS and stdout backends.
- Log only important information; no per-message spam.

## Open questions asked by the user

- Q1. A better name than "alert service".
- Q2. Is there an official Google Cloud Rust SDK for Pub/Sub now (there was
  none when the event bus was written)?
- Q3. How to keep the Discord webhook secret (it is in the URI) out of the
  egress message: mask it, or pass a placeholder that the egress consumer fills.

## Findings (2026-10-06, verified by research; not decisions)

- `stxr-prop/monitoring` is private and was empty; cloned into the workspace
  as `monitoring/` with `rust/crates/` created. Not registered as a submodule.
- Q2: Google now owns the `google-cloud-pubsub` crate name (yoshidan donated
  it; his crate lives on as `gcloud-pubsub`). Official 1.0.0 on 2026-05-06,
  1.6.0 on 2026-09-30, from googleapis/google-cloud-rust: `Publisher`,
  streaming-pull `Subscriber`, admin clients. Official Secret Manager crate:
  `google-cloud-secretmanager-v1`. `ipc/Cargo.toml` still uses
  `gcloud-pubsub 1.5.1` with a comment "until the google cloud team releases
  the official PubSub package"; that condition is now met.
- rust-lang/rust#156882 merged 2026-09-23, milestone 1.100 (nightly only on
  2026-10-06; local rustc is 1.97.1). Stabilises only the `Allocator` trait,
  `Box::*_in`, `Vec::*_in`, `Global`, `System`. No `String`, `VecDeque`,
  `HashMap` in custom allocators. blink-alloc 0.4.0 (2025-12) works on stable
  through `allocator-api2`; low activity.
- Arena-backed values cannot cross the engine -> egress thread boundary: egress
  messages must own their data. An arena would only serve per-message scratch.
- Q3: Discord Execute Webhook is `POST /webhooks/{id}/{token}`; the token in
  the path is the only credential; no header form exists. 429 carries
  `Retry-After` and a JSON `retry_after`; buckets via `X-RateLimit-*`.
- `stxr_http::RequestOwned` derives `Debug` with the URL in plain text;
  `stxr-http-client` never applies `timeout_ms`, has no public constructor for
  its reqwest config, copies the body. reqwest error `Display` includes the
  URL (needs `without_url()`).
- TS alert-service: acks immediately (before decode result and before
  Discord), no retry, no 429 handling. It budgets 6000 characters per embed;
  Discord's limit applies to the sum across all embeds of one message (to be
  re-checked against the Discord docs during implementation).
- The decoders the host would call allocate: the alerts codec uses prost, the
  incidents codec uses serde_json into owned structs.
- event-gw pool: `logic/insert_request_pool.rs` (`slots: Box<[Option<_>]>`,
  `CorrelationIdGenerator` starting at 1, slot = id % len, `acquire`, `retry`,
  `release`, stale ids miss). Sizing from Little's law.
- logger2 NATS + stdout wiring reference: `gw-mon/src/main.rs` (minus the
  Pub/Sub error route).

## Proposals awaiting the user (not decided)

- P1 name: `notify-gw` (matches event-gw / sim-gw / gw-mon); alternatives
  `alert-router`, `pager`.
- P2 crates in `monitoring/rust/crates/`: `notify-gw` (engine app),
  `feed-ingress` (Feed Ingress Producer, `pubsub` and `nats` modules),
  `discord-webhook` (pure build/classify functions, no I/O).
- P3 Pub/Sub module uses the official `google-cloud-pubsub` 1.x; `ipc`
  migration is a separate change.
- P4 secrets: egress carries an `EndpointId`, never a URL; the HTTP egress
  consumer owns `Secret<Url>` per endpoint loaded with `!secret env:` and joins
  it at send time. Errors log the endpoint name only.
- P5 ack after the outcome is final (2xx, permanent failure, or attempts
  exhausted); ack is an egress request; pool full -> nack for redelivery;
  Pub/Sub flow control max outstanding = pool capacity.
- P6 allocation: pool slots and body buffers sized from Discord limits and
  allocated at startup; bounded engine channels; no arena until a scratch need
  appears; accept allocation inside third-party SDKs and the feed decoders for
  now, bounded by capacities.
- P7 legacy `alerts` topic not supported by the Rust service (not a feed);
  TS service stays until publishers move to the alerts feed.
- P8 drop the `/health` and `/ping` HTTP server (Cloud Run WorkerPool).
- P9 extract event-gw `InsertRequestPool` into a shared generic pool crate
  (second user).

## Decisions (2026-10-06, second round)

### D1. Name: `notify-gw`
Accepted P1. Main crate `monitoring/rust/crates/notify-gw`.

### D2. Discord webhook URI travels whole in the HTTP request
Rejects P4 (EndpointId + consumer-side secret table). The user: "this sucks,
I'll just pass the whole uri, don't want to deal with that". The webhook URL
is a `Secret` in config and the logic puts the full URI into the request.
Consequence (not a decision): requests must not be Debug-logged.

### D3. Ack only when the outcome is final
Accepted P5: ack after 2xx, permanent failure, or attempts exhausted; pool
full -> nack for redelivery; Pub/Sub flow control max outstanding = pool
capacity. The ack is a ticket the logic always sends; sources that are not
durable streams (core NATS) treat it as a no-op.

### D4. Only the new feeds
Rejects reading the legacy `alerts` topic. notify-gw reads the alerts feed and
the Cloud Monitoring incidents feed only (SESS-00PYCE2 D9 feeds).

### D5. Startup check only
Cloud Run worker pools need a startup probe (infra
`lib/worker-pool-health.ts`, TCP on 8080). The check is needed only at
startup; afterwards it is removed so it does not waste resources. No `/ping`.

### D6. Telemetry source in config
Config takes the telemetry `Source` object; it is needed for logging
(logger2 engine meta, log source).

### D7. Allocation: best effort
The user believes bounded channels cannot be passed to the engine and accepts
that; static allocation is kept wherever possible (supersedes the "bounded
engine channels" part of P6).

### Still open
- P2 crate split, P3 official Pub/Sub crate, P9 shared pool crate: not
  answered.
- HTTP client: fix `ipc/crates/http-client` or new crate. The user asked
  which timeout; answer given: `HttpClientRequest.timeout_ms` is never read.
- FeedMsg `route` proposal: u16 index into the startup binding table.

## Decisions (2026-10-06, third round)

### D8. HTTP egress: fix `ipc/crates/http-client`
No new HTTP crate. Fix the existing one (public constructor for the reqwest
config, apply `HttpClientRequest.timeout_ms` per request).

### D9. Crate split accepted (P2)
`monitoring/rust/crates/`: `notify-gw` (engine app), `feed-ingress` (Feed
Ingress Producer with `pubsub` and `nats` modules), `discord-webhook` (pure
build and classify functions, no I/O).

### D10. Official `google-cloud-pubsub` SDK (P3)
Use Google's official crate in the `feed-ingress` Pub/Sub module. The user
notes it does not expose the request-builder style they prefer, and accepts
that rather than spend time on it. `ipc` migration not part of this work.

### D11. Copy the event-gw request pool (rejects P9)
Copy the `InsertRequestPool` shape into notify-gw; no shared pool crate.

### Open
- Telemetry source id: reuse `monitoring/DISCORD_ALERT` (`5VCQ2VF7C44P2`) or
  register a new `NOTIFY_GW` source. User asked what it is; explained.
- Startup check mechanics (D5): proposed host-decided readiness -> egress
  `StartupReady` -> one-shot TCP listener on 8080 that answers one probe and
  closes, with a deadline. Not yet accepted.

## Decisions (2026-10-06, fourth round)

### D12. Startup check lives in `main`
Rejects the engine-driven `StartupReady` proposal. `main` opens port 8080
(infra `WORKER_POOL_HEALTH_CHECK_PORT`), receives one connection, replies
`ok`, and the check task ends (listener closed). No readiness signal from the
feed sources. Refines D5.

### D13. New telemetry source `NOTIFY_GW`
Register a new `monitoring` source `NOTIFY_GW` in
`telemetry/registry/sources.toml` (generated into telemetry Rust and TS).
Rejects reusing `DISCORD_ALERT`; that entry is retired with the TS service.
Not created yet (no code in this session).

## Implementation (2026-10-06, uncommitted)

The user asked to implement. Landed, uncommitted, all `just check` green in
`monitoring/`:

- `monitoring/` (stxr-prop/monitoring clone): `justfile` (matrix copied from
  the databento-mkt-data rust/crates layout), README, AGENTS.md, LICENSE,
  `rust/crates/{discord-webhook,feed-ingress,notify-gw}`.
- Root workspace: member `monitoring/rust/crates/*`; `.cargo/config.toml`
  patches for the alerts codec and incidents codec crates.
- telemetry: `monitoring/NOTIFY_GW` source `8KNEWFXX68PQ5` (D13).
- ipc `stxr-http-client`: `ReqwestHttpClientConfig::new`, per-request
  `timeout_ms` applied, timeout test (D8).
- Official SDK pinned to `google-cloud-pubsub =0.33.2`: every 1.x needs tokio
  >= 1.52, the workspace pins tokio =1.50.0 in 19 manifests. Lockfile pins
  google-cloud-rpc/type 1.5.0 and wkt 1.4.0 so they use the vendored
  serde_json. Moving to 1.x means bumping tokio everywhere (open).
- Flow control is per subscription: `delivery.requests_max` is split evenly
  between Pub/Sub subscriptions; config rejects `requests_max` below the
  subscription count.
- discord-webhook enforces Discord's 6000-character budget across the whole
  message; with that budget one embed always suffices, so no `(cont.)` embeds.
- Config feed source is internally tagged (`source: { type: pubsub, ... }`):
  yaml_serde reads externally tagged enums only as YAML tags.
- Not done: Dockerfile, infra (`infra/infra/services/alert.ts` still deploys
  the TS service), Pub/Sub path never run against GCP, ipc migration to the
  official SDK.

### D14. Local config lives in `<repo>/mnt/config/config.<service>.yaml` (2026-10-06)

The user prefers `./mnt/config/config.{service}.yaml` over a per-crate
`config/example.yaml` (copied from databento-mkt-data's justfile). notify-gw's
config moved to `monitoring/mnt/config/config.notify-gw.yaml`; justfile,
README and the config test follow it.

dev-env: session `sess-00pyn1m` with notebook `notify-gw` explains the change.

### D15. NATS config is a nested struct with a reconnect policy (2026-10-06)

From a dev-env annotation: `nats: { url, reconnect }` replaces `nats_url`;
url defaults to `nats://localhost:4222`; the user left the policy fields to
the agent. Chosen: attempts_max 60, delay_initial_ms 250 doubling to
delay_max_ms 8000, connect_timeout_ms 5000; all optional. Applied to
feed-ingress NATS sources (`NatsReconnectPolicy`); logger2's
NatsLogDispatcher only takes a URL, so the logger is not covered.

Open: the user asked whether infra was updated. Answer: no; asked whether to
do it and whether to run notify-gw beside alert-service or switch at once.

### D16. TigerBeetle-style memory: derived sizes, StaticAllocator (2026-10-06)

The user rejected arbitrary size constants ("random ass constants") and asked
to follow TigerBeetle (`src/static_allocator.zig`, `config.zig`,
`constants.zig`). Implemented:
- discord-webhook: scratch sizes derived from Discord limits with const
  asserts (tags: (FIELD_VALUE_LIMIT + 2) * 3 + ellipsis; properties:
  (MESSAGE_TEXT_BUDGET + 2) * 3 + ellipsis); `ExecuteWebhookWriter<A>` with
  `new_in(alloc)` and `write` into `allocator_api2::vec::Vec<u8, B>`.
- notify-gw: `StaticAllocator<A>` (Init -> Static -> Deinit, allocator-api2
  0.2.21, already in the lockfile via hashbrown); `static ENGINE_ALLOCATOR`
  in main passed to `run` and `init::load_params`; pool, body and writer
  scratch come from it; `initialize` switches to Static, `shutdown` to
  Deinit. Delivery tests run after `initialize`, so any allocation from it on
  the message path fails them.
- Payload limits moved from constants to `feeds[].payload_bytes_max`.
- Answered: RUSTC_BOOTSTRAP=<crate names> scopes nightly gates per crate
  (tested; cargo [env] works, build scripts refused). Not used.

Still open from dev-env annotations: run in lib.rs with injected state and a
cancellation token from main's signal handler; multihost generator; Discord
state living in NotifyGwData.

### D17. `run` in the library, driven by a `Program` (2026-10-06)

The user: move `run` into lib; a `Program` struct takes the allocator, the
runtime config, the engine meta, "maybe some other shit in the future"; `run`
takes the `Program`. Earlier annotation: signal listeners stay in `main` and
pass a cancellation token. Implemented `notify_gw::program::{Program, run,
Shutdown, RunError}`; `Shutdown` is std-only (Mutex + Condvar); main owns
config, logger, `static ENGINE_ALLOCATOR` and a signal thread that calls
`shutdown.request()`.

### D18. Multihost generator and nested Discord state (2026-10-06)

The user: use the multihost generator; Discord-specific state becomes its
own struct owned by the engine data (nesting). Implemented
`NotifyGwComponent` + `#[derive(Multihost)] NotifyGwHost`, generated into
`src/generated/engine/NotifyGwHost.rs` by build.rs; logic generic over
`M: NotifyGwEgress`; `NotifyGwData.discord: DiscordData { webhook,
paused_until, body_writer, body }`. The generator always derives serde and
Debug on the unions, so serde was added to feed-ingress messages and an
optional `serde` feature to ipc `stxr-http` / `stxr-http-client`. The
derived Debug exposes the webhook URL (accepted risk per D2).

### D19. One timer task with a heap (2026-10-06)

The user asked to stop `ingress-egress/src/timer/consumer.rs` from spawning
a Send + Sync tokio task per timer: one task total, a heap of timers.
Implemented in ingress-egress (uncommitted): `timer/heap.rs` (`TimerHeap`:
BinaryHeap of deadlines + map of live timers, lazy deletion by generation)
and a consumer whose `handle_msg` only forwards requests over an unbounded
channel to one local worker task (`spawn_local`, started on the first
request), which emits Created/Cancelled/Expired. Re-creating an id replaces
its deadline (the old timer no longer fires). `CTX` no longer needs `Sync`;
`dashmap` dependency dropped. Tests use tokio's paused clock instead of
sleeps.

### D20. FeedMsg carries a transport enum (2026-10-06)

The user: `FeedMsg` needs a transport enum with transport-specific info (NATS
headers, reply subject). Implemented in feed-ingress: `FeedMsg { route,
payload, transport: FeedTransport }`, `FeedTransport::PubSub(PubSubDelivery
{ ticket, message_id, publish_time_nanos, ordering_key, attributes })` /
`Nats(NatsDelivery { subject, reply, headers })`; `MessageHeaders` sorted
name/value pairs with `get`. The ack ticket moved into the Pub/Sub variant;
`FeedMsg::ack_ticket()` gives `NotDurable` for NATS. Possible follow-up: use
the `feed_subject` attribute in notify-gw instead of the `*` alerts subject.

### D21. End-to-end test with testcontainers (2026-10-06)

The user: use testcontainers for Docker. Implemented `notify-gw/tests/e2e`
(feature `e2e`, `just e2e`): Pub/Sub emulator container
(gcr.io/google.com/cloudsdktool/google-cloud-cli:emulators, wait on stderr
"Server started"), topics/subscriptions/publishing through the official SDK
with an emulator endpoint and anonymous credentials, a fake Discord HTTP
server with scripted replies, and the service in-process via `program::run`.
Covers alerts + incidents delivered, 429 retried, malformed never posted,
clean shutdown. feed-ingress gained `PubSubEndpoint::{Google, Emulator {
host }}`; notify-gw config `gcp.pubsub_emulator_host`.

Finding (open, not decided): shutdown races in-flight deliveries; the last
delivery is consistently nacked at shutdown and redelivered on the next start
(a deploy re-posts in-flight alerts). Proposed fix: a Draining FSM state
before stopping the feed sources. Ack assertions wait on that.

## Handoff: graceful drain on shutdown (2026-10-06, open)

The user hands this task to a different agent. The problem below is measured;
the design is the previous agent's proposal, NOT a user decision. Confirm the
design with the user before building it. Nothing in this repo is committed.

### Problem (measured)

On shutdown, a delivery that is still in flight is nacked and redelivered on
the next start, so Discord gets the alert twice. In production every deploy
can re-post the alerts in flight at that moment.

Evidence: `just e2e` (monitoring repo) ran with a temporary probe that pulled
both subscriptions from the emulator after `program::run` returned. Three
runs out of three, the subscription of the last delivered message still held
1 message (`alerts=0 incidents=1`). The probe (`Emulator::pending`, a REST
`POST /v1/{subscription}:pull` with `returnImmediately: true`) was removed
again because the result is not deterministic yet.

Why, in order:
1. `program::run` (`notify-gw/src/program.rs`, `shutdown.wait()` then
   `runtime::send_shutdown_msg(ingress_tx, ctl_tx)`) sends the control
   Shutdown to the ingress producers and the engine Shutdown at the same time.
2. The feed-ingress Pub/Sub source stops at once
   (`feed-ingress/src/pubsub.rs`: `ShutdownBehavior::NackImmediately`,
   `flush_on_stop` with `STOP_FLUSH_TIMEOUT` 10 s). It flushes acks already
   requested and nacks every message still in `PubSubTickets`.
3. The last Discord reply (`HttpClientResponse`) is still on its way back,
   so the engine never emitted the `AckRequest` for it before step 2.

### Proposed design (proposal, not decided)

A second FSM state, `Draining`, in notify-gw:

1. On `shutdown.request()`, `run` first sends the engine a drain message (a new
   ingress type, e.g. `DrainRequest`), not the shutdown messages.
2. The component transitions `Running -> Draining` through the logged
   transition helper (this is the first real transition; the structure doc
   `dev-docs/frameworks/engine-component-application-structure.md` describes
   the `FSMState` trait and `transition_to` helper to add). In `Draining`:
   - a new `FeedMsg` is nacked immediately (no new delivery starts);
   - in-flight deliveries continue: responses and retry timers are handled as
     in `Running`;
   - when `deliveries.outstanding() == 0` (checked on entering `Draining` and
     after every finished delivery) the component emits a `Drained` egress
     message once.
3. A small egress consumer in notify-gw turns `Drained` into a signal `run`
   waits on (same shape as `program::Shutdown`).
4. `run` waits for `Drained` or a drain timeout, whichever comes first, then
   sends the existing shutdown messages and joins as today. The producers'
   stop then flushes the acks already requested.
5. The drain timeout is configuration (the user rejects arbitrary constants):
   e.g. `delivery.drain_timeout_ms`. Cloud Run gives about 10 s between SIGTERM
   and SIGKILL, and the Pub/Sub flush on stop needs time too, so the default
   in `mnt/config/config.notify-gw.yaml` must leave room for both.
6. Open choices for the user: whether retry timers that end after the drain
   timeout are simply nacked (proposed: yes, Pub/Sub redelivers), and whether
   `Draining` also stops the rate-limit hold from delaying the drain.

Every `(message type, FSM state)` pair needs an explicit outcome (structure
doc rule): FeedMsg, HttpClientResponse, delivery timer, DrainRequest in both
`Running` and `Draining`.

### Acceptance

- `just e2e` asserts that after `program::run` returns, both subscriptions
  hold 0 messages (re-add `Emulator::pending`), for runs where every delivery
  finished within the drain timeout.
- A second e2e case: the fake Discord holds a reply past the drain timeout;
  after shutdown the message is pending again (redelivered, not lost).
- Engine-level tests in `notify-gw/tests/delivery.rs` (harness
  `tests/support/mod.rs`) for the dispatch matrix of `Draining`, including
  `Drained` emitted exactly once and a FeedMsg nacked while draining.
- `just check` and `just e2e` pass; clippy clean with `--features e2e`.

### Where things are (monitoring repo, `rust/crates/`)

- `notify-gw/src/program.rs` (`run`, `Shutdown` in `program/shutdown.rs`,
  manager wiring in `program/managers.rs`).
- `notify-gw/src/component.rs` (multihost component; subscriptions
  `on_feed_msg`, `on_http_response`, `on_delivery_timer`; host generated into
  `src/generated/engine/NotifyGwHost.rs` by `build.rs`).
- `notify-gw/src/state.rs`, `state/running.rs` (FSM), `logic/delivery.rs`
  (`start`, `settle`, `finish`), `logic/delivery_pool.rs` (`outstanding()`).
- `notify-gw/src/messages.rs` (`NotifyGwEgress` bound the logic is generic
  over; a new egress type means adding it there and to the component
  `Output`).
- `notify-gw/tests/e2e/` (`main.rs` scenario, `emulator.rs`,
  `fake_discord.rs`).

### Constraints that apply (from this session)

- No allocation on the message path after `initialize`: the component's
  `StaticAllocator` asserts on it in tests (D16).
- No `dyn`; generics. Tests: table tests, property tests where it fits, no
  sleeps for synchronisation (the e2e test waits on posts, timeouts only as
  failure guards).
- Every number is derived or configured, never a bare constant (D16).
- Usage rustdoc on the crates is kept current; doctests run in `just check`.
