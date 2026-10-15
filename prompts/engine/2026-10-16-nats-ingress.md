read the session SESS-00QRJ0S
I want you to create a new session where we redesign the nats ingress producer.

I want to be able to have dynamic subscriptions from within the component.

This means there should be a way to send a message to the ingress producer to subscribe to a new topic or open a new connection.

This involves 2 parts:
- dynamic ingress producer
- communication between the components and the ingress producers/ingress manager

We should be able to send commands to the ingress producers and then we need to somehow identify which ingress producer we're sending
the command to.
For instance, imagine I receive new a new mkt over nats and now I need to dynamically subscribe to its market status mkt data.
Currently, there is no way to do that.

Consequently, I would like to brainstorm how we can achieve that.

I assume the structure of the nats ingress producer is
```rust
pub struct ConnectionId(u16);

pub struct NatsIngressProducerConfig {
    pub connection_pool_size: u16,
}
```
then we have some sized pool of connections
the component can send
```
pub struct ConnectRequest {
    pub correlation_id: u64,
    pub url: Arc<str>,
    pub reconnect_attempts: u16,
    pub name: Arc<str>,
    // ...
}
```
and then on the ingress it gets the
```
pub struct ConnectResponse {
    pub correlation_id: u64,
    pub status: i32, // > 0 -> connection id; < 0 -> error number
}
```
or maybe an enum if we want more metadata about the error

Similar deal with subscriptions
```
pub SubscribeRequest {
    pub correlation_id: u64,
    pub connection_id: u16,
    pub topic: Arc<str>,
    // ...
}

pub SubscribeResponse {
    pub correlation_id: u64,
    pub connection_id: u16,
    pub status: ... // ok | not ok
}
```

This means that our ingress producer must be structured in a way that facilitates this dynamism AND
we need a communication channel between the ingress producers and components.
I'm not intimately familiar with ingress-egress/src/ingress/manager.rs or engine/src/component.rs.
So, I would like to brainstorm the solutions with you


