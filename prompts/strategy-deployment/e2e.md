## Requirements
- plain technical English with no jargon
- max 300 words per reply (excluding code)
- do NOT write any implementation code yet

## Context
I want to test the strategy deployment end-to-end. I, on purpose, made a strategy that flips its position frequently, see
- structure-strat-template-core/strats/flip-positions/README.md
- structure-strat-template-core/run.sh

This means that I should be able to see the target positions and fills in the clickhouse database that the event gw manages.

That involves:
- [databento mkt data server](databento-mkt-data/rust/crates/databento-mkt-data-server)
- [strategy](structure-strat-template-core/run.sh)
- [target-executor](strats_v2/src/bin/target_executor_bin.rs)
- [sim gw](./sim-gw)
- [event-gw](event-gw/crates/event-gw)
- [application server](structure-web/packages/api)
- [infra](infra-local/compose.yaml)

Feeds:
- Simulation Venue: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs; ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0
- Trading Account Updates: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/trading_account_feed.rs; ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-0f65b87ad6d1adffed3112c388ea26d7
- Strategy Deployment Target Executor Positions: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs; ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5


For now, I'll just requery my local clickhouse database to see the data being updated there.

I want to approach it with the vertical slices:
1. see the target positions being emitted by the strategy and stored in the clickhouse database
2. make sure that the target executor receives those target positions and gets the fills from the sim gw
3. make sure that the fills are stored in the clickhouse database

## Milestone 1: target positions are emitted and stored
Let's figure out the remaining work to emit the target positions and store them in the clickhouse database.
I already have the datafeed defined in the data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs.
There is already a codec
```
strategy-deployment-target-position-feed-codec = { package = "data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5", path = "./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5" }
```

The event-gw doesn't hanve anything feed-related integrated.
I think we should handle it similarly to strategy-template, where we have the generic [StratComponentHost::on_feed_msg](structure-strat-template-core/src/component.rs:422)
that knows how to interpret each feed and how to dispatch to the necessary handler.

Then, the "on_nats_msg" will interpret the data feed ref based on the NATS subject and pass it to the on_feed_msg function.
```
EventGwHost::on_nats_msg
 -> EventGwHost::on_feed_msg
```

We should follow the ideas defined by `dev-docs/frameworks/engine-component-application-structure.md`
We should have an EventGwHandler defined in the event-gw/crates/event-gw/src/handler.rs
Then the state and the logic.
Based on the knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md
We know that we need to have some kind of accounting module that does the logic.
However, for the first milestone, we should just buffer and then flush the target positions to the database.
Unless there is some kind of continuous connection available using the clickhouse rust driver.

Keep in mind, we also need to have the proper ingestion orderand logic. I think we can reuse the sim gw idea sim-gw/src/orderand.rs

```
EventGwHost::on_nats_msg
 -> EventGwHost::on_feed_msg
  -> EventGwHandler::on_target_position
```

## Constraints

### Event cardinality
There are going to be a lot of different events stored in the clickhouse database. I don't think we should have the egress contracts to the clickhouse writer tied to a specific kind of event.
Ideally, the clickhouse writer should be very simple, received a batch, write it to the database.

### Backup
Currently, we use the json files as the backup in case the write fails. If the database fails, for some reason, we're screwed.
For the demo, durability is out of the window for now. We're not going to handle the durability. If after 3 retries we still fail,
just drop the packets, there is nothing we can do.
The key is that the reply of the clickhouse write must go back to the engine. There, we'll do the retry and if it still fails, we just give up.
In the future, we can improve the logic there, but not now

### do NOT move the sim gw orderand into a shared module
You should just copy the implementation, maybe modify it slightly. There is no sharing between the two.

### Rows buffer
BytesMut does not keep a pool of freed blocks. It has one allocation at a time. What it does is check ownership before growing:
- If the allocation is shared, meaning some frozen Bytes still points into it, it cannot touch that memory. It allocates a new block and moves only the unflushed tail bytes into it. The old block is freed by the allocator when the last Bytes handle drops.
- If the allocation is no longer shared, meaning every frozen piece has been dropped, BytesMut is the sole owner again. Then reserve can slide the tail back to the start of the same block and keep using it, with no new allocation.
So it is "smart" in the sense that it reclaims its own block once it is alone, not in the sense of recycling arbitrary freed memory.
By using .freeze() and .split() we can send the serialized rows to the clickhouse writer and reuse memory.

The buffer should be bound to 10 MBs. If there is no longer space there, we just drop the new packets. This is DEMO only behaviour, we will fix it properly in the future.

### Egress contract
Probably something like this:

ClickHouseInsertRequest
correlation_id   component-chosen, echoed back
table            static table name from the generated schema
columns          static column list from the generated row type
format           RowBinary (closed set, one variant for now)
row_count        for logging and metrics only
payload          Bytes, frozen from the component's BytesMut

ClickHouseInsertResponse
correlation_id
outcome          Persisted | Failed { } -> impl Failed { fn retryable(&self) -> bool }

###

## Q&A

### 1. Does clickhouse have a stream/peristent connection through which we can append the records?
Details: we can reduce the need in buffering for certain events
A: The client library has the [INSERTER](https://github.com/ClickHouse/clickhouse-rs/blob/main/src/insert.rs#L42) API.
However, it's also doing the I/O straight away, which is not acceptable for us to keep in the component.
I much prefer storing the buffer of the serialized events in the component state and then once we reached the threshold or time trigger,
send the serialized bytes to the clickhouse egress writer.

```
// The desired max frame size.
const BUFFER_SIZE: usize = 256 * 1024;
// Threshold to send a chunk. Should be slightly less than `BUFFER_SIZE`
// to avoid extra reallocations in case of a big last row.
const MIN_CHUNK_SIZE: usize = const {
    // to use the whole buffer's capacity
    assert!(BUFFER_SIZE.is_power_of_two());
    BUFFER_SIZE - 2048
};
```
https://github.com/ClickHouse/clickhouse-rs/blob/fcb8b02537072d75d157361c59269b5d2e4102ce/src/insert.rs#L211
```
 let result = match &self.row_metadata {
            Some(metadata) => serialize_with_validation(&mut *buffer, row, metadata),
            None => serialize_row_binary(&mut *buffer, row),
        };
```
[serialize_with_validation](https://github.com/ClickHouse/clickhouse-rs/blob/main/src/rowbinary/ser.rs#L31)

## Review

### 1. The EventGwHost should have almost no logic in it except dispatching messages
send_insert_request, on_clickhouse_insert_response, etc - all of that should be out of the host
Even if the clickhouse insert reponse is not the feed, the Event Gw Handler should still have the necessary handler and do the logic there or
in the state or in the logic module. Definitely not in the host


### 2. RowBuffers::new the capacity is not applied to BytesMut -> why?


### 3. I'd move the RowBuffer from data.rs to logic/row_buffer.rs

### 4. [next_correlation_id](event-gw/crates/event-gw/src/logic/insert_flush.rs:40) can be moved into src/correlation_id.rs
it's quote a reusable function. Maybe even create the correlation id generator.
fn send<TP: TimeProvider> should also take the: EM: EgressTrait.

### 5. Do not hardcode the egress message
```
fn send<TP: TimeProvider>(
    data: &mut EventGwData,
    request: ClickHouseInsertRequest,
    ctx: &EngineStateContext<'_, TP, EventGwEgressMsg>,
) { ... }
```
```
fn send<TP, EM>(
    data: &mut EventGwData,
    request: ClickHouseInsertRequest,
    ctx: &EngineStateContext<'_, TP, EM>,
) -> Result<FlushSent, FlushError>
where
    TP: TimeProvider,
    EM: From<ClickHouseInsertRequest>
```

### 6. in_flight is weird to see it being a hashmap
First, I think we need to keep the clickhouse persistence data as a separate abstraction.
Then, instead of using in_flight.insert() and then not forgetting to do in_flight.delete(), I would first create a request pool
something like ~/work/gh/tigerbeetle/src/message_pool.zig
Where we have the bounded concurrency and the max number of the messages depends on the throughput.
For us, it's the time it takes to flush the buffer (say 300 ms), the time threshold to flush the buffer,
max message buffer sizes per table buffer.

Then the slot/idx of that inflight request in the pool is modulo of the correlation id or some other way to do that.

It's just I don't like having all the functions randomly having access to all the properties of the EventGwData.
This makes the binding between the functions too tight

### 7. I would like to see an explicit drop
```
let attempts = in_flight.attempts;
data.in_flight.remove(&response.correlation_id);
Ok(InsertResponseOutcome::Dropped {
    row_count,
    attempts,
})
```




>>>----

## Requirements
- plain technical English with no jargon
- max 300 words per reply (excluding code)
- do NOT write any implementation code yet

## Context
I want to test the strategy deployment end-to-end. I, on purpose, made a strategy that flips its position frequently, see
- structure-strat-template-core/strats/flip-positions/README.md
- structure-strat-template-core/run.sh

This means that I should be able to see the target positions and fills in the clickhouse database that the event gw manages.

That involves:
- [databento mkt data server](databento-mkt-data/rust/crates/databento-mkt-data-server)
- [strategy](structure-strat-template-core/run.sh)
- [target-executor](strats_v2/src/bin/target_executor_bin.rs)
- [sim gw](./sim-gw)
- [event-gw](event-gw/crates/event-gw)
- [application server](structure-web/packages/api)
- [infra](infra-local/compose.yaml)

Feeds:
- Simulation Venue: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs; ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0
- Trading Account Updates: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/trading_account_feed.rs; ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-0f65b87ad6d1adffed3112c388ea26d7
- Strategy Deployment Target Executor Positions: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs; ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5


For now, I'll just requery my local clickhouse database to see the data being updated there.

I want to approach it with the vertical slices:
1. see the target positions being emitted by the strategy and stored in the clickhouse database
2. make sure that the target executor receives those target positions and gets the fills from the sim gw
3. make sure that the fills are stored in the clickhouse database

## Milestone 1: target positions are emitted and stored
Let's figure out the remaining work to emit the target positions and store them in the clickhouse database.
I already have the datafeed defined in the data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs.
There is already a codec
```
strategy-deployment-target-position-feed-codec = { package = "data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5", path = "./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5" }
```

The event-gw doesn't hanve anything feed-related integrated.
I think we should handle it similarly to strategy-template, where we have the generic [StratComponentHost::on_feed_msg](structure-strat-template-core/src/component.rs:422)
that knows how to interpret each feed and how to dispatch to the necessary handler.

Then, the "on_nats_msg" will interpret the data feed ref based on the NATS subject and pass it to the on_feed_msg function.
```
EventGwHost::on_nats_msg
 -> EventGwHost::on_feed_msg
```

We should follow the ideas defined by `dev-docs/frameworks/engine-component-application-structure.md`
We should have an EventGwHandler defined in the event-gw/crates/event-gw/src/handler.rs
Then the state and the logic.
Based on the knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md
We know that we need to have some kind of accounting module that does the logic.
However, for the first milestone, we should just buffer and then flush the target positions to the database.
Unless there is some kind of continuous connection available using the clickhouse rust driver.

Keep in mind, we also need to have the proper ingestion orderand logic. I think we can reuse the sim gw idea sim-gw/src/orderand.rs

```
EventGwHost::on_nats_msg
 -> EventGwHost::on_feed_msg
  -> EventGwHandler::on_target_position
```

## Constraints

### Event cardinality
There are going to be a lot of different events stored in the clickhouse database. I don't think we should have the egress contracts to the clickhouse writer tied to a specific kind of event.
Ideally, the clickhouse writer should be very simple, received a batch, write it to the database.

### Backup
Currently, we use the json files as the backup in case the write fails. If the database fails, for some reason, we're screwed.
For the demo, durability is out of the window for now. We're not going to handle the durability. If after 3 retries we still fail,
just drop the packets, there is nothing we can do.
The key is that the reply of the clickhouse write must go back to the engine. There, we'll do the retry and if it still fails, we just give up.
In the future, we can improve the logic there, but not now

### do NOT move the sim gw orderand into a shared module
You should just copy the implementation, maybe modify it slightly. There is no sharing between the two.

### Rows buffer
BytesMut does not keep a pool of freed blocks. It has one allocation at a time. What it does is check ownership before growing:
- If the allocation is shared, meaning some frozen Bytes still points into it, it cannot touch that memory. It allocates a new block and moves only the unflushed tail bytes into it. The old block is freed by the allocator when the last Bytes handle drops.
- If the allocation is no longer shared, meaning every frozen piece has been dropped, BytesMut is the sole owner again. Then reserve can slide the tail back to the start of the same block and keep using it, with no new allocation.
  So it is "smart" in the sense that it reclaims its own block once it is alone, not in the sense of recycling arbitrary freed memory.
  By using .freeze() and .split() we can send the serialized rows to the clickhouse writer and reuse memory.

The buffer should be bound to 10 MBs. If there is no longer space there, we just drop the new packets. This is DEMO only behaviour, we will fix it properly in the future.

### Egress contract
Probably something like this:

ClickHouseInsertRequest
correlation_id   component-chosen, echoed back
table            static table name from the generated schema
columns          static column list from the generated row type
format           RowBinary (closed set, one variant for now)
row_count        for logging and metrics only
payload          Bytes, frozen from the component's BytesMut

ClickHouseInsertResponse
correlation_id
outcome          Persisted | Failed { } -> impl Failed { fn retryable(&self) -> bool }


## Milestone 2: target positions are handled by the target executor

The target executor must handle the target position event, figure out the orders that are needed to be sent and send them.
Then, the sim gw must fill the order, send the updates.
Event gw must store all the events from the sim_venue_feed.rs
Target executor must handle all the events from the sim_venue_feed.rs to keep the accurate state of the venue.
AFAIK, the strategy doesn't need anything from either sim_venue_feed or trading_account_feed.rs
Additionally, Event GW must publish the trading_account_feed.rs, which it doesn't do right now: event-gw/crates/event-gw/src/logic/trading_accounts.rs

## Questions

### 1. What is missing in the target executor to satisfy milestone 2?
The core path already works: it decodes the target position feed, computes the delta versus the current position, and sends limit orders to stxr.gw.sim.request. Order acks and fills come back on the legacy response subject and drive its state. Three things block milestone 2:

- No price, so no orders. Ready state only gets prices from the Databento feed, but the adapter is built with an empty symbol map at strats_v2/src/target_executor/feed/ingress.rs:94. Every target ends in the "awaiting price" retry loop. The strategy already builds this map from market info, so copy that.
- Empty account repo. A target is rejected unless the strategy has an attached paper account. The repo is filled either by an HTTP call to the backend or by the trading account feed, which nobody publishes yet.
- Feed handlers are no-ops for fill, fee, deposit, and withdrawal. Only position updates are folded. Acceptable for the demo since the legacy path carries fills, but worth knowing.

### 2. What is missing from the sim gw to satisfy milestone 2?
A: nothing

### 3. What is missing from the event gw to satisfy milestone 2?
