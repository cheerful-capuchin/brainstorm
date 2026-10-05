---
create_time: 2026-10-06T15:01:08Z
summary: "Rust engine service in stxr-prop/monitoring rust/crates replaces TS alert-service; Feed Ingress Producer (feed->source map, pubsub/nats modules); pure-data requests over generic Io; event-gw pool correlation ids; Running FSM; logger2 nats+stdout; no alloc after init; Q1-Q3 answered, P1-P9 proposals open"
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
