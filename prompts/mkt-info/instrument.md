## Context

The current implementation of the instrument is wrong. Specifically, the `pub struct Instrument` (The type market-info-core/rust/src/entities/instrument.rs).
The problem is that it tries to reuse the common fields and build the unique id from them.
However, different instruments have very different configurations.
For example, we have an issue right now with the CME instruments.
The CME symbol is not globally unique, but only within a decade.
so ESU6 (E-MINI S&P 500 FUTURES for September). Can be for 2006, 2016, 2026, 2036, etc.
Security ID is also not globally unique. It's only the combination of symbol, security id and trading date that give us uniqueness.
Hyperliquid may have it's own rules, same with everything else.

I think our instrument id should be more like the entity-core/crates/entity-core/src/entities/trading_account.rs.
Where you have different types of the trading accounts, all of them have different ways to compute the id and all of the variants implement the trait.

The Instrument type is actively used in the MarketInfo trait `market-info/src/market_info.rs`.
An instrument could be a spot asset or a derivative contract (perp, future, option, etc).

How would you change the instrument type and market info trait?
What is the blast radius of this change.
Spawn subagents to analyze.
