## Requirements
- no file edits
- max 500 words per reply (excluding code)
- more code, less english prose

## Context

Read the knowledge-base/docs/references/data-feed.md.
I already have the data feeds defined in data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs
and I've already sketched some things out for the domain events in brainstorm/prompts/domain-events/proposal.md.
Now I would like to iterate further on that idea.

the old approach
- proto definition: messaging/msg-schemas/proto/structure/event_log.proto
- example of events: strategy-core/ts/src/entities/strategy/strategy.ts:233
- example of emission: structure-web/packages/api/src/strategies/strategies-service.ts:223
```
argus.event(
    Strategy.Event.Created,
    ok({
        strategy_id: StrategyID.toString(strategy.id),
    }),
    Subject.make(Strategy.Subject, { user_id: args.userId, strategy_id: strategy.id }),
);
```
- serialization: structure-web/packages/api/src/run.ts:1106

The nice thing about normalization is that I can just subscribe to the feed and be able to process the events in the same manner.
The problem with normalization is that you lose information or change the representation of that information.
I wonder how I could make the cake and eat it too, by using the semantic traits, like
data-feed-definitions/rust/crates/data-feed-definitions/src/demo/traits.rs:174
```rust
pub trait DomainEvent:
  HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
{
    fn event_time(&self) -> NanoTimestamp;
    fn event(&self) -> &str;

    fn subject(&self) -> impl telemetry::subject::traits::Subject;

    fn properties(&self) -> impl ExactSizeIterator<Item = (&str, &str)>;

    // Span identifier for the unit of work that produced this event.
    fn span_id(&self) -> Option<telemetry::SpanId>;
}
```
Where all the domain events (e.g. Trading Account, Strategy, User, etc) will implement this trait.
In turn, I would have a single codepath that will do the persistence for the event logs in a handler similar to event-gw/crates/event-gw/src/logic/runtime_events.rs.

However, I still don't like this normalization. Can you research how Google, Amazon, Datadog or Sentry store their events? Are they normalized?



>-----

## Requirements
- no file edits
- max 500 words per reply (excluding code)
- more code, less english prose

## Context

Read the knowledge-base/docs/references/data-feed.md.
I already have the data feeds defined in data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs.

However, I'm missing the proper definition for the domain events feed that is emitted by the application server.
Currently, it's still using the old approach:
- proto definition: messaging/msg-schemas/proto/structure/event_log.proto
- example of events: entity-core/packages/entity-core/src/entities/trading_account/trading_account.ts:521
- example of emission: structure-web/packages/api/src/trading-accounts/trading-accounts-service.ts:256
```
argus.event(
    TradingAccount.Event.Created,
    ok({
        sn: TradingAccount.eventSequenceNumber(account.updateTime),
        account: TradingAccount.AccountEventSnapshot_fromTradingAccount(account),
    }),
    createdSubject,
);
```
- serialization: structure-web/packages/api/src/run.ts:1106



I think we could define the feed in the data-feed-definitions. However, what do we do with the typescript side?
It doesn't have the event id, trace id, span id, subject is fucked up, serialization is weird, etc.
I definitely don't want to create a new codec, but for typescript.
We already leverage the application server core application-server/crates/application-server-core/src/application-server.ts in structure-web/packages/api/src/app/init.ts.
Maybe we could do all the necessary encoding there and just give the opaque bytes back to the publisher?

## Questions
### 1. What would be the proper way to keep the semantics I like of argus.event, but serialize it as a proper feed?

### 2. How would the pubsub topic map to the data feed?
Details: the PubSub topics have to be created before publishing anything, afaik. In nats, you can just publish to any subject and it's fine (see feed_topic in rust/crates/data-feed-definitions/src/demo.rs)
In Pub/Sub, we create the topics in IaC infra/infra/event-bus.ts. Creating one for every new data feed ref is not practical.
I assume I'd have to use some message attributes to do the routing.

---

```
pub(crate) fn subject_digest(subject_seed: &str) -> [u8; 16] {
    let digest = demo_digest(DEMO_FEED_SUBJECT_ALGORITHM, subject_seed);
    digest[..16]
        .try_into()
        .expect("the first half of a 32-byte digest is 16 bytes")
}
```

can I use the real subjects from the data feed core?

>----
3

data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs
What is preventing us from using the subject from the real data feed definition: data-feed-core/rust/crates/data-feed-core/src/subject.rs
I don't want to have some hacky "demo" subject
