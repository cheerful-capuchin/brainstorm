## Context

I want to get rid of the typescript alert service structure-web/packages/alert-service/src/main.ts and write a proper service in rust
to normalize all our APIs.

ensure a session document is created (decision log skill) and write the decisions there, don't write any rust code yet.
Answer the questions, let's design the app

https://github.com/stxr-prop/monitoring

create the "monitoring/rust/crates/".

ensure that the justfile has the table/matrix setup like in the entity-core
follow the config setup from dev-docs/frameworks
Use the engine architecture.

The ingress message is the "feed message" and since you know what you're subscribing to, you know the data feed.
So, don't create the "pubsub ingress producer" or "nats ingress producer". Instead, have the Feed Ingress Producer that takes in the mapping
between the feed and topic (where to get the data from). the pubsub is just a module. Ideally, you should reduce the logic for the I/O as much as possible.
I would much rather see you building the request as a pure data and then just send it over some client.
I attempted doing something like this in gcp/ts/gcp/src/cloudtask/mod.ts, but maybe there is a more ergonomic rust option.
Ideally, I/O should be taken as an interface, similar to zig.

Follow the tiger style as much as you can of not allocating after initialization.
The allocator API recently became stable (https://github.com/rust-lang/rust/pull/156882)
So, maybe you can use something like https://github.com/zakarumych/blink-alloc

I think the examples of the "on_feed_msg" are present in the event-gw and sim-gw.
You need the setup with state.rs, where the only state you have for now is Running.
It's a marker type -> this is also in the dev-docs/frameworks.
Then you have the logic, which is just building of the discord payload and emitting the egress message to publish it.

Use the event gw approach for the bounded pool of requests, where the correlation id is assigned by the pool and not just by you some random thing.
use the nats and stdout backend for the logger. don't spam logs. Only log very important information.

## Questions

### 1. Is there a better name than just alerts service?

### 2. gcp client
I think when I first wrote the event bus, there was no official gcs sdk for pub/sub maybe that changed?

### 3. How would you solve the "secrets" over the egress?
We have the ipc/crates/http-client. But in case you need to send the message to discord, you embed the secret into the http request.
Is there a way to mask it or pass a placeholder that will be filled in by the egress consumer?
Because the secret is in the uri


