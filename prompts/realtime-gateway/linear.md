I've had an idea, but i don't know how to properly name it and create the project with it.
We have the concept of the data feeds in entity-core/docs/data-feed/*.md

Ideally, we want to have a single gateway that allows the user to subscribe to any feeds or even send the request/reply messages to our structure api
https://api.structure.fi/openapi.json; structure-web/packages/api/src/app/routes.ts (2K LOC)

The feeds could be the prices for the particular instruments, the information about the strategy deployment: logs, fills, target positions, actual positions, etc.
Ideally, that gateway allows us establishing a long-lived connection. WebSocket could be one of the transports. However, we may expand to some custom TCP protocol, similar to databento https://databento.com/docs/api-reference-live.

However, when it comes to naming, I'm clueless. What name would characterize this "endpoint"/entrypoint/gateway properly?
It's not just "subscriptions", you can also have the request/reply semantics there.

## Prerequisites
The context and the description must be in a very simple language.
The audience is the people with the tech background, they generally understand
what the product is, but they are not aware about much details.
Also, try keeping it succinct so it doesn't take ages to read

## Linear hierarchy
1. **Initiative** — Structure v0 (https://linear.app/stxr/initiative/structure-v0-324e9b736950/overview)
2. **Project** — a major feature
3. **Milestone** — the delivery gate an issue advances
4. **Component label** — the system component affected by the issue
5. **Issue** — a concrete unit of work

## Task
We need to create a Linear project "Structure Realtime Gateway".
Assign it to the marmoset. Initiative - Structure v0

### Milestones

Every project uses the same milestones:

- **Designed** — The intended behavior, boundaries, and contracts are captured
  in an accepted DEC or SPEC. Design questions that block implementation are
  resolved.
- **Ready for Integration** — The code is written, reviewed, and verified in
  isolation. Other components can begin integrating with it, but no end-to-end
  integration is claimed yet.
- **Integrated** — The necessary system components use the feature through its
  agreed contracts. The relevant end-to-end paths work.
- **Deployed** — The integrated feature is running in Structure-managed
  infrastructure.
- **Done** — The feature is complete with no remaining work required for that scope.


!!!IMPORTANT!!! Copy the next sections verbatim


## Purpose:
Structure public API is currently only the request/reply operations over HTTP.
However, a lot of the functionality on the client application requires live updates like prices, logs, deployment fills, target positions, actual positions, etc.
Ideally, there should be a single entrypoint into the system that manages all of that. This reduces the overhead of making the HTTP requests all the time and gives us all the realtime capabilities we need.

## Outcome
Clients can establish one authenticated session with Structure and use it concurrently to:
* Subscribe to authorized data feeds.
* Receive typed, sequenced events.
* Send application requests and receive correlated responses.
* Manage subscriptions without reconnecting.


## Requirements
- The Realtime Gateway must be a separate stateless Engine Rust program.
- Currently, the only supported transport is websockets. However, it should be easy to extend that.
- The number of connections should be bounded to a configurable qty. If there are more clients trying to connect, the connection should be rejected, instead of growing the RAM indefinitely.
- After inactivity of X seconds, and failure of replying to the heartbeats, the connection should be dropped
- If the client's TCP buffer is full, they should be dropped
- The gateway doesn't parse the responses, it just provides the envelopes.
- The gateway should support multiple encoding formats: JSON, [FlatBuffers](https://flatbuffers.dev/). Therefore, when establishing the connection, the user should supply the encoding. Otherwise, we default to flatbuffers.
The reason to do that is to reduce the bandwidth and enable the zero-copy deserialization
- The gateway should support the compression in case the client asks for it. For now, the only compression algorithm is [LZ4](https://github.com/lz4/lz4) (frame format).
LZ4 is the better alternative to gzip, or zstd in terms of throughput and compression speed.

## Example flow
from the gateway's perspective
```rust
mod ingress {
    pub struct SubscribeRequest {
        pub correlation_id: u64,
        pub feed_ref: entity_core::entities::data_feed::DataFeedRef, // 65 bytes
    }
}

mod egress {
    // we don't want to use the 65-byte DataFeedRef identifier all the time
    pub struct StreamId(pub u32);

    pub enum SubscriptionResponse {
        Success(SubscriptionSuccess),
        Error(SubscriptionError),
    }

    pub struct SubscriptionSuccess {
        pub correlation_id: u64,
        pub stream_id: StreamId,
    }

    pub struct SubscriptionError {
        pub correlation_id: u64,
        pub reason: u16,
        pub message: Arc<str>,
    }

    pub enum CompressionAlgorithm {
        None,
        LZ4,
    }

    pub struct StreamMessage {
        pub stream_id: StreamId,
        pub bytes: bytes::Bytes,
        pub compression: CompressionAlgorithm,
        pub content_size: u32, // original content
    }
}
```
Flow
```
ingress: { action: subscribe, }
egress: { type: subscription_response }
egress: { type: message  }
```

## Success:
The project is successful when:
* A client can use one session for subscriptions and request/reply operations concurrently.
* Authentication and authorization are consistently enforced for operations and subscriptions.
* Prices, Strategy Deployment, Market Info feeds are available through the gateway
* Subscription lifecycle, correlation, errors, heartbeats, backpressure, and reconnection behavior are explicitly defined.
* Adding a new feed does not require designing another public transport integration.
* Existing Application Server business logic remains reusable rather than being duplicated inside the gateway.
* The protocol is not coupled to WebSocket-specific framing.

## Current state
Structure already has:
* An HTTP Application Server covering product and business operations.
* Internal real-time distribution over NATS and other infrastructure.
* JWK Authentication support `/.well-known/jwks.json` in [api/src/auth/jwt.ts](https://github.com/stxr-prop/structure-web/blob/80871d39dc8d46fbe9026b714fe51a7ac9815c5f/packages/api/src/auth/jwt.ts#L49)
* The multi-tenant support in [telemetry::Subject](https://github.com/stxr-prop/telemetry/blob/main/rust/src/subject.rs)

## Scope and non-goals
Initial scope includes:
* The realtime session and message protocol.
* Request, response, event, control, and error __envelopes__.
* Request correlation and subscription lifecycle.
* Authentication and authorization.
* Heartbeats, flow control, reconnection, and recovery semantics.
* A WebSocket transport adapter.
* A client SDK suitable for the web application and other consumers.

Non-goals include:
* Moving business logic out of the Application Server.
* Exposing NATS or other internal messaging infrastructure directly.
* Implementing a custom TCP transport in the first milestone.
* Reimplementing every existing HTTP operation immediately.

## Critical Questions
- What's the shape of the protocol - how do you correlate messages, how do you subscribe?
- How is the authentication handled - query parameters, first message, headers? What are the pros and cons?
- How is the application server called?
- How is the connection pool bounded?
- How do you know the relationship between the feed the user wants and where to get the data for it?
- How do you handle the authorization of the feed data - how do you prevent user A from seeing the data of user B?

## Topics to explore
- Authentication vs Authorization
- JWK and public/private keys. [Developer's Guide](https://workos.com/blog/developers-guide-jwks); [RFC7517](https://www.rfc-editor.org/info/rfc7517/);
- Web Sockets [stxr-websocket](https://github.com/stxr-prop/ipc/tree/main/crates/websocket); [tokio-tungstenite](https://github.com/snapview/tokio-tungstenite)
- [FlatBuffers](https://flatbuffers.dev/)

## Inspiration
- [Databento Live API](https://databento.com/docs/api-reference-live/basics/authentication?historical=rust&live=rust&reference=rust)

