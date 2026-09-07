
sim-gw/src/market_info_repo.rs
is currently using a shitty version.
I've built a proper one in market-info/crates/market-info-repo/src/repository.rs
Additionally, the data shoudl be loaded from the market-info/assets/market-info.rkyv file (see databento-mkt-data/rust/crates/databento-mkt-data-server).
do NOT copy the style of the databento-mkt-data-server implementation. Follow the ideas established in sim-gw.

I need you to use the new market info repo and load the data from the config.

Give me a plan of actions for the implementation
