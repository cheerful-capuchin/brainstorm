## Requirements
- plain technical English with no jargon
- max 300 words per reply (excluding code)

## Context
I want to change the ingress layer of the strategy with the minimum refactoring required to ship for a demo.

### Current state
The strategy in StratLiveDataState::on_nats_message matches the subject with the resolved symbolic topic,
and then parses the message as a protobuf message and passes it to the logic in
structure-strat-template-core/src/engine_state/strat_logic/common.rs

The strategy code assumes only Drift or Hyperliquid protobuf messages.
It then creates a union (enum) type with all the messages and passes it to the strategy source event handlers.

### Desired state
We've recently created a notion of [data feeds](knowledge-base/docs/references/data-feed.md) and there are some built already in
data-feed-definitions/rust/crates/data-feed-definitions/src/demo/databento_mbo_feed.rs,
data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs.

Based on the data feed idea, for every message there is a dedicated handler function that is called.
That handler, then, calls into the strategy source event handler or does some other logic.

## Tasks
do NOT change the backtest historical replay, ingress or egress managers. We're only fixing the component.
The tasks below are checkpoints for the data feed integration into the strategy logic.
You'll need the following feeds
```
data-feed-definitions = { git = "ssh://git@github.com/stxr-prop/data-feed-definitions.git", branch = "main" }
sim-venue-feed-codec = { package = "data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0", git = "ssh://git@github.com/stxr-prop/data-feed-definitions.git", branch = "main" }
databento-mbo-feed-codec = { package = "data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d",  git = "ssh://git@github.com/stxr-prop/data-feed-definitions.git", branch = "main" }
```

### Strategy Handler
Based on the ideas from the dev-docs/frameworks/engine-component-application-structure.md,
we need to have the strategy handler that will handle all the feed messages
structure-strat-template-core/src/handler.rs
That handler will implement the data feed traits, like
- TradeHandler
- Mbp1BookUpdateHandler
- FillHandler
- TradingAccountPositionUpdateHandler
- DepositHandler
- WithdrawalHandler
- DemoOnlyFeeHandler

Some of those handlers are noop
```
use data_feed_definitions::demo::traits::{FeedHandler, FeedMessageContext};

pub struct StrategyHandler<'a, TP, E> {
    pub state: &'a mut StratLogicState,
    pub context: &'a EngineStateContext<'a, TP, E>,
    pub params: &'a mut StratLogicParams // can I access these or do I need to get it from the state?
}

impl<'a, TP, E> StrategyHandler<'a, TP, E> {
    pub fn new(
        state: &'a mut StratLogicState,
        context: &'a EngineStateContext<'a, TP, E>,
        params: &'a mut StratLogicParams
    ) -> Self {
        Self {
            state,
            context,
            params,
        }
    }
}

impl<TP, E> FeedHandler for StrategyHandler<'_, TP, E> {
    type Error = StratLogicError;
}
```

### Feed Message
The FeedMsg struct that will carry the payload bytes and data feed ref.
Based on the data feed ref, we can figure out which codec to use
```
pub struct FeedMsg {
    pub bytes: bytes::Bytes,
    pub data_feed_ref: DataFeedRef,
}
```

### Feed Message Handler
The engine component should have the "on_feed_msg" function that knows how to decode each data feed.
For now, those are hardcoded assumptions based on the FeedKind and encoding, see [split_feed_id](data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs)
```
impl Component {
    pub fn on_feed_msg(&mut self, msg: FeedMsg) {
        let handler = StrategyHandler { ... };
        let kind = split_feed_id(msg.data_feed_ref.feed_id);
        match (kind, msg.data_feed_ref.encoding) {
            (DATABENTO_MBO_FEED.kind_id, EncodingKind::Dbn) => Mbp1BookDbnPayloadConsumer::consume_payload(..., handler), // data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d
            (SIM_VENUE_FEED.kind_id, EncodingKind::Protobuf) => SimulationVenueProtobufPayloadConsumer::consume_payload(..., handler), // data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0
        }
    }
}
```
For the StratIngressMsg::NatsMessage handler, we'll just match the interesting feeds with the NATS subject.
See [feed_topic](data-feed-definitions/rust/crates/data-feed-definitions/src/demo.rs:332).

### Mbp1 Update -> Strategy logic
For the strategy logic, we'll just resolve the necessary semantic topic and then the necessary handler ref
```
fn handle_mbp1_book_update<C: FeedMessageContext, M: Mbp1BookUpdate>(
    &mut self,
    context: &C,
    msg: &M,
) -> Result<(), Self::Error> {
    let sem_topic = self.params.rt_params.instrument_id_to_symbol.get(&msg.instrument_id())
        .map(|symbol| dsl_runtime::topics::SymbolicTopic::BookL1 {
            instrument_id: symbol, // todo: it should not be &'static str
        })
        .map(|topic| StratSrcEvent::try_from(topic)); // structure-strat-template-core/src/generated/strategy.rs:77

    // dispatch to strategy (logic/strategy.rs)?
    if let Some(topic) = sem_topic {
        let Ok(handler) = topic else {
            todo!()
        };
        ///
        /// impl From<T> for BookL1Update
        // where T: data_feed_definitions::demo::traits::Mbp1BookUpdate {
        //     // ...
        // }
        let update = BookL1Update::from(msg);
        let tick_data = TickData::BookL1(update);
        let action_set_opt = handle_tick_data_common(
            &tick_data,
            handler, // todo: fix handle_tick_data_common
            self.context.get_nanos(),
            &mut self.trading_ctx,
            &mut self.strat_data,
            &mut self.action_manager,
            &mut self.params,
            self.context,
            LIVE_STATE_CALLSITE,
            EngineRegime::Live,
            StrategyPhase::Running,
        )
            .map_err(|e| StratLiveStateError::HandleTickDataError(e))?;

    }
}
```

### Mbp1 Update -> Backtest logic
In addition to handling the strategy, backtest keeps the price tracker with the mkt data.
And instead of using the [SimMarketData](dsl-runtime/crates/dsl-backtest-runtime/src/exec_simulator.rs:50), we should use the [PriceTracker](trade/crates/trade-core/src/price/tracker.rs)
```
fn handle_mbp1_book_update<C: FeedMessageContext, M: Mbp1BookUpdate>(
    &mut self,
    context: &C,
    msg: &M,
) -> Result<(), Self::Error> {
    // ...
    if let Some(mid_mkt) = mid_mkt_price(msg) {
        // backtest.price_tracker.upsert(...)
    }
}
fn mid_mkt_price<M: Mbp1BookUpdate>(msg: &M) -> Option<Price> {
    let (bid, ask) = (msg.bid()?, msg.ask()?);
    Some((bid.price + ask.price) / Decimal::TWO.into())
}
```

### Trade Update -> Strategy Logic
For the strategy logic, we'll just resolve the necessary semantic topic and then the necessary handler ref
```
fn handle_trade<C: FeedMessageContext, M: Trade>(
    &mut self,
    context: &C,
    msg: &M,
) -> Result<(), Self::Error> {
    let sem_topic = self.params.rt_params.instrument_id_to_symbol.get(&msg.instrument_id())
        .map(|symbol| dsl_runtime::topics::SymbolicTopic::Trade {
            instrument_id: symbol, // todo: it should not be &'static str
        })
        .map(|topic| StratSrcEvent::try_from(topic)); // structure-strat-template-core/src/generated/strategy.rs:77

    // dispatch to strategy (logic/strategy.rs)?
    if let Some(topic) = sem_topic {
        let Ok(handler) = topic else {
            todo!()
        };
        ///
        /// impl From<T> forTradeUpdate
        // where T: data_feed_definitions::demo::traits::Mbp1BookUpdate {
        //     // ...
        // }
        let update = TradeUpdate::from(msg);
        let tick_data = TickData::Trade(update);
        let action_set_opt = handle_tick_data_common(
            &tick_data,
            handler, // todo: fix handle_tick_data_common
            self.context.get_nanos(),
            &mut self.trading_ctx,
            &mut self.strat_data,
            &mut self.action_manager,
            &mut self.params,
            self.context,
            LIVE_STATE_CALLSITE,
            EngineRegime::Live,
            StrategyPhase::Running,
        )
            .map_err(|e| StratLiveStateError::HandleTickDataError(e))?;

    }
}
```


### TickData

If you take a look at the [TickData](dsl-runtime/crates/dsl-runtime-nodes/src/types.rs), it's already some kind of normalized message.
So, maybe we could just do
```rust
impl TryFrom<T> for BookL1Update
where T: data_feed_definitions::demo::traits::Mbp1BookUpdate {
    // ...
}

impl TryFrom<T> for TradeUpdate
where T: data_feed_definitions::demo::traits::Trade {
    // ...
}

```

### Symbolic Topics
We're only going to handle the Book, Trade, AccountUpdate

### Trading Context
dsl-runtime/crates/dsl-runtime-nodes/src/trading_context.rs:37
The trading context should not own the trackers nor the mkt info repo. It should be created before calling the strategy handler
```
#[derive(Serialize, Deserialize)]
pub struct TradingContext<'a, M: market_info_repo::repository::MarketInfoRepository> {
    // Balance tracker
    pub balance_tracker: &'a mut MultiAccountBalanceTracker,
    // Position tracker
    pub position_tracker: &'a mut MultiAccountPositionTracker,
    // Last updates
    pub last_updates: &'a LastUpdateRepo,
    // Market info repository
    pub mkt_info_repo: &'a M,
}
```


### Ingress
Let's resolve

---

## Requirements
- plain technical English with no jargon
- max 300 words per reply (excluding code)

## Context
I want to fix the historical data ingress [ArrowFileProvider](dsl-runtime/src/hist_data.rs:160) for ./structure-strat-template-core with the minimum refactoring required to ship for a demo.
We already leverage the [data feeds](knowledge-base/docs/references/data-feed.md) in the [StratComponentHost::on_feed_msg](structure-strat-template-core/src/component.rs:422)


### Current state
The current historical ingress producer assumes that the mkt data is stored in the apache arrow format and the events are encoded as protobuf.
However, we're going to use the databento historical mkt data from [historical api](https://databento.com/docs/api-reference-historical?historical=rust&live=rust&reference=rust).
We'll download the files into the buckets. I don't know the hierarchy yet. We either store it per feed, which already includes the id, revision and events in it.
Or we store it per instrument, per event, or something else - TBD. There is a sample of the download job in prototypes/replay/src/bin/download_sample.rs:33.
The [StratComponentHost::on_feed_msg](structure-strat-template-core/src/component.rs:422) already handles the data feed object. Therefore,
ideally, the [HistTickData](dsl-runtime/src/hist_data.rs:109) should only include the bytes, timestamp and data feed ref.

We're going to store the files in a GCS bucket and run the backtest in a cloud run job. I think it's

The strategy in StratLiveDataState::on_nats_message matches the subject with the resolved symbolic topic,
and then parses the message as a protobuf message and passes it to the logic in
structure-strat-template-core/src/engine_state/strat_logic/common.rs

The strategy code assumes only Drift or Hyperliquid protobuf messages.
It then creates a union (enum) type with all the messages and passes it to the strategy source event handlers.

### Desired state
We've recently created a notion of [data feeds](knowledge-base/docs/references/data-feed.md) and there are some built already in
data-feed-definitions/rust/crates/data-feed-definitions/src/demo/databento_mbo_feed.rs,
data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs.

Based on the data feed idea, for every message there is a dedicated handler function that is called.
That handler, then, calls into the strategy source event handler or does some other logic.

## Tasks
do NOT change the backtest historical replay, ingress or egress managers. We're only fixing the component.
The tasks below are checkpoints for the data feed integration into the strategy logic.
You'll need the following feeds
```
data-feed-definitions = { git = "ssh://git@github.com/stxr-prop/data-feed-definitions.git", branch = "main" }
sim-venue-feed-codec = { package = "data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0", git = "ssh://git@github.com/stxr-prop/data-feed-definitions.git", branch = "main" }
databento-mbo-feed-codec = { package = "data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d",  git = "ssh://git@github.com/stxr-prop/data-feed-definitions.git", branch = "main" }
```


---

There are a bunch of changes to the structure-strat-template-core and I want to test it.
Build me a strategy in structure-strat-template-core/strats/flip-positions that trades every second by flipping its position.
You can use the `stxrc` to canonicalize it (dsl-processor-core/crates/stxrc).

The guide for building the strategies is in the dsl-processor-core/docs/dsl-beginner-guide.md, dsl-processor-core/docs/dsl-reference.md, dsl-processor-core/docs/dsl-spec.json.
This strategy should be fairly small and simple.
For the arguments, the instrument I want to trade is `inst_6NBRBWR34WAN4` from (market-info/assets/markets.csv:55) ESU2026.
The trading account can be arbitrary, just put 0 in there.
Ideally, through the stxrc compiler you should be able to produce the canonical strategy and the runtime config. If not, you can copy the structure-strat-template-core/mnt/local_dev/strat_config.yaml

For now, I just  want you to produce a strategy, but don't compile it in, yet, since the backtest is not ready.


