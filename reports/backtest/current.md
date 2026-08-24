## Initial Historical Tick

```
Ingress: StratIngressMsg::HistTickData
  -> StratComponentHost::process_msg
     -> StratComponentHost::process_backtest_hist_tick
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
The optimized path is implemented in component.rs:454.
_!!!_ The important detail is that SimExecReport is **NOT** processed inline.
It is inserted into the replayer's temporal stream and becomes eligible at its execution timestamp.

__SimExecReporter__ is the bridge that turns simulator execution reports into a time-ordered historical-data stream
```
ExecSimulator
  -> egress channel
     -> BTestControllerEgress
        -> SimExecReporter
           -> replayer heap
              -> engine ingress
```
1. Receives SimExecReport messages from egress.
2. Buffers them with their execution timestamp and block sequence.
3. Exposes them as a HistDataStream so StreamingHistDataReplayer can merge them with market-data streams.

## Execution Report Flow
Suppose the action was generated at timestamp T and the configured execution delay is D.
```
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
StratIngressMsg::SimExecReport(_) => MessageRoute::LogicOnly

## Q&A

### why do we need to send the sim exec report back to the ingress?
Because the execution report is a new event that the strategy must observe.
The simulator updates its own internal account state when it executes the action,
but the strategy's TradingContext is separate.

### if I want to add new events
```
-> ExecSimulatorState::process_btest_action
   -> ExecSimulator::on_btest_action
```
Is the spot to do it.
I can be a complete pig and just build the protobuf messages right there.
Fuck the dictionary encoding, just use the full identifiers




