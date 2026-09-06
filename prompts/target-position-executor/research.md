https://cmegroupclientsite.atlassian.net/wiki/spaces/EPICSANDBOX/pages/715325746/iLink+Execution+Report+-+Trade+Outright
https://cmegroupclientsite.atlassian.net/wiki/spaces/EPICSANDBOX/pages/716275899/iLink+Execution+Report+-+New+Order

strats_v2/src/target_executor

give me a brief introduction to the codebase.

Then, explain the flow from the strategy target position using the codebase explorer skill


```
TargetExecutorComponent::handle_incoming_nats_msg <writes> [enter component state machine]  target_executor.rs:212
  -> TargetExecutorState::handle_incoming_nats_msg <fails> [dispatch to ReadyState]  engine_state.rs:66
    -> ReadyState::handle_incoming_nats_msg <writes><fails> [route raw NATS message]  ready_state.rs:1770
      -> ReadyStateNatsHandler::dispatch_raw_msg [select target request handler]  ready_state.rs:1888
        -> ReadyStateNatsHandler::handle_msg<TargetPositionRequest> <fails> [decode request]  ready_state.rs:2027
          -> TargetPositionRequestMsg::from_wire <fails> [validate and normalize positions]  wire_msg/target_position.rs:79
          -> ReadyState::handle_target_position_request <writes><fails> [process target batch]  ready_state.rs:1052
            -> ExecutorAccRepo::check_strategy_executable <reads><fails> [require executable account]  accounts.rs:143
            -> SingleStratTargetManagerWithCtx::set_last_request_id <writes> [record correlation ID]  target_position_manager.rs:128
            -> SingleStratTargetManagerWithCtx::update_target_position <writes><fails> [validate target]  target_position_manager.rs:157
            -> common::status::send_status <emits TargetPositionStatusUpdate> [report Failed]  common/status.rs:15
```

## TopicMsgHandler<DriftOrderUpdate>::handle_msg (ready_state.rs:1977)
I don't think we need this anymore

## TopicMsgHandler<OraclePrice>::handle_msg (ready_state.rs:1945)
I don't think this is needed anymore

## TopicMsgHandler<Book>::handle_msg (ready_state.rs:1920)
Do we need that for the sim venue?

## TopicMsgHandler<RegisterNewStrategy>::handle_msg (ready_state.rs:2036)
who does this?

## TopicMsgHandler<PositionServerAccountUpdate>::handle_msg (ready_state.rs:2053)
needs changes

## ReadyState::handle_target_position_request (ready_state.rs:1052)

---

## Context
Read brainstorm/reports/target-position-executor/sim-venue.md
I want to fix the target position contract.
- [TargetPositions](dsl-runtime/src/actions.rs:262)
- [build_action_proto_request](dsl-runtime/src/utils.rs:71) function

## Proposal
The target position should have at least
```rust
pub struct StrategyDeploymentOrderand(pub u64);

/// What the target set contains, and therefore what absence means.
/// TODO: TBD
pub enum TargetSetCoverage {
    /// Every subject the strategy constrains
    Full,
}


pub trait TargetPositions:
  HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
+ HasFeedOrderand<Orderand= StrategyDeploymentOrderand>
{
    /// Simulated timestamp when the event occurred.
    fn event_time(&self) -> NanoTimestamp;
    /// When the event was sent
    fn send_time(&self) -> NanoTimestamp;

    /// Subject
    fn strategy_id(&self) -> StrategyId;
    fn strategy_revision_id(&self) -> StrategyRevisionId;
    fn strategy_deployment_id(&self) -> StrategyDeploymentId;

    /// Target Positions
    fn coverage(&self) -> TargetSetCoverage;
    fn positions(&self) -> impl ExactSizeIterator<Item: TargetPosition>;
}

pub trait TargetPosition {
    fn account_id(&self) -> AccountId;
    /// The economic position requested by the strategy.
    fn subject(&self) -> TargetPositionSubject;
    /// Whether execution may select a market or must use a specified market.
    fn market(&self) -> TargetPositionMarket;
    /// Signed; direction is the sign.
    fn quantity(&self) -> numerics::Qty;
    /// The limit the strategy places on execution price.
    fn price(&self) -> TargetPositionPrice;
}

pub enum TargetPositionContract {
    Derivative { contract_id: ContractId },
}

pub enum TargetPositionSubject {
    Asset { asset_id: AssetId },
    Contract(TargetPositionContract),
}

/// How the target position constrains the market used for execution.
pub enum TargetPositionMarket {
    /// The execution system chooses the instrument.
    Automatic,
    /// The target position supplies the instrument that must be used.
    Specified { instrument_id: InstrumentId },
}


/// Side-agnostic: the executor derives side from the delta. A buy fills at
/// or below the resolved price, a sell at or above it.
pub enum TargetPositionPrice {
    /// A limit resolved by the executor at submission time as
    /// `reference * beta + c`,
    Relative {
        reference: PriceReference,
        // beta: Decimal,
        // c: Decimal,
        /// Where the limit sits relative to `reference * beta + c`, in the
        /// trade direction. Positive crosses the reference and is the worst
        /// price the strategy accepts. Zero places the limit at the reference.
        /// Negative rests inside it and expects to be a maker.
        limit_offset_bps: i32,
    },
}


pub enum PriceReference {
    /// Midpoint of the instrument execution uses. Late-bound.
    ExecutionInstrument,
    // Instrument { instrument_id: InstrumentId },
    // /// Oracle or index price for an asset.
    // Asset { asset_id: AssetId },
}
```

## Problem
I've started defining the feeds.
For the strategy deployment it's easy: data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs
However, I don't know how to handle the request/reply semantics with the target position executor.
It's different from the deployment feed
How would you model that?
```rust

// target_execution_feed.rs  (executor side)
pub struct TargetExecutorOrderand(pub u64);

/// Which deployment event this outcome answers. The event id is the
/// correlation id; nothing else is needed.
#[derive(Clone, Copy)]
pub struct TargetSetRef {
    pub strategy_deployment_id: StrategyDeploymentId,
    pub event_id: telemetry::EventId,
}

pub enum TargetPositionOutcome {
    /// Position equals target within tolerance.
    Completed { filled_quantity: numerics::Qty },
    /// Target will not be pursued. Closed set of reasons.
    Failed { reason: Arc<str> },
    /// A newer set for the same key replaced this one before completion.
    Superseded { by: TargetSetRef },
}

pub enum TargetPositionFailure {
    UnknownStrategy,
    UnknownAccount,
    AccountNotPaper,
    AccountNotAttached,
    UnknownInstrument,
    VenueRejected,
}

/// Terminal state of one target of one target set. Emitted exactly once
/// per (target set, account, subject).
pub trait TargetPositionOutcomeEvent:
    HasIdentity<Id = telemetry::EventId>
    + HasTracing<Id = telemetry::TraceId>
    + HasFeedOrderand<Orderand = TargetExecutorOrderand>
    + HasProvenance<Item = TargetSetRef>
{
    fn event_time(&self) -> time::NanoTimestamp;
    fn send_time(&self) -> time::NanoTimestamp;

    fn account_id(&self) -> TradingAccountId;
    fn subject(&self) -> TargetPositionSubject;
    fn outcome(&self) -> TargetPositionOutcome;
}

/// The executor could not act on the set at all (malformed, unknown
/// deployment). Per-target validation failures are per-target outcomes.
pub trait TargetSetRejectedEvent:
    HasIdentity<Id = telemetry::EventId>
    + HasTracing<Id = telemetry::TraceId>
    + HasFeedOrderand<Orderand = TargetExecutorOrderand>
    + HasProvenance<Item = TargetSetRef>
{
    fn event_time(&self) -> time::NanoTimestamp;
    fn send_time(&self) -> time::NanoTimestamp;
    fn reason(&self) -> TargetSetRejection;
}
```

## Requirements
- Give me replies with max 500 words per question (code excluded).


---
## Context
I want to only have the order working with the sim gw, the simplest possible thing for the demo version of the product.
We don't have drift, not hyperliquid. Just CME.

strats_v2/src/target_executor/engine_state/ready_state.rs
currently models a bunch of shit that I don't really need.
And the entrypoint of the event: strats_v2/src/target_executor/logic/target_position.rs tries to satisfy all of that nonsense.

What is the simplest solution we can have to make it work with the [simulation venue](sim-gw/src) only?
The contracts are messaging/msg-schemas/proto/gw/uni-gw/requests.proto

<details>
<summary>Sim gw</summary>
## Context
The sim gw has a number of contracts that are declared, but there is no logic implemented.
Specifically, I'm talking about the [DEC-0ANEJ: Simulation Venue Feed](knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md)

### Deposits / Withdrawals
We have the DEC document for the trading account deposit and withdrawal flow: knowledge-base/docs/decisions/records/DEC-07XKF-paper-trading-account-deposit-withdrawal.md
The sim gw has the message handler in sim-gw/src/state/ready.rs `impl<'a, TP, E> TopicMsgHandler<UniGwRequest> for ReadyStateNatsHandler<'a, TP, E>`
However, it now only handles the create order command.

### Feed encoding
For the demo, there is no clear encoding builder yet, so we'll handroll it for now.
The feed protobuf msgs are in data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/generated/messages.rs.
Exposed by `pub mod generated` in data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0/src/messages.rs

The nats subject is derived from SIM_VENUE_FEED from data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs:274
For now, all the feed events will go to that single subject, no matter the event kind or account/instrument/etc

There is no clear provenance in the demo for now, so we skip it.

### Feed event send time
Use the engine context's time provider

## Linear
You should divide work by subtasks and put them in Linear via the MCP integration
[ENG-1942: Implement the sim venue feed](https://linear.app/stxr/issue/ENG-1942)

Your word budget is 500 words per issue description (excluding the code snippets).

## Tasks

### sim venue feed orderand
- [DEC-0ANEJ: Simulation Venue Feed](knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md)
The simulation venue orderand is assumed to be encoded as
`(seconds since JAN 2026) << 31 | (sequence number & 2^32)`
in a `u64`. Consumers must treat `SimGwOrderand` as an opaque, feed-scoped
ordering value ([DEC-07RD2]) and must not decode or interpret the bit layout.
If the encoding changes, opaque consumers are unaffected.
This is necessary for the stateless sequence number generation, since we have not yet implemented
the engine state serialization for the demo.

This must be created in the sim gw and stored in the sim gw data.
I prefer you making a trait that gives you the "next" orderand.

### deposit
in sim-gw/src/logic create "deposit.rs" and handle the deposit logic there.
Ignore the cost basis in the calculations; it's only necessary for the deposit event in the sim venue feed.

### withdrawal
in sim-gw/src/logic create "withdrawal.rs" and handle the deposit logic there.
Use some kind of withdrawal policy, like
```rust
pub trait WithdrawalApprovalRequest {
    fn account_id(&self) -> TradingAccountId;
    fn asset_id(&self) -> AssetId;
    fn quantity(&self) -> Decimal;

}
pub trait WithdrawalApprovalPolicy {
    type Request: WithdrawalApprovalRequest;

    fn approve_withdrawal(
        &self,
        request: &Self::Request,
    ) -> WithdrawalApproval;
}

pub enum WithdrawalApproval {
    Approved,
    Rejected(String),
}
```
For now, the only implementation for that policy is that the balance after withdrawal is not negative.

Then, publish the withdrawal event


### publish_account_position_update
[publish_account_position_update](sim-gw/src/logic/position.rs)
- different topic -> use the demo feed subjects (SIM_VENUE_FEED from data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs:274)
- different message -> [traits::TradingAccountPositionsUpdate](data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs:98)

### publish_fill
finish the mockup in sim-gw/src/logic/order.rs by sending a [traits::Fill](data-feed-definitions/rust/crates/data-feed-definitions/src/demo/sim_venue_feed.rs)
</details>

<details>
<summary>Strategy template</summary>

## Context
I want to align the strategy target position with what the target executor expects after the recent changes.
I have a definition of the data feed in data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs
And a codec in ./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5
The target executor already consumes that event.
However, the [build_action_proto_request](dsl-runtime/src/utils.rs) still uses the old schema.

There are many issues with the current implementation of the target positions.
Implement brainstorm/prompts/target-position-executor/strat-target-positions.md.
First, plan the changes, then spawn a haiku subagent to create the issues in Linear.
Parent issue: https://linear.app/stxr/issue/ENG-1485, assignee: capuchin, cycle: current, points: each is one point, status: in progress.
Your max word budget is 300, excluding the code snippet.

Without waiting for the linear subagent, start the implementation.

## tasks

### use the feed contract
- data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs
- data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5

### implement the necessary changes for the target positions
Only the coverage=Partial and absent_target_policy=Preserve should be used for now, otherwise the target executor will reject.


</details>

<details>
<summary>Trading Account Positions</summary>

## Error by application server
```
{"path":"/api/v0/positions","method":"GET","handler_name":"list","error":"Error: positions_service.list.list_err err=repository.driver_error err=position_snapshots.list.query_err err=query_err err=ApiError[INTERNAL]: failed to execute clickhouse query: [{\"@type\":\"ErrorInfo\",\"reason\":\"CLICKHOUSE_CLIENT_QUERY_ERR\",\"metadata\":{\"query_id\":\"2015\",\"error\":\"Error: Unknown table expression identifier 'trading_account_events' in scope SELECT account_id, sequence_number, timestamp_nanos, account_positions, account_balances FROM trading_account_events WHERE event_kind = 'account_position' ORDER BY timestamp_nanos DESC, sequence_number DESC, account_id ASC LIMIT 1 BY account_id. \"}}];","stack":"Error: positions_service.list.list_err err=repository.driver_error err=position_snapshots.list.query_err err=query_err err=ApiError[INTERNAL]: failed to execute clickhouse query: [{\"@type\":\"ErrorInfo\",\"reason\":\"CLICKHOUSE_CLIENT_QUERY_ERR\",\"metadata\":{\"query_id\":\"2015\",\"error\":\"Error:
```

## Context
I changed the schema in the knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md,
prototypes/accounting/db/deployment-schema.sql

but I did not fix the application server structure-web/packages/api/src/positions/positions-repository.ts
The position_updates table should include all the necessary information about the latest positions.
For the sequence number, use the ingestion orderand for now.
derivative_positions[].quantity is the base amount
the quote amount should be 0

</details>
