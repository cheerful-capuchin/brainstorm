# Proposal: Domain events as data feeds, encoded in the application server core

Status: demo scope. Companion to `domain-events-feed.md` (the question) and
[REF:data-feed] (the model).

## Problem

The application server emits domain events through `argus.event(def, payload, subject)`.
The sink wraps every event in the `EventLog` protobuf envelope
(`messaging/msg-schemas/proto/structure/event_log.proto`), flattens the payload into a
`map<string,string>`, and publishes it on the `event-log` Pub/Sub topic. event-gw then
parses those strings back (`entity-core-wire`), normalizes them into the trading account
feed (`TRADING_ACCOUNT_FEED`), and republishes on NATS.

What is wrong with that path:

- the event shape is defined twice: a zod `IPC.define` in TypeScript and a proto message
  in Rust, with a hand-written string snapshot (`AccountEventSnapshot`) between them;
- event id, trace id, and orderand are lost or re-derived at the consumer;
- normalization to `EventLog` is lossy and happens at the producer, so the consumer has
  to undo it;
- `EventLog` is a log envelope, not a feed; the data feed identity model
  (`FeedId`, `FeedRevisionId`, `DataFeedRef`) never enters the picture.

## Design

One definition, in Rust. The application server core (wasm) encodes. TypeScript keeps
the `argus.event` call shape but hands typed input to the wasm and gets opaque feed
bytes plus the feed identity back. No TypeScript codec.

Two feeds, two providers:

- **Trading account events feed** (`TRADING_ACCOUNT_EVENTS_FEED`, kind
  `fkind_835b2f2fdb2fd9dce336c325b71522fa`), provider: the account service (application
  server). One variant per domain event the service records, nothing merged or
  filtered. The lossless record.
- **Trading account feed** (`TRADING_ACCOUNT_FEED`, kind
  `fkind_0f65b87ad6d1adffed3112c388ea26d7`), provider: the event gateway. The mutations the
  trading infrastructure folds into its account projection: the minimum a consumer
  needs, derived from the events that change a tradeable account.

```
TS call site                         wasm (application-server-core)          Pub/Sub                  event-gw
argus.feedEvent(EventsFeed, msg)     encode_feed_event(kind_id, hdr, msg)    topic: feeds             attrs → DataFeedRef
  header from argus ctx + sink:        serde → prost TradingAccountDomainEvent  attributes:              1:1 republish to NATS
    event_id, trace_id,                validate via codec adapter                 feed_kind              feed_events row (lossless)
    event_time, send_time              prost encode → bytes                       feed_subject           event_logs row (projection)
  entry { feed parts, data }           subject = owner + account                  feed_revision          events → mutation → NATS
     → FeedSink                                                                   encoding               (TRADING_ACCOUNT_FEED)
                                                                                ordering_key: feed_subject
```

### Source of truth

The prost messages generated inside the codec crate
(`data-feed-codec-protobuf-0f65…/src/generated/messages.rs`) are the single definition
of the wire shape. `prost-build` attaches `serde` and `specta` derives to them, so the
same types are:

- the protobuf codec (unchanged);
- the JSON shape crossing the wasm boundary (`serde_wasm_bindgen`);
- the TypeScript type and zod schema (`specta` export, then `ts-to-zod`), following the
  pipeline already used by `event-gw/crates/db/justfile`.

`u64` fields cross as strings. Raw key bytes cross as `number[]`.

### Feed handle in TypeScript

The export step also emits the feed identity, so TypeScript never types a kind id by hand:

```ts
export const TradingAccountFeed = {
    kind_id: "fkind_0f65b87ad6d1adffed3112c388ea26d7",
    revision_id: "frev_a5a78a2227389de7c174db975554d082893eacf75a0da251a05717738f5797de",
    encoding: "protobuf",
} as const;

export const TradingAccountMutationFeed = Feed.define(TradingAccountFeed, tradingAccountMutationSchema);
```

`Feed.define` pairs the handle with its generated message type, the way `IPC.define`
pairs a kind with a zod schema.

### `argus.feedEvent`

```ts
argus.feedEvent(server, TradingAccountMutationFeed, {
    account_id: { id: TradingAccountID.toPrimitive(account.id).toString() },
    feed_orderand: { value: Timestamp.toNanos(account.updateTime).toString() },
    kind: { upsert: { account: TradingAccount.toFeedAccount(account) } },
});
```

It stamps `event_id`, `trace_id`, and `event_time` from the argus context, calls the
wasm, and emits an entry tagged `FEED_TAG` carrying `{ feed_topic, ordering_key, data }`.
`FeedSink` publishes those entries and knows nothing about feeds.

### Wasm entry point

```rust
pub fn encode_feed_event(&mut self, feed_kind_id: &str, header: Ts<FeedEventHeader>, msg: JsValue)
    -> Result<Ts<EncodedFeedMessage>, JsError>
```

The set of feeds is closed in Rust: the function matches on the kind id, an unknown id is
an error, a new feed is a new arm. The existing consumer adapter
(`TradingAccountMutationMsg::parse`) validates the message before it is encoded, so the
producer can never publish a payload the consumer would reject.

### Pub/Sub mapping

Topics are transport, not feeds. One static topic `feeds` in IaC. The message's
`DataFeedRef` travels as four attributes, one per part: `feed_kind` (`fkind_…`),
`feed_subject` (`fsubj_…`), `feed_revision` (`frev_…`) and `encoding`; the feed subject is
the ordering key. Subscriptions select feeds by attribute equality
(`attributes.feed_kind = "fkind_…" AND attributes.encoding = "protobuf"`), so revisions
and subjects never touch infra. Filters are immutable per subscription, so they select on
kind only and consumers reject unknown revisions.

The NATS subject scheme (`feeds.{fkind}.{fsubj}.{frev}.{encoding}`) is rendered by
`feed_topic()` alone, and only where a NATS subject is needed: event-gw rebuilds the
`DataFeedRef` from the attributes and renders the subject when it republishes.

event-gw hands the bytes to the same `FeedMsg` path the NATS feeds use: 1:1 republish to
NATS, a lossless `feed_events` row, the `event_logs` projection, and, for the events
feed, the derived mutation on `TRADING_ACCOUNT_FEED`.

### Persistence

`feed_events` is the lossless record. `event_logs` for domain events is a projection built
from the decoded message in event-gw, not an envelope built at the producer. It can be
rebuilt from `feed_events`.

## Demo trade-offs

- **Snapshots stay the account service's text.** `AccountEventSnapshot` on the events feed
  carries ids, `type`, `venue`, `confirmation_status`, `blockchain` as the strings the
  service renders (the same shape the `EventLog` path carried); the codec adapter parses
  the names, the event-gw transform parses the keys when it derives a mutation.
- **`SkipUnconfirmed` lives in event-gw's transform**, where it was before: the events feed
  carries every created/updated event, the mutation feed only confirmed accounts.
- **One `argus.event` remains**: the drift delegate transaction *failure* path, which has no
  variant on the events feed. It stays on the `EventLog` path.
- **Nullable header fields in TS** because prost makes every message field `Option`.
  `feedEvent` types them out with `Omit`.
- **The zod schema is generated but not used on the publish path.** Serde in the wasm is
  the validation. The schema exists for consumers that parse JSON.
- **The old event-log to trading-account republish in event-gw is removed.** The app
  server publishes the feed; event-gw bridges it.

## Implementation map

| Repo | Change |
|------|--------|
| data-feed-definitions | `demo/trading_account_events_feed.rs` (definition + traits); codec crate `data-feed-codec-protobuf-835b…` (proto, adapter, consumer); both codecs' `build.rs`: serde + specta derives, u64 as string; `export-ts` bin; `ts/` package `@structure/data-feed-definitions` (`Feed.define`, generated types, zod, feed ids); `just generate` |
| application-server | `feed.rs` (`FeedEventHeader`, `EncodedFeedMessage` as `DataFeedRef` parts, closed `FeedKind`), wasm entry, TS wrapper `encodeFeedEvent`; rebuild `build/release` |
| structure-web/api | `argus.feedEvent`, `FeedSink`, `Topic.Feeds`, wiring in `run.ts`, trading account call sites emit `TradingAccountDomainEventFeed`; entity-core `TradingAccount.toFeedEventSnapshot` |
| event-gw | Pub/Sub feed ingress by `DataFeedRef` attributes → `FeedMsg` path + NATS republish; events feed handler: `event_logs` projection + event → mutation transform → `TRADING_ACCOUNT_FEED` on NATS; event-log republish removed |
| infra | `feeds` topic, event-gw subscription with kind filter and ordering, IAM, `feeds_pubsub_topic` and `pubsub-feeds` config rendering |

## Verification

- codec crate: serde round trip of every `oneof` variant; every 64-bit field crosses as a
  string; specta export checked by the TS package typecheck.
- application-server-core: native test encodes a JSON mutation and decodes it with the
  codec consumer; contract violations, bad event ids and unknown kind ids rejected; bun
  test against the shipped wasm.
- event-gw: `resolve_feed_subject(feed_topic(ref)) == ref`; host test per mutation kind:
  one NATS republish with identical bytes, one `feed_events` row, one projected
  `event_logs` row, ack only after the batch write is persisted.
- api: typecheck against the generated types; `FeedSink` tests with a fake broker and a
  fake encoder.

## As implemented (2026-09-15)

Deviations from the sketch above, all deliberate:

- `FeedEventHeader` also carries `send_time_ns`. The application server core runs on a
  mock clock, so `FeedSink` stamps send time from its injected time provider.
- The sink, not the call site, calls the wasm: `argus.feedEvent(def, msg)` emits an entry
  with `{ feed_kind_id, feed_revision_id, msg }` and `FeedSink` encodes and publishes.
  Call sites need no handle on the application server.
- `FeedSink` publishes one message per request, sequentially, which satisfies Pub/Sub's
  one-ordering-key-per-request rule without grouping.
- Trace ids that are not telemetry ids (HTTP request ids) are hashed with BLAKE3 into a
  stable 128-bit id, so the feed still correlates with the host's logs.
- `rename_all = "snake_case"` is applied to the `oneof` enums only: specta and serde
  disagree on field names with digits (`w0` vs `w_0`). Empty messages export as
  `Record<string, never>`.
- (2026-09-16) `EncodedFeedMessage` returns the `DataFeedRef` parts instead of a rendered
  topic; the two feeds were split as described under Design; the wasm publishes the
  events feed only and `FeedKind` has that single variant.
- event-gw acks a data feed message when the projected `event_logs` batch is persisted;
  the `feed_events` row has no ack coupling (TECH-DEBT comment on
  `on_pubsub_data_feed_msg`). Unroutable or undecodable messages are acked and dropped.
- The `event_logs` projection uses a system subject with the account as child and the
  application server as source; the mutation carries no owner.
- Config: api reads `feeds_pubsub_topic`; event-gw reads `pubsub-feeds` entries with
  `kind: data_feed` and subscribes to every listed subscription. Infra renders both.
- `TradingAccount.Event` and `AccountEventSnapshot` remain defined in entity-core; only
  the emission sites moved. Removing them is a follow-up once no consumer references them.
