# CME Futures Market Info DEC Blast Radius

Date: 2026-08-30

Decision under review:
`knowledge-base/docs/decisions/records/DEC-0AFBN-cme-futures-market-info.md`

## Purpose

This report answers two questions:

1. What happens if Structure introduces the proposed futures market-info trait?
2. What happens if `MarketInfoType` changes from spot/perpetual dispatch to
   spot/perpetual/future dispatch?

The intended audience is engineers reviewing the decision and planning its
implementation. The report separates direct source breakage from behavioral
work because the compiler can find missing match arms, but it cannot decide
whether a future should be valued, rejected, settled, or accidentally treated
as a perpetual.

This is a static blast-radius analysis, not a temporary-enum compile probe. It
combines direct workspace inspection with three independent GPT-5.6 Luna
reviews covering the trait change, the market-type change, and the architecture
decision checklist. Counts and file locations describe the workspace as
inspected on the date above. Inferences are labeled where they go beyond direct
source evidence.

### Assumptions

- The four existing CME Group venue values remain unchanged.
- Existing `SPOT = 0` and `PERP = 1` discriminants, protobuf tags, the
  instrument-ID seed, and the hash algorithm remain unchanged.
- The proposed scope is market information for dated futures; options and live
  CME execution are separate work.
- No future record is currently present in the production static market-info
  catalog.
- The DEC's proposed trait and enum shapes are still open to revision because
  the decision status is `proposed`.

### How to use this report

Use the subsystem sections as an impact inventory, the migration sequence as a
rollout outline, and the final questions as acceptance gates for the DEC. Before
implementation, convert each affected subsystem into owned tasks and verify the
static findings with compile probes and compatibility fixtures. Do not treat a
restored build as proof of correct future behavior: every new arm must be
classified as shared derivative behavior, future-specific behavior, or an
explicit unsupported error.

## Executive Summary

The four CME Group venues are already modeled. `Cme`, `Cbot`, `Nymex`, and
`Comex` have stable domain and protobuf identities, so this decision does not
need another venue migration.

The blast radius comes from five other changes that the DEC currently bundles:

1. introduce common derivative and future-specific traits;
2. add a concrete future market-info family to the catalog;
3. expand `MarketInfoType` and `MarketInfo` from two variants to three;
4. add `FUTURE` to the shared `InstrumentType` discriminator;
5. expand `QuoteUnit`, settlement data, and the corresponding wire contracts.

The impact depends on what "introduce the trait" means:

| Change | Immediate effect | Operational result |
|---|---|---|
| Add only `FutureMarketTrait` | Small source change; no existing implementor must change | Inert. Futures cannot enter today's `MarketInfo`, repository, static catalog, or two-way dispatch. |
| Add `FutureMarketTrait` plus `DerivativeMarketTrait` extraction | Existing perpetual implementations and bounds must move shared methods | Perpetual semantics can remain unchanged, but this is a source-breaking API refactor. |
| Wire futures into `MarketInfoType` and `MarketInfo` | Every implementation, delegation match, and two-way dispatch must be revisited | Futures become discoverable through the repository, but consumers still need explicit behavior. |
| Add `InstrumentType::FUTURE` and publish it | Broad cross-repository enum and protocol migration | Old consumers may reject, drop, or misroute future records. |

The decision should remain proposed. Its direction is coherent, but the wire
shape, lifecycle invariants, identity policy, catalog provenance, compatibility
plan, settlement behavior, observability, and replay model are not yet complete.

## What Is Already Available

### Venue identity

`market-info-core/rust/src/entities/venue.rs` already defines:

- `Venue::Cme`;
- `Venue::Cbot`;
- `Venue::Nymex`;
- `Venue::Comex`.

Their stable primitive values are 9 through 12. The same values exist in
`messaging/msg-schemas/proto/market-info/market_info.proto`, and
`market-info/crates/market-info-wire/src/conversion.rs` already converts them
in both directions.

Consequences:

- no new venue variants are required;
- no venue values should be renumbered;
- no venue serialization migration is required;
- venue-only routing, formatting, and identity code is not part of this
  change unless it also branches on instrument type;
- existing spot and perpetual instrument IDs remain stable if their existing
  discriminator values and all other hash inputs stay unchanged.

A venue value is only an identity. It does not provide market data, calendars,
accounts, margin, orders, execution, settlement, or risk support.

### Existing generic market facts

`MarketInfoTrait` already carries tick size, quantity constraints, precision,
listing status, and the instrument. These fields can represent whole-contract
quantities and venue-native prices without changing their Rust types.

`ListingStatus` also remains usable as the current listing state. It cannot
replace future lifecycle timestamps because it contains neither transition
history nor the scheduled trading-termination instant.

## Question 1: Introducing the Futures Trait

### Trait-only introduction

Adding this definition by itself is low blast radius:

```rust
pub trait FutureMarketTrait: DerivativeMarketTrait {
    fn trading_termination_time(&self) -> NanoTimestamp;
    fn settlement_method(&self) -> &FutureSettlementMethod;
}
```

No current type implements it, and existing consumers are not bounded by it.
The trait would therefore compile without changing runtime behavior.

It would also be unusable through the primary abstraction. Today's
`MarketInfoType` exposes only `SpotType`, `PerpType`, `as_spot`, `as_perp`, and
a two-closure `dispatch` in `market-info/src/market_info.rs:91-111`. The
repository's associated market-info type is consequently unable to return a
future through the current sum type.

This is a useful staging option, but it does not deliver CME future market info.

### Extracting `DerivativeMarketTrait`

The current `PerpMarketTrait` owns the following facts:

- underlying;
- settlement asset;
- quote unit;
- settlement quantity per quote unit;
- funding asset;
- contract ID.

The proposal moves every item except funding into `DerivativeMarketTrait`.
That changes the implementation structure for:

- `PerpMarketInfo` in `market-info/src/market_info.rs`;
- `DriftPerpMarketInfo` in
  `market-info/src/market_info/drift/drift_mkt_info.rs`;
- `HlPerpMarketInfo` in `market-info/src/market_info/hyperliquid.rs`;
- the mock perpetual market info in `market-info/src/market_info.rs`.

Existing perpetual values do not need semantic changes: their quote-unit scale
is zero, their funding asset remains on `PerpMarketTrait`, and their common
facts move to the new supertrait. Generic consumers that currently use
`PerpMarketTrait` only for settlement, multiplier, underlying, or contract ID
should eventually widen to `DerivativeMarketTrait`.

The refactor is nevertheless source-breaking for implementations, imports,
trait bounds, documentation, mocks, and fixtures.

### Renaming `PerpUnderlying` to `Underlying`

The rename is conceptually correct because futures and perpetuals share the
underlying concept, but it is a broad source-level rename. References exist in:

- the market-info wrapper, Drift and Hyperliquid implementations;
- the Hyperliquid static-market generator and generated catalog;
- market-info tests and mocks;
- trade and trade-v2 fixtures;
- messaging protobufs and generated Rust, TypeScript, and Python code;
- backtest feed decisions, specifications, and execution plans;
- Hyperliquid design documentation.

Compatibility option: introduce `Underlying` internally while temporarily
keeping `PerpUnderlying` as a Rust alias/conversion and preserving the existing
protobuf message name. The domain and wire rename do not have to occur in the
same release.

### Expanding `QuoteUnit`

The current domain type at
`market-info-core/rust/src/entities/quote.rs:7-11` contains only:

```rust
QuoteUnit::Asset { asset_id }
```

The DEC proposes:

```rust
QuoteUnit::Asset { asset_id, scale_exponent }
QuoteUnit::IndexPoint { ticker }
QuoteUnit::ParPoint
```

Direct source effects:

- every `QuoteUnit::Asset` constructor gains `scale_exponent`;
- every match must tolerate the two new variants;
- the Hyperliquid generator must emit scale zero;
- the generated Hyperliquid catalog must be regenerated;
- the quote-unit protobuf and all generated language bindings must change.

The inspected generated Hyperliquid catalog contains 232 explicit
`QuoteUnit::Asset` constructions. This is generated churn rather than 232
independent design decisions; the generator should be fixed first and the
catalog regenerated.

Semantic risk: the multiplier must remain the sole notional/P&L conversion
input. If a consumer applies both `scale_exponent` and the already-scaled
multiplier, ZC is double-scaled. The DEC states this intent, but the invariant
needs tests and wire documentation.

### Execution remains unsupported

`strats_v2/src/target_executor/venue_trade_specs.rs:578-614` currently supports
Drift and Hyperliquid and returns an unsupported-feature error for the four CME
venues. Therefore the metadata change does not enable live trading.

Separate work remains for:

- CME market-data ingestion and product/calendar reference data;
- account and clearing models;
- order and execution-report conversion;
- trading sessions and halts;
- margin and daily variation settlement;
- final settlement price ingestion;
- first-notice risk and forced flattening;
- physical-delivery prevention;
- contract roll behavior.

## Question 2: Changing `MarketInfoType`

### Direct Rust API breakage

The proposed trait adds:

- associated type `FutureType`;
- `as_future()`;
- a third closure parameter to `dispatch`.

In the current production market-info crate, direct inspection found:

- two `MarketInfoType` implementations: `MarketInfo` and `MockMarketInfo`;
- twelve direct `.dispatch(...)` calls across market-info and the backtest
  artifact consumer;
- repeated exhaustive delegation over `MarketInfo::{Spot, Perp}` for every
  `MarketInfoTrait` accessor.

All of these require source changes. The main locations are:

- `market-info/src/market_info.rs`;
- `market-info/src/market_info/mkt_info_repo.rs`;
- `market-info/src/market_info/drift/drift_mkt_info_repo.rs`;
- `market-info/src/asset/hl_assets.rs`;
- `backtest-post-processor/src/artifact.rs`.

Adding a third closure is intentionally a compiler tripwire, but each new arm
needs a semantic classification:

| Existing operation | Appropriate future behavior |
|---|---|
| Generic instrument lookup | Include futures. |
| Contract-ID lookup | Include futures as derivatives. |
| Spot pair lookup | Exclude futures. |
| Underlying asset index | Include only asset-backed underlyings; CME ticker underlyings produce no asset key. |
| Settlement-asset collection | Include futures. |
| Funding-asset collection | Perpetual only. |
| Drift oracle indexes | Explicitly reject/ignore futures; do not invent a Drift oracle. |
| Hyperliquid generated-asset scan | Future arm should be unreachable for the HL-only source, or the operation should be generalized and renamed. |
| Backtest market facts | Include common derivative facts, then separately handle future termination and settlement. |

### `MarketInfo` sum type

The concrete enum must gain `MarketInfo::Future(FutureMarketInfo)`. Every
delegated accessor in `MarketInfoTrait` then gains a future arm, as do direct
matches in market-info asset repositories, market-data senders, oracle code,
tests, fixtures, and downstream services.

The wrapper also needs a concrete venue implementation. A single CME Group
implementation may be sufficient if venue differences remain entirely in the
embedded `Instrument::venue`, but that is an explicit design choice rather than
a consequence of having the four venue enum values.

### `InstrumentType` is a wider, separate migration

The DEC also adds `InstrumentType::FUTURE = 2`. This is not merely an
implementation detail of `MarketInfoType`; it is a shared discriminator used
by identity, serialization, APIs, execution, position logic, and generated
messages.

Current `market-info-core/rust/src/entities/instrument.rs` explicitly warns
that the values participate in deterministic hashing. Adding value 2 is safe
for existing IDs only if:

- `SPOT` remains 0;
- `PERP` remains 1;
- the instrument-ID seed and hash algorithm remain unchanged;
- existing symbols and venue values remain unchanged.

Inference: under those conditions, existing spot/perpetual IDs remain stable
and futures receive distinct IDs from `(contract-month symbol, FUTURE, venue)`.

Identity questions still unresolved by the DEC:

- Is a future `ContractId` always derived from `InstrumentId`, as current
  perpetual implementations do?
- Is that derivation a permanent invariant or a temporary 1:1 shortcut?
- Does correcting a contract symbol preserve identity or create a new contract?
- What is the canonical symbol grammar for each contract month?
- Are positions keyed by `ContractId`, `InstrumentId`, or both?

The living contract and position references say derivative identity is
contract-based, while current trade/trade-v2 implementations commonly key
positions by instrument. Futures expiry and replay expose that mismatch.

### Exhaustive-match compile breaks

Representative exhaustive branches that need future behavior include:

- `market-info-core/rust/src/entities/instrument.rs` — `Display` and tests;
- `market-info/crates/market-info-wire/src/conversion.rs` — domain/protobuf and
  numeric conversions;
- `messaging/rust/src/conversion.rs` — shared protobuf conversion and conversion
  to venue-specific market kinds;
- `client/crates/client-core/src/wasm.rs` — public WASM instrument type;
- `trade/crates/trade-core/src/position/tracker.rs` — spot balance versus
  derivative position handling;
- `trade_v2/src/position.rs` — position lookup/update routing;
- `trade_v2/src/order/manager.rs` — execution report behavior;
- `trade_v2/src/account_position_update.rs` — position-message conversion;
- `dsl-runtime/src/utils.rs` — spot/perpetual request construction;
- `marketdata/src/marketdata/drift/dlob_server_client.rs` — Drift market type;
- `structure-md-server-bin/src/md_sender.rs` — outbound type routing;
- Hyperliquid market-info and projection code that intentionally supports only
  spot/perpetual markets;
- Structure Web repositories that convert protobuf instrument types to the
  TypeScript domain type.

Venue-specific conversions cannot all gain a meaningful future arm. For
example, converting the shared `InstrumentType::FUTURE` to Drift's
spot/perpetual-only `MarketType` should become fallible or reject the value
before conversion. Mapping it to `Perp` would be incorrect.

### Compile-safe runtime hazards

Not every problematic consumer is exhaustive. Wildcards, `else` branches, and
binary predicates can compile after adding futures while doing the wrong thing.

Examples:

- `dsl-runtime/crates/dsl-backtest-runtime/src/exec_simulator.rs` treats
  `SPOT` specially and everything else as a derivative/perpetual execution;
- `sim-gw/src/state/ready.rs` contains a spot branch and a generic branch named
  as perpetual behavior;
- code that assumes `as_perp().unwrap()` after checking only "not spot" can
  panic for futures;
- filtering only `as_spot()` or `as_perp()` may silently omit futures from
  indexes, assets, responses, and snapshots;
- wildcard arms in venue-specific code may silently classify futures as an
  existing venue product.

Every such site should either gain genuine future behavior or fail closed with
an explicit unsupported-future error. A wildcard must not be accepted merely
because it restores compilation.

## Wire and Generated-Code Blast Radius

### Parallel schemas

At least three schemas carry overlapping market-kind information:

1. `messaging/msg-schemas/proto/common.proto`
   - shared/deprecated `Instrument` and `InstrumentType`;
2. `messaging/msg-schemas/proto/market-info/market_info.proto`
   - canonical market-info instrument type, quote unit, spot/perpetual payloads,
     and top-level market-info oneof;
3. `messaging/msg-schemas/proto/structure/market_info.proto`
   - Structure catalog snapshot/delta and venue-specific spot/perpetual oneofs.

The Hyperliquid market-info schema also carries the common instrument type. All
schema sources and generated bindings must agree on whether and where futures
are representable.

Required generated artifacts include:

- Rust protobuf and serde files under `messaging/rust/src/generated/`;
- TypeScript files under `messaging/ts/generated/ts/types/`;
- Python `*_pb2.py` descriptors under `messaging/python/messaging_py/`;
- downstream generated client declarations and API types.

Generated files should not be patched manually.

### Protobuf compatibility

Adding enum value 2 and new oneof fields is binary-additive if existing values
and tags remain unchanged. Existing spot/perpetual payloads continue to decode
with upgraded readers.

That does not make future publication backward-compatible:

- old enum converters can reject `FUTURE = 2`;
- old generated JSON/text converters do not know the new symbolic name;
- old readers cannot interpret a new future oneof arm;
- an old intermediary may decode a future with no recognized kind and discard
  its unknown payload when reserializing;
- business logic may default, omit, or return an unsupported-type error.

The rollout must upgrade readers before any producer publishes future records.

### Quote-unit wire hazard

The wire `QuoteUnit` currently contains `AssetId asset = 1`. The DEC specifies
the new Rust shape but not the protobuf shape or field numbers.

This is safety-critical. If an old reader can decode an asset quote while
silently ignoring a newly added non-zero scale, it will interpret ZC in dollars
instead of cents. The wire design must ensure one of the following:

- old readers reject scaled asset quotes;
- future/scaled quote units travel only over a versioned endpoint;
- publication is gated until every price-interpreting consumer understands the
  scale;
- another explicitly documented compatibility mechanism prevents silent use.

New oneof alternatives such as index point and par point can be assigned new
tags, but tag numbers, unknown handling, JSON names, and compatibility tests
must be part of the decision.

## Consumer Blast Radius by Subsystem

### Market-info repositories

Affected responsibilities:

- instrument lookup;
- contract-to-instrument lookup;
- underlying/base-asset indexes;
- spot-pair lookup;
- asset collection;
- static list initialization and duplicate detection;
- mutable repository upsert/remove semantics;
- server filtering and publication.

Ticker underlyings must not use the current panic-based
`PerpUnderlying::asset_id()` path. Repository insertion should parse and index
valid future data without panics.

### Market-info server

`market-info-server/src/main.rs` currently serves assets/instruments, while
full `list_market_info` is explicitly unimplemented. Adding domain futures does
not automatically publish future market facts.

The server work includes:

- future filtering in `ListInstruments`;
- full future payload serialization;
- snapshot/delta behavior;
- old-client behavior;
- catalog version/provenance exposure;
- deployment sequencing.

### Messaging and conversion layers

Affected layers include:

- domain-to-market-info protobuf conversion;
- market-info protobuf-to-domain conversion;
- common/deprecated instrument conversion;
- numeric `u32` instrument-type conversion, currently restricted to 0 and 1;
- Drift/Hyperliquid-specific conversion boundaries;
- generated serde/JSON conversion;
- TypeScript and Python mirrors.

Conversions to a narrower venue protocol should become fallible instead of
inventing future support.

### Trade, positions, and accounting

Current code frequently uses the spot/perpetual split to choose between asset
balances and derivative positions. Futures share some perpetual mechanics but
add termination and settlement.

Required decisions include:

- how a futures position is keyed;
- whether common position code dispatches on spot versus derivative;
- daily variation-margin accounting;
- unrealized and realized P&L around final settlement;
- cash settlement versus physical-delivery prevention;
- close/flatten deadlines;
- final settlement price source;
- position removal/archive behavior after settlement;
- portfolio valuation before and after termination.

The current domain references say derivative positions use `ContractId`, but
several implementations use `InstrumentId`. This cannot remain an implicit
shortcut once expiry, roll, and replay behavior depend on contract lifecycle.

### Backtest and simulation

The DEC states that the simulator must stop filling an expired contract and
force-settle positions. Current simulation mostly treats non-spot markets as
perpetual derivatives and has no final-settlement-price event.

Required work includes:

- reject fills at the exact termination boundary;
- introduce a reproducible settlement event and price source;
- settle or flatten open positions according to the method;
- prevent physical delivery;
- preserve settlement decisions in the output artifact;
- replay calendar changes against the version used by the original run;
- test contracts whose first notice precedes or differs from last trade;
- decide whether daily variation margin is modeled or intentionally omitted.

The backtest artifact database does not currently store the proposed future
lifecycle fields. Merely adding the enum may not require a database migration,
but faithfully persisting future semantics does.

### Risk and execution

Risk needs an explicit operational deadline. For physical contracts, first
notice and trading termination can impose different constraints. The decision
must specify which one triggers warnings, order rejection, forced flattening,
and incident escalation.

Execution needs:

- a trading-hours/session model before live CME operation;
- order cutoff semantics;
- whole-contract validation;
- product-specific tick behavior;
- correct handling of dynamic/calendar-dependent tick rules;
- unsupported behavior before the CME adapter exists.

The DEC's SR3 consequence is internally unsafe: it proposes storing the
standard tick while acknowledging that the front month can have a smaller
tick. `MarketInfoTrait::min_px_inc` is defined as the minimum price step the
venue accepts. Publishing a knowingly inaccurate value violates that contract;
the dynamic rule must be modeled, the scope narrowed, or SR3 excluded until it
is correct.

### Market data and oracle consumers

Drift and Hyperliquid oracle projections are venue-specific. They should not
receive placeholder future arms that claim CME compatibility.

CME futures require separate decisions for:

- MDP3 market-data ingestion;
- venue-native price representation;
- contract-month subscriptions;
- product family versus individual contract identity;
- final settlement prices;
- session boundaries and data gaps;
- historical reference and calendar data.

### Client, WASM, and TypeScript APIs

Affected public/client surfaces include:

- `client/crates/client-core/src/wasm.rs`;
- generated client-core declarations that currently expose only `"spot" |
  "perp"`;
- Structure Web instrument repositories;
- positions and portfolio-history repositories;
- API filters and JSON shapes;
- generated messaging TypeScript enums.

The TypeScript domain mirror uses a separate numeric convention in some places,
including a `None` value. Its future value must follow that type's own mapping,
not blindly copy the Rust/protobuf numeric value.

### Fixtures, snapshots, configuration, and documentation

Expected churn includes:

- market-info dispatch and underlying tests;
- static-market generator tests;
- trade/trade-v2 market-info fixtures;
- simulation end-to-end fixtures;
- event-gateway snapshots;
- instrument JSONL fixtures;
- market-data server configuration;
- Hyperliquid market-info design docs;
- backtest feed specification and plans;
- living knowledge-base references and server specifications.

The living `knowledge-base/docs/references/market-info.md` still states that
market info is spot or perpetual and that `QuoteUnit` is asset-only. It must be
updated with a provenance row in the same semantic change that accepts and
implements this decision.

## Storage and Data Compatibility

Adding `FUTURE` by itself does not necessarily require an immediate migration
for stores that persist only instrument or contract IDs. Existing records stay
valid if old IDs remain stable.

Stores that persist enum numbers or strings require review:

- Rust Serde encodes `InstrumentType` as `spot`/`perp`; old readers reject a
  new `future` string;
- protobuf fields need value 2 and regenerated bindings;
- JSON/text representations need new names;
- database/check constraints or analytics enums, where present, must be
  extended without renumbering;
- snapshots and fixtures that assert a closed two-value set must change.

The backtest artifact schema currently stores instrument and contract
references but not termination, settlement method, or calendar provenance.
Representing the DEC's semantics therefore requires an additional storage
design even if the discriminator itself fits without migration.

## What Is Not Affected

Assuming existing numeric values and hashes remain frozen:

- CME/CBOT/NYMEX/COMEX venue identities;
- existing spot/perpetual instrument IDs;
- existing spot/perpetual protobuf binary records;
- existing Drift and Hyperliquid market semantics;
- `SpotMarketTrait` behavior;
- `ListingStatus` as a current-state enum;
- stores that contain only stable IDs and never interpret market kind;
- the separate backtest-view enum that already has its own Future value;
- prototype-local `MarketInfoType` definitions unless they are intentionally
  migrated to the production abstraction.

These areas can still require mechanical changes if they exhaustively match a
shared enum.

## Compatibility Matrix

| Producer | Consumer | Spot/perpetual | Future before consumer upgrade |
|---|---|---|---|
| Old | Old | Unchanged | Not produced |
| New | Old | Compatible only if existing fields/tags retain their meaning | Unknown enum/oneof; may reject, omit, or discard |
| Old | New | Must remain compatible | No future records; valid empty result |
| New | New | Compatible | Supported only after domain, wire, and business behavior are deployed |

Quote-unit scale needs a stricter matrix than ordinary protobuf additions
because silent scale omission produces a valid-looking but economically wrong
price.

## Recommended Migration Sequence

1. Freeze compatibility contracts.
   - Add regression tests for existing spot/perpetual instrument IDs.
   - Freeze venue values, protobuf tags, hash seed, and existing enum values.
2. Complete the decision model.
   - Define identity, timestamps, chronology, settlement, source provenance,
     errors, replay, and correction behavior.
3. Define the wire contract before publishing domain values.
   - Assign tags for future market info, settlement variants, and quote units.
   - Specify old-reader and unknown-value behavior.
4. Regenerate Rust, TypeScript, and Python bindings.
5. Upgrade consumers to fail closed.
   - Add explicit unsupported-future errors to venue-specific and spot-only
     paths.
   - Remove wildcards that would classify futures as perpetuals.
6. Introduce the domain traits and sum types.
   - Add `DerivativeMarketTrait`, `FutureMarketTrait`, and future settlement
     values.
   - Keep a temporary compatibility facade if incremental rollout is needed.
7. Update repositories and server boundaries.
   - Add future indexing, contract lookup, asset collection, serialization,
     filtering, and catalog versioning.
8. Add the deterministic CME contract-month generator and pinned fixtures.
9. Upgrade shared derivative consumers.
   - Position lookup, valuation, notional/P&L, and artifact extraction.
10. Implement future-specific behavior.
    - Termination, settlement, risk deadlines, replay, and physical-delivery
      prevention.
11. Publish future catalog entries only after all required readers are live.
12. Add CME execution and live market-data capability separately.

## Lower-Blast-Radius Alternatives

### Compatibility facade

Add future-aware APIs such as `as_derivative()` and `dispatch_kind()` while
temporarily retaining the current two-way methods. Existing consumers keep
working but must reject future values at ingestion. Migrate consumers by
semantic responsibility, then remove the old facade.

### Nested derivative kind

Use a semantic shape such as:

```text
MarketInfoKind
├── Spot
└── Derivative
    ├── Perpetual
    └── Future
```

Consumers needing only common derivative facts handle one derivative branch.
Funding and settlement consumers must still handle the subtype explicitly.

### Versioned futures catalog/API

Keep the existing spot/perpetual endpoint stable and introduce a future-aware
version or separate futures catalog. This reduces deployment coupling but
creates a managed dual-API period.

### Defer source-level renames

Introduce generic domain names internally but keep `PerpUnderlying` aliases and
wire message names during the first protocol migration. Renaming generated APIs
can happen after behavior and compatibility are stable.

### Separate CME generator first

Build and verify a dedicated, provenance-aware CME catalog without adding it to
the production `MKT_INFO_LIST`. This isolates data-quality work from the shared
dispatch and protocol migration.

## Required Verification

### Identity and compatibility

- Existing spot and perpetual `InstrumentId` regression fixtures remain exact.
- Future IDs are deterministic across runs and platforms.
- Contract IDs follow the documented identity rule.
- Existing protobuf binary fixtures still decode and re-encode.
- Old-reader/new-writer behavior is tested for enum and oneof additions.
- Rust Serde and protobuf JSON behavior is covered.

### Domain and property tests

- Settlement chronology invariants reject invalid values.
- Quote-unit scale and multiplier cannot double-convert.
- ZC, CL, treasury, SR3, and MNQ examples use handpicked expected results.
- Cash and physical variants round-trip without impossible fields.
- Empty/noncanonical tickers and invalid scale ranges are rejected.
- Repository lookup by instrument and contract is consistent.

### Consumer behavior

- Spot/perpetual behavior remains unchanged.
- Venue-specific consumers reject futures explicitly.
- Futures are never routed through a perpetual wildcard.
- Accounting and valuation use common derivative facts where appropriate.
- Backtests reject post-termination fills and settle reproducibly.
- Physical-delivery positions are flattened before the chosen risk deadline.
- TypeScript, Python, Rust, and WASM public surfaces agree.

### Catalog and operations

- CME generation is deterministic from pinned fixtures.
- Duplicate IDs and conflicting contract-month facts fail startup/generation.
- Source version and correction history are observable.
- Replaying a run uses the same calendar/reference version.
- A rollback can stop future publication without corrupting existing catalog
  readers or IDs.

## Final Assessment

Reusing the existing venue values is safe and materially reduces the work. It
does not reduce the central blast radius: futures add a new economic lifecycle
to a platform whose market dispatch, wire types, positions, simulation, and
clients currently assume a binary spot/perpetual world.

The safest implementation treats this as a staged protocol and semantic
migration. Upgrade readers and make unsupported paths fail closed before
publishing any future record. Then add the deterministic CME catalog, shared
derivative behavior, and future-specific lifecycle behavior. Live CME execution
remains a separate capability after the metadata model is correct.
