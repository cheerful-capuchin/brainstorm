Read:
- market-info/README.md
- market-info/crates/market-info-store/README.md

Context:
- generated hyperliquid mkt info: generated/hyperliquid/market_info/hl_market_list.rs
- hyperliquid mkt info generator: market-info/crates/hl-market-list-gen/src

I want you to update the generator to generate the entities in the market-info/assets/markets/hyperliquid/{instrument_type} as Ron entities, instead of rust code in hl_market_list.rs.
Ideally, you should do a merge instead of a simple replacement. So, we don't override the properties that the user has defined by themselves, like display name.

So, I guess, in the beginning of the program you read the existing market info into some in-memory representation.
Then, you fetch the hyperliquid info
You have some kind of merge function that updates the existing entities, and then you overwrite the files and create the new ones.

Give me an action plan
