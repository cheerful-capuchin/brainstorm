## Context
We're building the paper trading and backtesting for our trading strategies framework.
Currently, I want to organize the venue simulator. We support cme, cbot, nymex and comex.
Each venue, has its own project in infra/infra/projects.ts and a dedicated github repo
- github.com/stxr-prop/cme
- github.com/stxr-prop/cbot
- github.com/stxr-prop/nymex
- github.com/stxr-prop/comex

For the demo purposes, all those venues are going to have the same logic - always fill the order.
I suppose there will be more reusable logic in the future, so I created the https://github.com/stxr-prop/venue-core repo.
The venue-core will have `venue-core/rust/crates/venue-simulator` crate that will include this common logic.
The idea is that the [sim-gw](sim-gw/src/main.rs) and the [backtest](structure-strat-template-core/src/backtest/host.rs) will
reuse those simulated venues, so the paper trading on live mkt data and the backtest have the same matching and accounting logic.

The directory structure is already laid out as {venue}/rust/crates/{venue}-venue-simulator, but there are no crates yet.
Same with venue core, `venue-core/rust/crates/venue-simulator` direcotry exists, but it's not a crate.

### Structure
The venue simulator will have the matching and accounting engine.
Matching handles the orders, accounting engine handles the positions.

### Position Tracker
We already have a prototype for the position tracker in prototypes/position-tracker/src/tracker_traits.rs.
There are 2 existing subpar implementations in trade/crates/trade-core/src/position/tracker.rs and trade_v2/src/position.rs.
I don't want to replace them yet, therefore, I would use the position tracker from the prototype in the `venue-core/rust/crates/venue-simulator`.

### Order Book
For now, the venue simulator doesn't need any order book or any mkt data in general. We get an order, fill it, create the fill event,
probably pass the fill to the accounting engine, update the trading accounts' positions. Emit the trading account position update.

### Deposit + Withdrawal
We need to handle the deposits and withdrawals properly and emit them as events, together with the updated trading account positions.

### Fees
we do NOT model any fees

## Questions

### 1. What is the best organization of the venue simulators?
I do NOT think those should be standalone [engine components](dev-docs/frameworks/engine-application-framework.md).
Rather, those should be modules that will be plugged into something like sim-gw or backtest sim venue.
What are your thoughts when it comes to the organization, specifically, when it comes to the topology of the venue simulator.
I mentioned that it's a matching engine and accounting engine, but I've never built a proper venue simulator or any venue itself,
therefore, I want to understand what comes into having a venue.
What's the structure of CME or CBOT or any other popular exchange?







todo:
- create all the repos {venue}/rust/crates/{venue}-venue-simulator
- have the logic for the simulation that handles the realized pnl properly in the venue-core
- each venue has it's own logic for handling the orders and accounting, but for now they all call into the venue-core repo
- move the sim gw and the backtest sim to use those sim venues
- no fees
- rebuild the strategy to buy the bid and sell the ask and earn on spread
- reduce the slippage in the backtest config
