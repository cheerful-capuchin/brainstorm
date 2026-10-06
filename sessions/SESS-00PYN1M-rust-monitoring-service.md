---
create_time: 2026-10-06T15:01:08Z
summary: "notify-gw (Rust engine app, stxr-prop/monitoring rust/crates: notify-gw, feed-ingress, discord-webhook) replaces TS alert-service; new feeds only; official google-cloud-pubsub; fix ipc http-client; copy event-gw pool; whole Discord URI; ack ticket on final outcome; one-shot startup port in main; new NOTIFY_GW telemetry source"
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
