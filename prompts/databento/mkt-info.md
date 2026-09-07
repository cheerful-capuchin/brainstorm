strats_v2/src/target_executor/feed/symbols.rs
structure-strat-template-core/src/feed.rs
databento-mkt-data/rust/crates/databento-mkt-data-server/src/application/use_cases/plan_dataset_subscription_use_case.rs:34

In all three of these cases, there is some mapping between our instrument symbol and the databento one.
I don't like this, since we're speculating here, and then we start having exceptions like databento-mkt-data/rust/crates/databento-mkt-data-server/src/domain/raw_symbol.rs:30

How can we use the security id from the CME markets?

This is not good. Therefore, I want to understand why our symbols do NOT match the databento ones and which symbols are used by CME?

Our mkt info is generated in market-info/assets/markets, like market-info/assets/markets/cme/future/ESU2026.ron.
AFAIK

We have the source file in market-info/crates/cme-market-info-gen/assets/cme-futures-v1.json | jq .markets
I assume that file was created using market-info/crates/cme-market-info-gen/src/main.rs

What I don't understand is why there is a distinction between "symbol" and raw_symbol in that json file

---
## Context
We need to update our CME market info generator market-info/crates/cme-market-info-gen/README.md
The source files are in the market-info/crates/cme-market-info-gen/assets.
They don't match in date, but I don't think that's a problem. It's a one-day diff.

## Tasks

### Ron instead of JSON
The program should read the existing data in market-info/assets
and merge the data in the .ron files with the data derived from the security definition + fprf.
Do not overwrite the "display_name" I would say
Currently, the output is to the JSON file in market-info/crates/cme-market-info-gen/assets/cme-futures-v1.json

### Different structure
[CmeFutureMarketInfo](market-info/src/market_info/cme.rs:45) requires the security_id and instrument symbol.
The current json file doesn't include the security id and uses the wrong symbol for the instrument.




