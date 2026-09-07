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
