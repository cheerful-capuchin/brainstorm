---
create_time: 2026-10-16T11:06:40Z
title: "Dynamic NATS ingress: connect/subscribe commands from components"
summary: "Brainstorm, no decisions yet. Goal: components open NATS connections and (un)subscribe at runtime (e.g. a new mkt arrives, subscribe to its market status feed). Proposal P1 (recommended): commands leave through egress as NatsSubscriberCommand (Connect/Subscribe/Unsubscribe), an egress consumer forwards them over an mpsc to the subscriber, events come back through ingress as NatsSubscriberEvent keyed by component-chosen ConnectionId + route; replay-safe for free, same shape as timers and publishes. Static config = initial commands. Control channel and a new context channel rejected. Open Q1-Q8."
related_sessions:
  - SESS-00QRJ0S
  - SESS-00QKRBE
agents:
  - claude-code:a58380e6-b8d0-4bcf-b22f-b0f2b24010c2
---

# SESS-00QRK20: Dynamic NATS ingress: connect/subscribe commands from components

## Trigger (2026-10-16)

Continues SESS-00QRJ0S. D4 there gave the NATS ingress producer a static list of
connections, each with its subscriptions. The user now wants the list to change while the
process runs: a component receives a new mkt over NATS and must subscribe to that mkt's
market status feed, which has no path today. Two parts: (1) a dynamic ingress producer,
(2) a way for components to send it commands, and to say which producer a command is for.

User's starting sketch (verbatim shape, to be reworked):

```rust
pub struct ConnectionId(u16);
pub struct NatsIngressProducerConfig { pub connection_pool_size: u16 }
pub struct ConnectRequest { correlation_id: u64, url: Arc<str>, reconnect_attempts: u16, name: Arc<str> }
pub struct ConnectResponse { correlation_id: u64, status: i32 /* >0 id, <0 errno */ }
pub struct SubscribeRequest { correlation_id: u64, connection_id: u16, topic: Arc<str> }
pub struct SubscribeResponse { correlation_id: u64, connection_id: u16, status }
```

## What the code gives us today (read 2026-10-16, uncommitted D1-D3 state)

- `ingress-egress/src/ingress/producer.rs`: `IngressProducer::start(sender, ctl_rcvr, tp)` runs
  as a local task on the ingress manager thread. Its only inbound channel is the control
  broadcast from `main`: `ControlMsgData` is `Copy`, bounded (16), carries only `Shutdown`.
  Nothing reaches a producer from the engine thread.
- `ingress-egress/src/egress/consumers.rs`: `EgressConsumer::handle_msg(msg, ingrs_sendr, tp)`
  runs on the egress manager thread and holds the ingress sender. Two consumers already use
  this as a request/response loop with the component:
  - `ingress-egress/src/timer/consumer.rs`: `TimerRequestWithCtx<CTX>` (egress) is forwarded
    over an mpsc to a worker task spawned on the egress thread's `LocalSet`; the worker reports
    `TimerEventWithCtx<CTX>` through ingress, in the order it applied requests.
  - `ipc/src/nats/publisher_with_ctx.rs`: `PublishRequestWithCtx<C>` (egress) answers with
    `PublisherResponseWithCtx<C>` (ingress), `C: Copy` chosen by the component (target-exec uses
    `PubContext { corr_id }`).
- Host enums are generated (`strats_v2/src/generated/engine/TargetExecutorHost.rs`): one
  variant per message type with `From<T>`; consumers find their message by
  `for<'a> &'a D: TryInto<&'a T>` (`MaybePublishRequestWithCtx`, `MaybeTimerRequestWithCtx`).
  So a new request type routes itself to its consumer by type; no producer registry exists.
- `engine/src/replay.rs`: replay feeds recorded ingress to the engine and compares the
  engine's egress with the recorded egress. Managers are not involved. Any request the
  component sends as egress is compared, and any response that came back as ingress is
  replayed. Requests via egress + responses via ingress are replay-safe with no extra work.
- `ipc/src/nats/subscriber.rs`: one connection, `topics: Vec<T>`, subscribes all at connect,
  merges into a `SelectAll`; routed mode tags each message with its topic's index
  (`RoutedNatsMsg { route: u32, payload }`), strategies index feeds by it. Statuses
  `NatsStatusMsg::{Ready, Disconnected, Dead}` carry no connection id yet (D4 adds it).
  `SelectAll::push` works at runtime; `async_nats::Subscriber::unsubscribe()` exists.
- Topics of feeds: `feeds.<kind>.<feed_id>.<revision>.<encoding>`; today's subscriptions use
  the kind wildcard `feeds.<kind>.*.<rev>.<enc>` (`kind_subscription_filter`).
- `Dead` handling: event-gw alerts, gw-mon logs, target-exec logs per state (D5: component
  decides).

## Proposals (not decided)

### P1 (recommended): commands through egress, events through ingress

```rust
// ipc, replaces NatsStatusMsg
pub struct ConnectionId(pub u16);   // chosen by the component
pub struct Route(pub u32);          // chosen by the component; the subscription handle and
                                    // the tag on every delivered message

pub enum NatsSubscriberCommand {
    Connect { connection_id, url: Arc<str>, name: ConnectionName, max_reconnect_attempts: u16 },
    Disconnect { connection_id },
    Subscribe { connection_id, route, topic: Arc<str> },
    Unsubscribe { connection_id, route },
}

pub enum NatsSubscriberEvent {
    Connected { connection_id },
    ConnectFailed { connection_id, error: ConnectError },      // AlreadyConnected | Limit | InvalidUrl | Refused
    Disconnected { connection_id },
    Dead { connection_id },
    Subscribed { connection_id, route },
    SubscribeFailed { connection_id, route, error: SubscribeError }, // UnknownConnection | DuplicateRoute | NotConnected | Limit | Nats
    Unsubscribed { connection_id, route },
}
```

- The component calls `context.send_msg(NatsSubscriberCommand::Subscribe { .. })`. A small
  egress consumer `NatsSubscriberCommandConsumer` forwards the command over an mpsc to the
  subscriber. The subscriber's select loop gets a third arm for commands.
- Identity: the message type routes the command to the one NATS subscriber of the process;
  `connection_id` names the connection inside it. No `producer_id` unless a process ever
  runs two NATS subscribers (none does; D4 chose one producer with many connections).
- Component-chosen ids instead of producer-allocated ids + correlation ids: the component
  can key its state before the answer, the recorded egress carries the same ids on replay,
  and `Connected { connection_id }` is its own correlation. The sign-coded `status: i32` is
  replaced by closed enums (idiomatic-code / no-undefined-behavior standards).
- Static config becomes the initial command list: `NatsSubscriberConfig { initial:
  Vec<NatsSubscriberCommand>, max_connections, max_subscriptions }`, applied before anything
  else, so one code path serves startup and runtime. Bounded tables (NASA rule 2/3).
- Invariant to keep: `Subscribed { route }` is sent before the subscription is pushed into
  the merged stream, so it precedes the first message on that route in the ingress channel.
- Reconnect: the subscriber keeps the (connection, route, topic) table and re-subscribes
  after a reconnect; async-nats also re-issues SUBs of live subscribers on its own reconnect,
  to be verified (Q7).

Two placements of the subscriber under P1:

- P1a: subscriber stays an ingress producer; the consumer holds the mpsc sender. Needs a
  pairing step at build time (`NatsSubscriberConfig::split() -> (producer_cfg, consumer_cfg)`)
  because the two halves are added to two different managers.
- P1b: the subscriber moves into the egress consumer, like the timer worker: the consumer
  spawns the subscriber on the egress thread's `LocalSet`, the worker feeds the ingress
  sender. One config, no pairing, no ingress producer. Cost: the market data firehose shares
  the egress thread with publishes.

### Rejected

- Control channel: wrong direction (main -> managers), broadcast to every producer, `Copy`
  payloads only (no `Arc<str>` url), bounded 16 and read by async tasks (a send from the
  engine thread can block), and the sender would have to be smuggled into component params
  like `ShutdownHandler`.
- A new `context.command(..)` channel on `EngineStateContext` (sibling of the `report` idea in
  SESS-00QRJ0S): a third way out of the engine, needs engine changes, and replay safety has to
  be built (gate on `IngressMode`) instead of coming free with egress. `report` stays for
  supervisor-level things (stop, health), not for I/O commands.

## Open questions

- Q1: P1a (ingress producer + paired consumer) or P1b (subscriber lives in the egress
  consumer)?
- Q2: Component-chosen `ConnectionId`/`Route` (recommended) or producer-allocated with
  correlation ids?
- Q3: Add a `CTX: Copy` generic as the publisher and timer do, so the component gets its own
  context (e.g. `InstrumentId`) back on `Subscribed`? Or is `(connection_id, route)` enough?
- Q4: Keep raw mode (`RawNatsMsg` with subject, used by event-gw/target-exec/gw-mon) next to
  routed mode, or make every subscription routed and let raw users keep the subject on the
  message?
- Q5: Limits: `max_connections`, `max_subscriptions` per connection; command channel bounded
  with `try_send` (fail with `QueueFull`) or unbounded like the timer worker?
- Q6: With dynamic connections there is no single `Ready`; does anything still need a
  producer-level ready signal (health check gating)?
- Q7: Verify async-nats re-subscribes live subscribers after its own reconnect, and whether the
  producer's manual reconnect loop still needs to re-subscribe.
- Q8: The market status subscription today is the kind wildcard; does the new mkt case need a
  per-feed subject, or is the wildcard already delivering it and the real need is a new kind
  or connection at runtime?
