# Future Instrument Type Implementation Report

Date: 2026-08-30

## Scope

`FUTURE` was appended to the shared instrument-type discriminators without
changing `MarketInfoType`. Existing `SPOT` and `PERP` numeric values remain
unchanged. Rust, TypeScript, Python, and protobuf representations were updated.

No tests were added. The instrument repository, positions repository,
portfolio history repository, Coin API, and target executor were not changed as
part of this work.

## Excluded Binary Assumptions

The excluded Structure Web repositories still recognize only spot and
perpetual instruments:

- `packages/api/src/instruments/instruments-repository.ts:162-197` rejects a
  future wire value on decode and cannot encode `Instrument.Type.Future`.
- `packages/api/src/positions/positions-repository.ts:460-468` rejects a future
  wire value as `unknown_instrument_type`.
- `packages/api/src/portfolio/portfolio-history-repository.ts:671-679` rejects
  a future wire value as `unknown_instrument_type`.

These are deliberate follow-up sites, not implementation defects fixed in this
change.

Coin API has no direct exhaustive match over `InstrumentType`; it remains
limited by the unchanged spot/perpetual `MarketInfoType` accessors. The target
executor likewise has no newly failing exhaustive instrument-type match. Its
binary compiled successfully with the new discriminator and was not modified.

## Permitted Consumer Classification

Permitted consumers were handled according to their boundary semantics:

- shared position and order calculations classify futures with perpetuals as
  derivative instruments;
- common and market-info wire conversions preserve the new discriminator;
- Drift-specific conversions reject futures explicitly instead of silently
  treating them as perpetuals;
- Hyperliquid protobuf glue preserves the discriminator without claiming
  venue support.

## Verification

Targeted `cargo check` runs passed for the changed core, messaging, wire,
client, trade, trade-v2, DSL runtime, marketdata, Hyperliquid market-info, and
excluded target-executor packages.

`structure-md-server-bin` could not be checked independently because Cargo
reports that the package believes it belongs to the workspace but is not a
workspace member. This is a pre-existing workspace configuration problem; the
three exhaustive matches in that package were updated by inspection.
