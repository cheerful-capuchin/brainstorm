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

`MarketInfoType` is now three-way. It exposes `FutureType`, `as_future()`, and
a third `dispatch` closure. `MarketInfo` and `MockMarketInfo` both carry a
`Future(FutureMarketInfo)` variant, and every delegated `MarketInfoTrait`
accessor handles it exhaustively.

`FutureMarketInfo` is intentionally an uninhabited closed enum at this stage.
No concrete CME market-info implementation or static future record exists yet,
so this shape exposes the final dispatch contract without inventing market
data. A future venue implementation will become a variant of this wrapper.

## Verification

No test cases were added. The existing market-info mock implementation was
split across the derivative and perpetual traits with the production
implementations, and its market-type dispatch surface was expanded to accept a
future closure.

- `market-info` `just check`: success; 46 tests passed.
- `cargo check --all-targets` for `trade_v2`: success.
- `cargo check --all-targets` for `sim-gw`: success.
- `cargo check --all-targets` for `trade-core`: success.
- `cargo check --all-targets` for Coin API: success.
- `cargo check --all-targets --features binary` for `strats_v2`: success.
- `backtest-post-processor` cannot be checked directly because Cargo considers
  it part of the root workspace while the root manifest neither includes nor
  excludes it.
- `git diff --check`: success.

## Consumer Migration

Downstream consumers now import `DerivativeMarketTrait` when they use
underlying, settlement, multiplier, or contract capabilities. This includes
portfolio valuation, trade fixtures, Coin API generation, target-executor test
support, and backtest artifact projection.

Consumers of asset-backed underlyings now pattern-match
`Underlying::Asset`. Generic consumers explicitly handle
`Underlying::Ticker`; test repositories return `false` for ticker-backed
markets when filtering by asset id.

Three-way dispatch was applied to the generic repositories, Drift indexes,
Hyperliquid asset collection, `trade_v2` fixtures, trade fixtures, the
simulation gateway, and the backtest artifact projection. Shared derivative
operations use the future's contract id, settlement asset, and asset-backed
underlying; ticker underlyings remain absent from asset indexes.

The position tracker stores futures by instrument alongside perpetual
derivatives. Coin API uses a future's contract id and settlement asset for
resolution and coverage, while its perpetual-specific quote-record generator
continues to report futures as unsupported until a CME symbol mapping exists.
Target-executor repository helpers resolve future contract ids and
asset-backed underlyings explicitly.
