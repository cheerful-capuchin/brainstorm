# Future Market Trait Implementation Report

Date: 2026-08-30

## Implemented Contract

The `market-info` trait hierarchy now models derivatives directly:

```rust
pub trait DerivativeMarketTrait: MarketInfoTrait {
    fn underlying(&self) -> &Underlying;
    fn settlement_asset(&self) -> &Asset;
    fn quote_unit(&self) -> QuoteUnit;
    fn settlement_qty_per_quote_unit(&self) -> Decimal;
    fn contract_id(&self) -> ContractId;
}

pub trait PerpMarketTrait: DerivativeMarketTrait {
    fn funding_asset(&self) -> &Asset;
}

pub trait FutureMarketTrait: DerivativeMarketTrait {
    fn trading_termination_time(&self) -> NanoTimestamp;
    fn settlement_method(&self) -> &FutureSettlementMethod;
}
```

The former blanket forwarding implementation was removed. `PerpMarketInfo`,
`DriftPerpMarketInfo`, `HlPerpMarketInfo`, and the market-info mock now
implement `DerivativeMarketTrait` explicitly. `PerpMarketTrait` contains only
the perpetual-specific funding capability.

`Underlying` is the only derivative-underlying name. Existing source,
generator, and generated-catalog references were renamed from
`PerpUnderlying`. There is no compatibility alias and `Underlying` has no
helper-method implementation; consumers distinguish `Asset` and `Ticker` by
pattern matching.

All futures lifecycle fields use `time::NanoTimestamp`:

- `trading_termination_time`;
- `final_settlement_time`;
- `first_notice_time`;
- `last_delivery_time`.

`MarketInfoType` and the `MarketInfo` enum remain spot/perpetual only. No future
associated type, accessor, dispatch closure, or enum variant was introduced.

## Verification

No test cases were added or run. The existing market-info mock implementation
was split across the derivative and perpetual traits with the production
implementations.

- `cargo check --offline -p market-info`: success with existing warnings.
- Targeted `rustfmt --check`: success.
- `git diff --check`: success.
- `trade`, `trade-core`, `trade_v2`, and Coin API compile across all targets.
- `strats_v2` compiles across all targets with its binary feature.
- `dsl-runtime`, `marketdata`, and `client-core` compile.

## Consumer Migration

Downstream consumers now import `DerivativeMarketTrait` when they use
underlying, settlement, multiplier, or contract capabilities. This includes
portfolio valuation, trade fixtures, Coin API generation, target-executor test
support, and backtest artifact projection.

Consumers of asset-backed underlyings now pattern-match
`Underlying::Asset`. Generic consumers explicitly handle
`Underlying::Ticker`; test repositories return `false` for ticker-backed
markets when filtering by asset id.

The backtest post-processor was updated by inspection. Cargo cannot check it
from this workspace because the package is neither a workspace member nor
listed in `workspace.exclude`.
