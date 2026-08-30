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

## Proposal
The target position should have at least
```rust

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

pub trait TargetPosition {
    fn account_id(&self) -> AccountId;
    /// The economic position requested by the strategy.
    fn subject(&self) -> TargetPositionSubject;
    /// Whether execution may select a market or must use a specified market.
    fn target_market(&self) -> TargetPositionMarket;
    fn quantity(&self) -> numerics::Qty;
}
```

## Problem

Additionally, it should have the price embedded in it.
Howe would you modify the `TargetPosition` trait?
There is already some old implementation in the [build_action_proto_request](dsl-runtime/src/utils.rs:71) function.
However, I don't like that it's in the protobuf message and not on the trait.

## Requirements
- Give me replies with max 500 words per question (code excluded).
- It should be flexible for extension, propose variants





