## Requirements
- do NOT edit any files
- max 300 words per rely (exluding code)
- more Rust code, less English prose.

## Context
The strategy deployment needs additional feeds.
See knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md.
I think that each event i.e., runtime event, target positions, triggering source event should be in its own feed.
I've already designed and integrated the target positions feed data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs.

## Tasks

### Update the feed definitions
in data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs, instead of having
```
pub static STRATEGY_DEPLOYMENT_FEED
```
We'll have a feed per event kind:
- strategy deployment target positions feed
- strategy deployment triggering source events feed
- strategy deployment runtime events feed


The consumers of those feeds are:
- target position executor (target positions only)
- event gw (runtime event, target positions, triggering source event)

Each of them has their own handlers, and there is NO single Strategy Deployment Feed handler.

### Codecs
The current codec in .cargo/config.toml
```
strategy-deployment-target-position-feed-codec = { package = "data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5", path = "./data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5" }
```
Only defines the target positions feed. Therefore, we need 2 more protobuf codecs.

### Event GW | Triggering Source Events
handlers: event-gw/crates/event-gw/src/handler.rs (must add)
table: FeedTable::FeedEvents + TriggeringSourceEvents
Needs logic in: event-gw/crates/event-gw/src/logic/triggering_source_events.rs
Ideally, you follow the patterns established in event-gw/crates/event-gw/src/logic/sim_venue/fills.rs

### Event GW | Runtime Events
handlers: event-gw/crates/event-gw/src/handler.rs (must add)
table: FeedTable::FeedEvents + [event_logs](event-gw/crates/db/clickhouse/schema.sql:348) needs addition

Source: [strategy_deployment::StrategyDeploymentSource](strategy-core/rust/src/telemetry.rs)
Subject: I think we need to define something similar to strategy-core/ts/src/entities/strategy_revision/strategy_revision.ts, but in strategy-core/rust/src/entities/strategy_revision.rs + strategy-core/rust/src/entities/strategy_deployment.rs,
so we serialize things properly

I think we need a new logic module in event-gw/crates/event-gw/src/logic/runtime_events.rs
Ideally, you follow the patterns established in event-gw/crates/event-gw/src/logic/sim_venue/fills.rs


## Questions

### 1. How do we define the "subject" and "source" in rust modules, so that it translates to typescript
Details: e.g. strategy-core/ts/src/entities/strategy_revision/strategy_revision.ts
A: like strategy-core/rust/src/subject.rs + strategy-core/rust/src/entities/strategy_deployment.rs
For now, no typescript translation, it's tech debt

### 2. is using `fn properties(&self) -> impl ExactSizeIterator<Item = (&str, &str)>;` for RuntimeEvent a good decision?
A: yes, stick with it

### 3. How does the strategy template core emit the necessary events?
Details: structure-strat-template-core/src/lib.rs

---
- max 300 words per rely (exluding code)
- more Rust code, less English prose.


## Requirements
- do NOT edit any files
- you reply must be structured as it a set of a logical statements, maybe using the codebase-explorer stack structure would be easier

## Context
The strategy deployment has multiple feeds data-feed-definitions/rust/crates/data-feed-definitions/src/demo/strategy_deployment_feed.rs.
According to knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md, we need to do some accounting in the event gw to persist all the necessary state.
I have been prototyping some things in prototypes/accounting/bin/deployment_feed.rs. However, they may not be correct.
For the demo sake, we'll assume that the events will arrive in order and will not be lost. We're going to have like 10 strategies, it's going to be fine.

Call stack (what exists):
```
EventGwHost::on_nats_msg / on_pubsub_data_feed_msg  [decode, persist]   host.rs:121, host.rs:301
  -> EventGwHandler::on_feed_msg  [one payload, one engine clock]   handler.rs:107
     -> FeedCodecs::consume  [dispatch by FeedCodecKind]   feed.rs:369
        -> FeedMsgHandler::*  [trait impls]   handler.rs:305–543
           -> store_feed_event <writes><emits feed_events row>  [raw bytes + ingestion_orderand]   handler.rs:239
              -> IngestionOrderandSource::next_orderand  [time+bump, no restart state]   orderand.rs:31
           -> EventGwState::handle_target_positions / handle_triggering_source_event / handle_runtime_event
              <writes target_positions | triggering_source_events | event_logs>   state/running.rs
           -> EventGwState::handle_fill / handle_demo_only_fee / handle_deposit / handle_withdrawal / handle_trading_account_position_update
              <writes fills | demo_fees | deposits | withdrawals | position_updates>   handler.rs:392–543
           -> flush_if_required <defers ClickHouse insert>  [byte/timer batch, not reorder]   handler.rs:221
```

Call stack (what DEC-0ADYZ still requires):
```
economic event already in feed_events + semantic table
  -> bounded reorder buffer <defers fold>  [grace period; durability already done]
     -> fold at (effective_time, frontier_orderand)
        -> Position / cost-basis engine <writes>  [qty, avg entry, realized PnL]
           -> Fill: same-sign re-average; reduce realizes (exit−entry)×closed×sign; zero-cross splits
           -> DemoOnlyFee: cumulative fees, never into avg entry
           -> Deposit / Withdrawal: change spot-asset quantity (DEC-09S6G); not in prototype
           -> PositionUpdate: store as observed drop-copy; do not mix into fill fold
        -> Turnover engine <writes account_trading_volume>  [base volume + quote turnover]
        -> persist account_position_aggregate / account_trading_volume
Valuation engine is not this write path: client fetches prices; unrealized PnL is read-time
```

Logical statements
1. StrategyDeploymentEvent is three feeds: TargetPositions, TriggeringSourceEvent, RuntimeEvent (strategy_deployment_feed.rs:124–131). None of them change quantity, cash, or PnL.
2. Economic facts for a live deployment arrive on SIM_VENUE_FEED: Fill, DemoOnlyFee, Deposit, Withdrawal, TradingAccountPositionsUpdate (sim_venue_feed.rs:259–270).
3. Event-gw already dual-writes every decoded payload: feed_events.raw_event plus one semantic table, sharing event_id and ingestion_orderand (handler.rs:234–264).
4. DEC-0ADYZ accounting is the fold of those economic rows into account_position_aggregate and account_trading_volume, not a fourth strategy-deployment feed.
5. DEC-09S6G names four engines; the demo implements two of them in the gateway: position/cost-basis and turnover. Valuation is stateless and needs live prices. The ledger is deferred.
6. Fees never enter average_price. Realized price PnL is independent of fees (DEC-09S6G:126–134). The prototype PositionState::apply_fill / apply_fee matches that split (deployment_feed.rs:269–329).
7. Event-gw has no fold, no aggregate writer, and no reorder buffer. ingestion_orderand is arrival order, not fold order (orderand.rs:1–9).
8. prototypes/accounting/bin/deployment_feed.rs is a batch projector of one Hyperliquid feed.rkyv. It is not a streaming multi-feed fold.

## Tasks

### Let's divide this goal into the logical subtasks
This is quite a vast goal, and I would like it to be divided into the subtasks. Each node has at most 3 children. The nodes do not represent files or functions. Instead, those are
logical pieces. How would you subdivide the work into the well-defined tasks?

----

I want to rewrite the paragraph `Bounded reordering buffer` in knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md:95

We'll for sure have a case when the events arrive late. It's just a given. We have the same problem with persisting the mkt data.
There, our idea was to have a background job that reorders the entries once we're 99% sure that there will be no data.
For example, in traditional markets, we know that after 4 p.m. there is no more trading activity. This means that there will be no new events coming in.
This is our signal to start reordering.
When it comes to economic events like fills and deposits, our signal could be the target positions snapshot. The positions update uses the same orderand as the rest of that venue's feed.
We should be able to reconcile the deltas between snapshot at orderand_0 and orderand_1 and disard the economic events from the buffer and flush.




