# SimExecReport Event Flow After Strategy Actions

> Session: `ses_fdb0ac394ffem05KMloRBTf2tT`
> Source: OpenCode session export

---

## User

I want to understand how the structure-strat-template-core/src/component.rs, specifically when it comes to the SimExecReport works?

So, we start from loading the historical data into the EventHeap (min heap by sn). Then one by one, we dispatch the messages from the heap to the engine component host. based on the message, we invoke the strategy, which may or may not produce the actions in structure-strat-template-core/src/engine_state/strat_logic/common.rs:96. What happens next?

---

## Assistant

I'll trace the execution path from `EventHeap` dispatch through strategy actions and `SimExecReport`, then map the state transitions and callbacks back to the relevant files.

*(reads: component.rs, common.rs, btest_state.rs, exec_simulator.rs, sim_reporter.rs, egress.rs, hist_data.rs, strat_logic.rs, backtest.rs)*

**Execution Flow**

After `handle_tick_data_common` returns `Ok(Some(ActionSet))` at `common.rs:96`, the result is not executed immediately by the strategy. It goes through the backtest action pipeline.

1. **Action filtering and conversion**

`StratBacktestState::dispatch_tick_result_internal` calls:

```rust
action_manager.on_new_actions_backtest(action_set, StrategyPhase::Running)
```

This may return:

- `Some(BTestAction)`: an executable target-position action.
- `None`: action suppressed, commonly because it is similar to the previous action.

See `btest_state.rs:367`.

2. **The action reaches the simulator**

In the current optimized path, `component.rs:325` handles a historical tick in one engine cycle:

```text
HistTickData
  -> simulator.on_hist_tick()
  -> strategy logic
  -> ActionSet
  -> BTestAction
  -> simulator.process_btest_action()
```

The simulator:

- Calculates `execution_ts_ns = current_ts + execution_delay`.
- Applies target positions internally.
- Uses the latest market prices and configured slippage.
- Produces a `SimExecReport::SimAccountSnapshot`.

This happens in `dsl-backtest-runtime/src/exec_simulator.rs:274`.

3. **The simulator's state changes immediately**

`process_btest_action` applies the target positions before creating the report:

```rust
let account_snapshots =
    self.apply_target_positions(&action.action_set, mkt_info_repo)?;
```

So the simulator's internal account state now reflects the simulated fill.

However, the strategy's `TradingContext` does **not** update yet. It updates only when the resulting `SimExecReport` is later replayed.

4. **The report is sent to egress**

The report is sent to the egress channel at `component.rs:477`.

The component also sends `BTestProcessResult::TickProcessed` afterward:

```text
SimExecReport
TickProcessed
```

The egress handler:

- Sends the report to `SimExecReporter`.
- Writes it to the JSONL backtest output.
- Eventually acknowledges the historical tick.

See `btest_controller/egress.rs:377`.

5. **The report enters the historical-data merge**

`SimExecReporter` receives the report and stores:

```text
(report, execution_sequence, execution_timestamp)
```

Its sequence is based on:

```rust
DslSeqNum {
    ts_nanos: report.exec_ts_ns(),
    block_seq: report.block_seq(),
}
```

See `sim_reporter.rs:213` and `sim_reporter.rs:264`.

The reporter is another input stream to the historical-data replayer. Therefore the report is not dispatched directly back into the engine. It is inserted into the same temporal ordering mechanism as market data.

For example, with a one-second execution delay:

```text
market tick at T
strategy creates action at T
report becomes executable at T + 1s
market data between T and T + 1s is processed first
report is dispatched at T + 1s
```

6. **The replayer dispatches `SimExecReport`**

When the report becomes the minimum item in the replayer heap, it is popped and sent as:

```rust
StratIngressMsg::SimExecReport(report)
```

`component.rs:355` routes this message only to strategy logic:

```rust
SimExecReport => MessageRoute::LogicOnly
```

The simulator must not receive its own report; it explicitly treats that as unreachable in `exec_simulator.rs:104`.

7. **The report is converted into strategy-visible account ticks**

`StratBacktestState::on_sim_exec_report` receives the report.

For each account snapshot, it creates a synthetic:

```rust
TickData::ConsolidatedAccountUpdate(
    ConsolidatedAccountUpdate::AccountPositionUpdate(...)
)
```

The synthetic subject is the canonical account-position topic.

See `btest_state.rs:261`.

Then it calls `handle_tick_data_common` again:

```rust
handle_tick_data_common(
    &tick_data,
    &subject,
    timestamp,
    &mut self.trading_ctx,
    &mut self.strat_data,
    ...
)
```

This is important: the execution report feeds the resulting positions back through the same strategy graph machinery as ordinary market data.

Consequently:

- `TradingContext` is updated with the simulated account position.
- If the account update is a trigger topic, the strategy graph runs.
- The graph may generate another `ActionSet`.
- The last generated action set across all account snapshots is retained.

8. **Any follow-up action is processed**

After all snapshots in the report are processed:

```rust
self.dispatch_tick_result(final_action_set, context, context.get_nanos())?;
```

Possible outcomes:

```text
follow-up ActionSet
  -> ActionManager
  -> BTestAction
  -> simulator
  -> next SimExecReport
```

or:

```text
no action
  -> BTestProcessResult::TickProcessed
  -> replayer acknowledgment
```

See `btest_state.rs:577`.

**Complete Loop**

```text
Historical tick
  -> update simulator market book
  -> run strategy graph
  -> ActionSet
  -> ActionManager
  -> BTestAction
  -> simulated fill
  -> SimExecReport
  -> egress/file/reporter
  -> temporal replayer heap
  -> report dispatched at execution timestamp
  -> synthetic account-position tick
  -> update TradingContext
  -> run strategy graph again
  -> possibly produce another action
```

The key distinction is:

- The simulator applies the fill immediately when processing `BTestAction`.
- The strategy observes that fill only later, when `SimExecReport` reaches its scheduled execution timestamp through the replayer.

---

## User

can you also do it in a format like this Ingress -> Component -> Strategy -> Actions flow

```
StratComponentHost::process_msg {
  if StratIngressMsg::HistTickData {
    -> StratComponentHost::process_backtest_hist_tick
  }
}

StratComponentHost::process_backtest_hist_tick
  -> ExecSimulatorState::on_hist_tick [store the data in the contexts]
  -> StratBacktestState::on_hist_tick_data_internal [compute the DAG and return the actions]
  -> ExecSimulatorState::process_btest_action [get the SimExecReport]
  -> StratBacktestState::send_egress_msg_with_ts [sends the SimExecReport to the egress]
  -> StratBacktestState::send_tick_processed_msg [sends the egress message with the BTestProcessResult::TickProcessed]
```

---

## Assistant

### Initial Historical Tick

```text
Ingress: StratIngressMsg::HistTickData
  -> StratComponentHost::process_msg
     -> StratComponentHost::process_backtest_hist_tick
```

```text
StratComponentHost::process_backtest_hist_tick
  -> ExecSimulatorState::on_hist_tick
     -> ExecSimulator::on_tick_data
        -> update simulator market/book state

  -> StratBacktestState::on_hist_tick_data_internal
     -> handle_tick_data_common
        -> update TradingContext
        -> determine whether the topic is a trigger
        -> execute the strategy DAG
        -> return Option<ActionSet>

  -> StratBacktestState::dispatch_tick_result_internal
     -> ActionManager::on_new_actions_backtest
        -> compare/filter the ActionSet
        -> return Option<BTestAction>

  -> ExecSimulatorState::process_btest_action
     -> ExecSimulator::on_btest_action
        -> calculate execution timestamp
        -> calculate simulated fills/slippage
        -> update simulator account state
        -> create SimExecReport

  -> StratBacktestState::send_egress_msg_with_ts
     -> sends StratEgressMsg::SimExecReport
        -> BTestControllerEgress
           -> sends report to SimExecReporter
           -> writes report to JSONL output
           -> report enters the replayer stream

  -> StratBacktestState::send_tick_processed_msg
     -> sends BTestProcessResult::TickProcessed
        -> BTestControllerEgress
           -> acknowledges the current historical tick
           -> replayer may dispatch the next event
```

The optimized path is implemented in `component.rs:454`.

The important detail is that `SimExecReport` is **not processed inline**. It is inserted into the replayer's temporal stream and becomes eligible at its execution timestamp.

---

### Execution Report Flow

Suppose the action was generated at timestamp `T` and the configured execution delay is `D`.

```text
SimExecReport
  -> SimExecReporter
     -> compute sequence:
        (execution_ts_ns = T + D, block_seq)
     -> buffer report

  -> StreamingHistDataReplayer
     -> inserts report into the min-heap
     -> waits until the report is the next event by sequence/time
     -> dispatches it at T + D

  -> StratComponentHost::process_msg
     -> StratIngressMsg::SimExecReport
     -> route = MessageRoute::LogicOnly

  -> StratLogicState::handle_ingress_msg
     -> StratBacktestState::on_sim_exec_report
```

The simulator does not receive this message:

```rust
StratIngressMsg::SimExecReport(_) => MessageRoute::LogicOnly
```

---

### Strategy Processing of `SimExecReport`

```text
StratBacktestState::on_sim_exec_report
  -> process_all_account_snapshots
     -> for each account snapshot:
        -> convert account positions/balances
           into synthetic TickData::ConsolidatedAccountUpdate

        -> handle_tick_data_common
           -> update TradingContext with executed positions
           -> determine whether the account topic is a trigger
           -> execute the strategy DAG again
           -> possibly return another ActionSet

  -> dispatch_tick_result
```

Relevant code:

```text
SimExecReport
  -> SimAccountSnapshot
     -> AccountSnapshotEntry
        -> synthetic AccountPositionUpdate
           -> handle_tick_data_common
              -> strategy DAG
              -> Option<ActionSet>
```

This is where the strategy finally observes the result of its simulated execution.

---

### Follow-Up Action

If processing the report produces another action:

```text
ActionSet
  -> ActionManager::on_new_actions_backtest
     -> BTestAction
        -> BTestProcessResult::BTestAction
           -> egress
              -> ingress: StratIngressMsg::BTestAction
                 -> StratComponentHost::process_msg
                    -> route = MessageRoute::SimulatorOnly
                       -> ExecSimulatorState::on_btest_action
                          -> simulator creates next SimExecReport
```

This follow-up path is not the same optimized path used for the original historical tick. The action is sent through egress and then back through ingress.

If no follow-up action is produced:

```text
No ActionSet
  -> BTestProcessResult::TickProcessed
     -> egress
        -> replayer acknowledgment
```

---

### Full Feedback Loop

```text
Historical data
  -> StratComponentHost
     -> simulator updates market book
     -> strategy DAG processes market tick
     -> ActionSet
     -> ActionManager
     -> BTestAction
     -> simulator applies simulated execution
     -> SimExecReport
     -> egress/file/reporter
     -> replayer heap
     -> report dispatched at execution timestamp
     -> synthetic account-position tick
     -> TradingContext updated
     -> strategy DAG processes execution result
     -> possibly another ActionSet
```

The separation is:

```text
Simulator state:
  updated immediately when BTestAction is executed

Strategy TradingContext:
  updated later when SimExecReport is replayed at execution time
```

This delay is what allows historical market data between order submission and execution to be processed before the strategy observes the fill.

---

## User

Wtf is SimExecReporter?

---

## Assistant

`SimExecReporter` is the bridge that turns simulator execution reports into a time-ordered historical-data stream.

```text
ExecSimulator
  -> egress channel
     -> BTestControllerEgress
        -> SimExecReporter
           -> replayer heap
              -> engine ingress
```

It does three things:

1. Receives `SimExecReport` messages from egress.
2. Buffers them with their execution timestamp and block sequence.
3. Exposes them as a `HistDataStream` so `StreamingHistDataReplayer` can merge them with market-data streams.

It is implemented in:

```text
dsl-runtime/crates/dsl-backtest-runtime/src/btest_controller/sim_reporter.rs
```

The key methods are:

```rust
peek_next()
```

Returns the report's ordering metadata:

```text
(execution timestamp, block sequence)
```

```rust
pop()
```

Removes the next buffered report for dispatch.

The reporter does **not**:

- Execute orders.
- Update simulator positions.
- Run the strategy.
- Process the report inside the component directly.

Its purpose is temporal ordering. For example:

```text
Market tick at T
Action generated at T
Execution delay = 1 second
Market tick at T + 500ms
SimExecReport at T + 1 second
```

The reporter makes the report appear to the replayer at `T + 1 second`, so the `500ms` market tick is processed first.

Without `SimExecReporter`, the simulator would have to send the report directly back into the engine, which would incorrectly make the fill visible immediately at order-submission time.

---

## User

Okay, why do we need to send the sim exec report back to the ingress?

---

## Assistant

Because the execution report is a **new event that the strategy must observe**.

The simulator updates its own internal account state when it executes the action, but the strategy's `TradingContext` is separate. The strategy learns about the fill only through:

```text
SimExecReport
  -> egress
  -> SimExecReporter
  -> historical-data replayer
  -> ingress
  -> strategy logic
```

This is needed to:

- Update `TradingContext` with the executed positions and balances.
- Trigger strategy logic based on the account-position update.
- Preserve the configured execution delay.
- Order the report correctly relative to market data.
- Keep all strategy-visible events serialized through the engine's normal ingress boundary.

Without sending the report back through ingress:

```text
Simulator position = updated
Strategy TradingContext = stale
```

The strategy would not know that its order executed and could make decisions from obsolete positions.

The ingress path is therefore not only for external market data. In this architecture, it is the engine's serialized event boundary, and simulated fills must pass through it so they behave like real execution/account updates.

---

## User

oh, I see. But that's not a fill, it's a position snapshot that is then used for the strategy logic. Okay, say I wanted to capture the fill events in the backtest results. How would that work? I guess there is no real 'venue simulator' that gets a target position. the backtest just immediately updates the state. Ideally, I want to emit the triggering source event, target position, fill, etc. Would this all be in on_btest_action? Say, I really want to hack it and not change much

---

## Assistant

I'll inspect the simulator's existing order and exchange-result data flow to identify the smallest place to derive and emit fill records without redesigning the backtest loop.

*(reads: exec_simulator.rs, backtest.rs, searches for SimExchangeResult)*

Yes. The smallest practical hack is to keep the existing `SimExecReport` pipeline and enrich the report with fill data.

You do **not** need a separate venue-simulator event stream yet. The simulator already calculates the information you need inside:

```text
ExecSimulator::on_btest_action
  -> apply_target_positions
     -> calculate_sim_exch_result
     -> apply_exchange_result
```

The current problem is simply that `SimExchangeResult` is discarded after being applied.

### Current Flow

```text
ExecSimulator::on_btest_action
  -> execution_ts_ns = trigger_ts + delay
  -> apply_target_positions
     -> for each target:
        -> calculate_sim_exch_result
        -> apply_exchange_result
     -> return final account snapshots
  -> create SimExecReport::SimAccountSnapshot
```

`calculate_sim_exch_result` already knows:

- Account ID
- Instrument ID
- Target quantity
- Current position/balance
- Quantity delta
- Mid/oracle price
- Slippage-adjusted execution price
- Balance deltas
- Realized PnL inputs

See `dsl-backtest-runtime/src/exec_simulator.rs:205`.

### Minimal Design

Add fills to `SimAccountSnapshot`:

```rust
pub struct SimAccountSnapshot {
    pub account_snapshots: Arc<[(AccountId, AccountSnapshotEntry)]>,
    pub fills: Arc<[SimFill]>,
    pub execution_ts_ns: u64,
    pub block_seq: SequenceNumber,
}
```

Define a simple record:

```rust
pub struct SimFill {
    pub account_id: AccountId,
    pub instrument_id: InstrumentId,
    pub target_qty: Decimal,
    pub filled_qty: Decimal,
    pub price: Decimal,
    pub trigger_ts_ns: u64,
    pub execution_ts_ns: u64,
}
```

Or with extra context:

```rust
pub struct SimFill {
    pub account_id: AccountId,
    pub instrument_id: InstrumentId,
    pub target_qty: Decimal,
    pub previous_qty: Decimal,
    pub filled_qty: Decimal,
    pub price: Decimal,
    pub trigger_ts_ns: u64,
    pub execution_ts_ns: u64,
    pub block_seq: SequenceNumber,
}
```

### Where to Construct It

Change `apply_target_positions` to return both the final snapshot and fills:

```text
apply_target_positions
  -> for each target:
     -> calculate_sim_exch_result
        -> return SimExchangeResult {
             balance_deltas,
             derivative_orders,
             fills,
           }
     -> append fills
     -> apply_exchange_result
  -> return (account_snapshots, fills)
```

Conceptually:

```rust
let (account_snapshots, fills) =
    self.apply_target_positions(
        &action.action_set,
        mkt_info_repo,
        current_ts_ns,
        execution_ts_ns,
    )?;
```

Then:

```rust
SimExecReport::SimAccountSnapshot(SimAccountSnapshot {
    account_snapshots,
    fills,
    execution_ts_ns,
    block_seq,
})
```

This preserves the existing flow:

```text
BTestAction
  -> simulator
  -> SimExecReport
  -> egress
  -> SimExecReporter
  -> replayer
  -> strategy ingress
```

The report remains the strategy-visible position update, but now it also carries the audit/fill records.

### Fill Calculation

For derivatives, the existing code already has the essential fill:

```rust
ExecutedOrder {
    instrument_id,
    size: delta,
    price: exec_px,
}
```

So you can convert that directly:

```text
ExecutedOrder
  -> SimFill {
       filled_qty: order.size,
       price: order.price,
     }
```

For spot, the current code creates balance deltas:

```text
base balance delta = filled quantity
USD balance delta = execution cost
```

You can derive an effective fill price from:

```text
price = absolute(home_currency_delta / base_quantity_delta)
```

Or, preferably, explicitly store the oracle/mid price and slippage-adjusted execution price while calculating the spot exchange result.

### Triggering Source Event

`on_btest_action` already receives:

```rust
current_ts_ns
```

That is the triggering event timestamp in the normal historical-tick path:

```rust
process_backtest_hist_tick
  -> current_ts_ns = tick.timestamp
  -> process_btest_action(..., current_ts_ns, ...)
```

So record:

```rust
trigger_ts_ns: current_ts_ns
execution_ts_ns: current_ts_ns + execution_delay
```

The action set also carries its block sequence, so retain that as the source sequence if needed:

```rust
action.action_set.block_seq()
```

### Writing Results

The least invasive output change is in:

```text
btest_controller/egress.rs::write_action_to_file
```

Currently it serializes:

```rust
SimReport {
    snapshot,
    instrument_metadata,
}
```

Add fills to the serialized report:

```rust
pub struct SimReport<'a> {
    pub snapshot: &'a SimAccountSnapshot,
    pub fills: &'a [SimFill],
    pub instrument_metadata: &'a AHashMap<...>,
}
```

Then your JSONL output can contain:

```json
{
  "trigger_ts_ns": 1000000000,
  "execution_ts_ns": 2000000000,
  "fills": [
    {
      "account_id": "...",
      "instrument_id": 123,
      "target_qty": "10",
      "previous_qty": "4",
      "filled_qty": "6",
      "price": "101.25"
    }
  ],
  "snapshot": {
    "...": "final account state"
  }
}
```

### Important Caveat

A `BTestAction` may contain multiple target positions. Therefore the fill should be emitted per:

```text
(account_id, instrument_id)
```

not once per action.

The minimal architecture is therefore:

```text
ActionSet
  -> simulator calculates target deltas
  -> simulator creates SimFill records
  -> simulator applies those deltas
  -> report contains:
       triggering metadata
       fills
       final position snapshot
  -> existing egress/reporter/replayer flow remains unchanged
```

That gives you source event, target, actual simulated fill, price, execution timestamp, and resulting position without introducing a new event type or changing the backtest control loop.

---

## User

Ideally, it should comply with the knowledge-base/docs/specs/SPEC-backtest-feed.md. forget about the dictionary encoding and optimizations for now. I just want to have the data emitted

---

## Assistant

*(reads: SPEC-backtest-feed.md, layer-definitions.md, testing-strategy.md, idiomatic-code.md, no-undefined-behavior.md, AGENTS.md)*

---

## User

do not implement anything, just report

---

## Assistant

**Report**

No files were changed.

The current backtest output is not a `BacktestResults` feed yet. It currently emits one JSONL record per `SimExecReport`, containing:

```text
SimAccountSnapshot
  -> final positions
  -> balances
```

The writer is `dsl-backtest-runtime/src/btest_controller/egress.rs::write_action_to_file`.

### What Exists Already

`ExecSimulator::calculate_sim_exch_result` already computes most fill facts:

```text
account_id
instrument_id
target quantity
current quantity
quantity delta
execution price
balance deltas
derivative order details
```

The current flow is:

```text
BTestAction
  -> ExecSimulator::on_btest_action
     -> apply_target_positions
        -> calculate_sim_exch_result
        -> apply_exchange_result
     -> snapshot_all
  -> SimExecReport::SimAccountSnapshot
  -> JSONL output
```

The missing part is that `SimExchangeResult` is discarded after `apply_exchange_result`. Only the final snapshot survives.

### Why `on_btest_action` Is Not Enough

`on_btest_action` can directly produce:

```text
TargetPositions
Fill
TradingAccountPositionsUpdate
```

But it does not inherently have the original triggering source event.

It receives:

```rust
&BTestAction
current_ts_ns
```

`current_ts_ns` is enough for timestamps, and `action.action_set.block_seq()` can provide trace-like sequencing. However, the original market/source event payload and its feed identity have already been consumed by the time the action reaches `on_btest_action`.

To emit `TriggeringSourceEvent`, that provenance must be captured earlier and propagated through the action path.

### Spec Event Mapping

The desired mapping is:

```text
Historical source event
  -> TriggeringSourceEvent

Strategy-generated ActionSet
  -> TargetPositions

Simulator market state before execution
  -> PricesUpdate

Simulator calculated delta
  -> Fill

Simulator final account state
  -> TradingAccountPositionsUpdate

Backtest termination
  -> BacktestJobCompleted
```

The current code only emits the last meaningful item:

```text
SimAccountSnapshot
  -> TradingAccountPositionsUpdate-like data
```

It does not currently emit raw `Fill` or `TargetPositions` events.

### Required Fill Semantics

Per `SPEC-backtest-feed.md`, each fill needs:

```text
event_time
observe_time
instrument
account
price
unsigned quantity
explicit trade side
liquidity role
provenance
```

For this simulator:

```text
event_time   = simulated execution timestamp
observe_time = timestamp when the report re-enters strategy ingress
quantity     = absolute simulated fill delta
price        = slippage-adjusted execution price
side         = explicitly derived from the signed delta
liquidity    = likely Taker for this immediate simulator
provenance   = TargetPosition { event_id }
```

The current `ExecutedOrder` already supplies the derivative `quantity` and `price`. Spot execution currently stores balance deltas, so its fill price and quantity would need to be retained explicitly rather than reconstructed later.

### Ordering Requirement

The spec requires:

```text
PricesUpdate
  -> Fill
```

for every fill.

Therefore, simply adding `fills` to `SimAccountSnapshot` would expose the data, but would not fully comply with the feed contract. A conforming feed needs separate ordered events:

```text
TargetPositions
  -> PricesUpdate
  -> Fill
  -> DemoOnlyFee, if applicable
  -> TradingAccountPositionsUpdate
```

The feed also requires:

```text
BacktestDefinition first
BacktestJobCompleted last
feed-scoped sequential event IDs
feed-scoped monotonic orderands
```

None of those concepts exist in the current JSONL report writer.

### Smallest Useful Implementation Boundary

For a minimal raw-data version, the best boundary is still the simulator, but the output should be an intermediate event collection rather than only a snapshot:

```text
ExecSimulator::on_btest_action
  -> calculate raw execution facts
  -> return:
     - target-position record
     - fill records
     - final account snapshot
```

Then the egress writer could serialize those records in order.

However, to include the triggering source event:

```text
process_backtest_hist_tick
  -> capture source-event metadata
  -> strategy produces ActionSet
  -> attach source provenance to BTestAction
  -> simulator receives propagated provenance
```

So the minimal data path would be:

```text
HistTickData
  -> source-event metadata
  -> ActionSet / TargetPositions
  -> BTestAction with provenance
  -> simulator calculates fills
  -> raw feed records
  -> JSONL
```

### Bottom Line

`on_btest_action` is the correct place to calculate and capture:

```text
target position
filled quantity
execution price
execution timestamp
resulting position snapshot
```

It is not the correct place to discover the original source event. That provenance must be captured before or while the strategy creates the `BTestAction`.

Adding `fills` to `SimExecReport` is the smallest hack that exposes the data, but it is only a partial implementation of `SPEC-backtest-feed.md`. A minimally spec-shaped implementation needs an ordered raw-event writer with at least:

```text
TargetPositions
PricesUpdate
Fill
TradingAccountPositionsUpdate
```

plus propagated source provenance and feed-local ordering.
