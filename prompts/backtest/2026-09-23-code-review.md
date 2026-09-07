## 1. Params
StrategyComponent::new (structure-strat-template-core/src/component.rs:120)
```
let strat_data = params
    .strat_data
    .take()
    .expect("strat_data should never be None");
```
if the strat data should never be None, why is it an option in the params, then?
Who is using the `component_params.warehouse_dir`?
Why not rename the `buffered_live_account_snapshots` to `initial_trading_account_positions` and keep the hashmap empty for the backtest?

## 2. on_feed_subject
StrategyComponent::on_feed_subject structure-strat-template-core/src/component.rs:246
```
pub fn on_feed_subject<TP, E>(
    &mut self,
    subject: &str,
    bytes: bytes::Bytes,
    now: NanoTimestamp,
    prices: Option<&mut PriceTracker>,
    engine_ctx: &EngineStateContext<'_, TP, E>,
) -> Result<FeedOutcome, StratLogicError>
where
    TP: TimeProvider,
    E: StratComponentEgressTrait,
{
// ...
}
```
Why is a price tracker an argument to the feed subject?
Why can't you use the on_feed_msg?
Why does on_feed_msg need a price tracker?


---
So:
1. fix the strat_data to lose the Option<>
2. remove the warehouse_dir
3. rename the `buffered_live_account_snapshots`
4. mirror the accounting from sim-gw/src/logic/order.rs and get rid of the home currency and the hardcoded USD
5. remove the price tracker from the sim venue
6. the target executor needs its price tracker that is updated by mid mkt price of mbp1
7. get rid of the fee calculation for now
8. get rid of the simulated slippage bps

If the work is parallelizable, do it in parallel

## 3. backtest feed analysis
