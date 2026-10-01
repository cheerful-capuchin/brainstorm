- domain events - what drives the state (raw facts)
- audit events - what, who, why, when
- activity event - normalized projection that is user-friendly, not the raw facts

therefore, my database schema should change a bit to store the audit events and activity events
maybe anything that impls the ActivityEvent trait, will be stored instead of the event_logs table
and then we'll have the audit events?

```rust
pub trait ActivityEvent:
  HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
{
    // Span identifier for the unit of work that produced this event.
    fn span_id(&self) -> Option<telemetry::SpanId>;

    fn event_time(&self) -> NanoTimestamp;
    fn send_time(&self) -> NanoTimestamp;
    fn event(&self) -> &str;
    fn severity(&self) -> telemetry::Severity;
    fn labels(&self) -> impl ExactSizeIterator<Item = (&str, &str)>;

    fn subject(&self) -> impl telemetry::subject::traits::Subject;
    fn source(&self) -> impl telemetry::source::traits::Source;

    fn data(&self) -> impl FeedData;
}
```

## Context

For long time I've not liked the current implementation of the repositories and domain events in the application server.
For instance, we have the Service that includes all the domain logic: structure-web/packages/api/src/trading-accounts/trading-accounts-service.ts
Then, there is a repository structure-web/packages/api/src/trading-accounts/trading-accounts-repository.ts.

There is no sync between the data I store and whatever I publish to the network as the domain event.
Moreover, the moment I want to add the audit events, this all becomes a mess.
Additionally, I don't know how to handle postgres properly not to deadlock myself all the time.
For instance, when I do an upsert, this means that I'm updating the whole entity stored in the database.
If I have two concurrent updates to the same row, what happens?


