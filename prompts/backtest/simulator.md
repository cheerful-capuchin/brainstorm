## Context
I want to hot fix our current venue simulator in the [backtest](structure-strat-template-core/src/backtest/host.rs).
It's not calculating the realized pnl and not updating the spot asset balance.
Based on the [settlement asset](market-info/src/market_info.rs) you know how to convert the quote unit and what an asset is.
Therefore, when we partially close the position, we should realize the pnl. For the cost-basis, use the average price.

Then, spawn a workflow, to fix the backtest post-processor to write the data to a duck db database, instead of sqlite in backtest-post-processor/src/egress.
The schema is already defined in DEC-0AB71 and in the prototypes/accounting/db/backtest.duckdb, I think.
I don't think we need the price sampler in the backtest post-processor.


