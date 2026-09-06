# Market Info Storage

Date: 2026-09-07

Status: proposal. Nothing in this report is implemented.

## Problem

Every market the platform knows about is Rust source. The Hyperliquid catalog
is generated into `market-info/src/generated`, the Drift markets are literals in
`market_info_list.rs`, and the CME catalog is a JSON file that still needs a
code path. All of them are compiled into `StaticMktInfoRepo` and served from
there.

Changing one field of one market means a code change, a full rebuild, and a
redeploy of every consumer. Nobody can look up a market without reading Rust.

## Goal

- Markets live as human readable files in the `market-info` repository. Anyone
  can read or edit one. Generators read and write the same files.
- Production loads one binary file from a bucket at boot, or on a runtime
  command, and fills the in-memory repository from it.
- A collection change is a file change plus a re-upload. No rebuild.

## Out of scope

- Ingestion into `market-info-repo`. The loader that turns the binary file
  into repository inserts is a separate piece of work. This report stops at
  "the file is on disk and can be decoded into domain types".
- Removal of `StaticMktInfoRepo`, the `static_mkt_info` and `code_gen`
  features, and the `ctor` based initialization. They stay until the loader
  exists.

## Overview

```
market-info/assets/
  markets/<venue>/<instrument_type>/<symbol>.ron   human edited, generator edited
  assets/<blockchain>/<symbol>.ron                   referenced by markets
  schedules/<schedule_id>.ron                        referenced by markets
  markets.csv                                        derived, checked in
  market-info.rkyv                                   derived, not checked in

market-info/crates/mkt-info-gen                      the CLI

  walk RON tree
    -> decode per venue file structs
    -> resolve asset and schedule references
    -> run domain constructors  (validation, ids)
    -> build MarketInfoFile in memory  (staging)
    -> guard against markets.csv
    -> write markets.csv and market-info.rkyv atomically
```

## Source of truth: the RON tree

### Layout

```
assets/markets/cme/future/ESZ6.ron
assets/markets/cbot/future/ZCZ6.ron
assets/markets/hyperliquid/perp/BTC.ron
assets/markets/hyperliquid/spot/@107.ron
assets/markets/drift/spot/USDC.ron
assets/assets/solana/USDC.ron
assets/assets/hyperliquid/HFUN.ron
assets/schedules/continuous-v1.ron
assets/schedules/cbot-grains-1900-1320-ct-v1.ron
```

Rules:

- Directory names are the lower case `Venue` and `InstrumentType` display
  strings. The file stem is the venue symbol. The CLI checks that the path
  agrees with the fields inside the file and refuses a mismatch.
- A symbol that is not a legal file name is percent encoded. Hyperliquid spot
  symbols such as `@107` are legal on every file system we use, so no encoding
  is needed today.
- A file is never deleted when a venue delists a market. `listing_status`
  changes to `Delisted`. Historical data references the id.
- One market per file. One asset per file. One schedule per file.

### File structs

The RON files do not store the `MarketInfo` enum. Each venue and instrument
type has one file struct. The struct holds exactly the fields a human or a
generator decides, and nothing derived. The CLI turns file structs into domain
types through the existing constructors.

The file structs live in a new module `market_info::source` so that the CLI,
the generators, and tests share one definition. They derive `serde` only. They
do not derive rkyv.

No file struct stores `instrument_id`, `contract_id`, or `asset_id`. Those are
computed.

`CmeFutureSource` maps one to one onto `CmeFutureMarketInfoParams`:

```ron
CmeFutureSource(
    symbol: "ESZ6",
    venue: Cme,
    display_name: "E-mini S&P 500 Dec 2026",
    underlying_ticker: "ES",
    quote_unit: IndexPoint(ticker: "SPX"),
    settlement_qty_per_quote_unit: "50",
    min_px_inc: "0.25",
    quote_decimals: 2,
    listing_status: Active,
    activation_time: 1750000000000000000,
    trading_termination_time: 1766000000000000000,
    settlement_method: Cash,
    trading_schedule_id: "cme-equity-1700-1600-ct-v1",
)
```

`HlPerpSource` holds the inputs of `HlPerpMarketInfo::new` plus
`min_notional`. `underlying` is either `Asset("hyperliquid/PEPE")` or
`Ticker("PAXG")`. `settlement_asset` and `funding_asset` are asset references.

`HlSpotSource` holds the inputs of `HlSpotMarketInfo::new`. `base_asset` and
`quote_asset` are asset references.

`DriftSpotSource` holds `DriftSpotMarketConfig` minus the `Instrument`, which
is rebuilt from `symbol` and the venue implied by the path.

`AssetSource` is either `Crypto { symbol, name, blockchain, asset_type, decimals }`
or `Fiat { symbol, name, fiat }`.

`ScheduleSource` is `TradingScheduleRecord` from `trading_schedule.rs`, which
already derives serde. The CME schedule JSON catalog converts to this tree
once.

### References between files

A market refers to an asset by the path relative to `assets/assets` without
the extension, for example `"solana/USDC"`. A market refers to a schedule by
`TradingScheduleId`, which is the file stem. The CLI resolves every reference
and fails with the referencing file path and the missing key when one does
not resolve.

Numeric types `Price`, `Qty`, and `Decimal` are written as decimal strings.
Timestamps are written as integer nanoseconds. Both already round trip through
serde.

### Field ownership

Generators rewrite files, and humans edit files by hand. Without a rule, the
next generator run reverts the hand edit. Each file struct documents which
fields a generator owns. The generator reads the file, replaces only its own
fields, and writes the file back. Fields it does not own are left as read.

For Hyperliquid, the existing `overrides.toml` stays the place for human
choices that the venue feed cannot supply, such as `underlying_symbol` and
`display_name` for scaled perps.

The RON pretty printer configuration is fixed in one place and used by every
writer, so a generator run that changes one field produces a one line diff.

## The identity ledger: markets.csv

`assets/markets.csv` is derived by the CLI and checked in. It is the only
place where an instrument id is written in a human readable form.

```
instrument_id,contract_id,venue,instrument_type,symbol,listing_status,filepath
inst_1531185364826081794,,drift,spot,USDC,active,markets/drift/spot/USDC.ron
```

Sorted by `instrument_id`. `contract_id` is empty for spot.

The CLI compares the ledger it just built with the checked in one and refuses
to write when:

- a row from the old ledger is missing in the new one;
- a row keeps its `filepath` but changes `instrument_id`;
- two files produce the same `instrument_id`.

A flag `--allow-id-change` turns the first two refusals into warnings. It is
for the rare case where a wrong symbol was checked in and the id was never
used. The refusal exists because `Instrument::from_canonical_id` documents
that the fixed seed hash is not byte identical on every target, and because
historical data holds these ids.

## The compiled artifact: market-info.rkyv

### Format

rkyv `0.8.16`, the version already pinned in `domain`, `feed-info`,
`dsl-runtime`, and the `numerics` rkyv feature. Reasons:

- Zero copy access with bytecheck validation. A truncated or corrupt file is
  refused before any field is read.
- `Decimal`, `Price`, and `Qty` already archive through
  `numerics::decimal::RkyvDecimal`.
- Every consumer of this file is a Rust service.

Alternatives considered and rejected:

- Postcard over the existing serde derives. Simpler, cross language, but no
  validation on load.
- Protobuf through `market-info-wire`. Cross language, but full market info
  messages do not exist and would have to be written and kept in sync.
- FlatBuffers. Same benefits as rkyv, but a second schema language and a new
  dependency for the workspace.

The archive stores the domain types directly. There is no intermediate
storage struct. The trade off is that any layout change in a domain type
invalidates every existing file. That is accepted: re-upload is cheap, and
the rejection is detected at load, not by wrong values.

### Layout

```
+---------------------------+
| magic       b"STXRMKTI"   |  8 bytes
| schema_hash u64           |  8 bytes, see below
| rkyv_len    u64           |  8 bytes
| reserved    [u8; 8]       |  8 bytes, zero
+---------------------------+
| rkyv archive of           |
|   MarketInfoFile          |
+---------------------------+
```

The header is plain bytes, read with fixed offsets, so the loader rejects a
wrong `schema_hash` without touching the archive.

```rust
#[derive(rkyv::Archive, rkyv::Serialize, rkyv::Deserialize)]
pub struct MarketInfoFile {
    pub generated_at: NanoTimestamp,
    pub source_revision: String,      // git sha of market-info at build time
    pub markets: Vec<MarketInfo>,     // sorted by instrument_id, unique
    pub assets: Vec<Asset>,           // sorted by asset_id, unique
    pub schedules: Vec<TradingScheduleRecord>, // sorted by id, unique
}
```

`assets` is needed even though every market embeds its assets. The asset
repository serves assets that no market references, for example `WSOL`.
Assets duplicated inside markets are a few hundred kilobytes at the current
collection size and are not worth normalizing.

### The schema hash

rkyv has no reflection, so the schema hash is a fixture hash.

`market_info::source::schema_fixture()` returns one `MarketInfoFile` value
with every variant of every enum present and a distinct value in every
field. Both the CLI and the loader serialize the fixture with rkyv and hash
the bytes with blake3. The first eight bytes of the digest are the
`schema_hash`.

Any change in field order, field type, enum variant order, `Arc<str>` versus
`String`, or the rkyv version changes the bytes and so the hash. A renamed
field with the same type does not change the hash and does not need to. A
change in the meaning of a field is not detectable by any hash and is a
review concern.

Distinct values per field matter. Two swapped fields of the same type with
the same fixture value would hash the same.

Cost at boot: one serialization of a fixture with a few dozen records, a few
microseconds.

### Validation on load

rkyv deserialize does not run `try_new`. The CLI is the gate: every record in
the file passed the constructors when it was built. If a constructor rule
tightens between build and load, the loader will accept a value the current
code would refuse. Accepted for now. The loader may re-run the cheap checks
later if this turns out to matter.

## Domain type changes required

These changes are prerequisites. They are in other repositories.

market-info:

- `HlSpotMarketInfo.display_name` and `HlPerpMarketInfo.display_name` change
  from `&'static str` to `Arc<str>`. rkyv cannot archive a borrowed str.
- `MarketInfo`, `SpotMarketInfo`, `PerpMarketInfo`, `FutureMarketInfo`, the
  Drift, Hyperliquid, and CME structs, `Underlying`, `ListingStatus`,
  `FutureSettlementMethod`, `TradingScheduleId`, and the schedule types derive
  `rkyv::Archive`, `rkyv::Serialize`, `rkyv::Deserialize`. Fields of type
  `Decimal`, `Price`, `Qty` get `#[rkyv(with = RkyvDecimal)]`.
- rkyv becomes a required dependency, not a feature.
- `CryptoAsset::new` takes `&'static str`. `CryptoAsset::from_arc` already
  exists and is what the CLI uses.

market-info-core:

- `Instrument`, `InstrumentId`, `InstrumentType`, `Venue` and its unit
  structs, `Asset`, `CryptoAsset`, `FiatAsset`, `AssetId`, `CryptoAssetType`,
  `Blockchain`, `Fiat`, `QuoteUnit`, `ContractId` derive rkyv. Private
  fields are fine because the derive is in the defining crate.
- `numerics` is enabled with the `rkyv` feature.

utils (`time`):

- `NanoTimestamp` derives rkyv.

## The CLI: mkt-info-gen

Location: `market-info/crates/mkt-info-gen`. Binary name `mkt-info-gen`.

```
mkt-info-gen build  --assets market-info/assets --out market-info/assets [--allow-id-change]
mkt-info-gen check  --assets market-info/assets
mkt-info-gen inspect --file market-info.rkyv [--instrument inst_...]
```

`build` runs the pipeline and writes `markets.csv` and `market-info.rkyv`.
`check` runs the same pipeline and exits non zero when the ledger would
change or any validation fails. It is the CI command. `inspect` prints the
header, the schema hash, the counts, and optionally one market as RON, so an
operator can look inside a file pulled from the bucket.

Pipeline, each step fails with the file path and the reason:

1. Walk `assets/assets`, decode every `AssetSource`, build `Asset` values,
   index by reference key. Fail on duplicate `asset_id`.
2. Walk `assets/schedules`, decode every `ScheduleSource`. Fail on duplicate
   id or on a file stem that differs from the id inside.
3. Walk `assets/markets`, decode every file into the file struct chosen by
   the directory pair. Fail on a path and content mismatch.
4. Resolve asset and schedule references.
5. Run the domain constructor for each market. `try_new` errors are reported
   with the file path.
6. Collect into `MarketInfoFile`. Sort. Fail on duplicate `instrument_id` or
   `contract_id`.
7. Build the new ledger. Compare with the checked in `markets.csv` under the
   guard rules.
8. Serialize with rkyv. Compute the schema hash. Write header plus archive to
   `market-info.rkyv.tmp`, write `markets.csv.tmp`, then rename both. Nothing
   on disk changes if any earlier step failed.

Steps 1 through 7 are the staging area. The whole collection is in memory and
validated before any byte is written.

Memory and file limits follow the workspace rules: a fixed upper bound on the
number of files walked and on file size, checked before reading. No
recursion in the tree walk.

## Generator workflow

`cme-market-info-gen` and `hl-market-list-gen` stop emitting Rust or JSON
catalogs. Each one:

1. Reads its venue inputs as it does today.
2. For each market it knows about, reads the existing RON file if present,
   decodes it into the file struct, replaces the fields it owns, and writes
   the file back with the shared pretty printer. If the file is absent, it
   writes a new one.
3. For each existing file under its venue that the input no longer mentions,
   sets `listing_status` to `Delisted`. It never deletes.
4. Does not touch `markets.csv` or the rkyv file. The user runs
   `mkt-info-gen build` after.

The generators depend on `market_info::source` and the shared pretty printer
and on nothing else new.

## Bucket and runtime

Objects are named `market-info/<generated_at>-<source_revision>.rkyv`. A
small `market-info/latest` object holds the name of the current file. A
service reads `latest`, then the file it names. A partial upload can never be
picked up, and rollback is one write of `latest`.

The reload command and the repository ingestion are out of scope for this
report.

## Tests

- Round trip: every file struct serializes to RON and back unchanged. Table
  test over one example per struct.
- Schema fixture: serialize the fixture, compare the hash with a checked in
  constant. When a domain type changes on purpose, the test tells the author
  to bump the constant. This is the test that proves the hash tracks layout.
- Full build: `mkt-info-gen check` over the real tree in CI.
- Load: decode the rkyv file produced from the real tree and compare every
  market with the one built directly from the RON tree. This is the test that
  proves "we can load the dataset".
- Ledger guard: property test that a random id change or row removal is
  refused without the flag.

## Open questions

- Should the CSV also carry `display_name`? It helps humans and costs
  nothing, but it is presentation data in an identity file.
- Hyperliquid spot symbols such as `@107` are file stems today. If a venue
  ever uses `/` in a symbol, percent encoding starts to apply. Decide the
  encoding now or when it happens.
- Whether `source_revision` should be the market-info git sha or a content
  hash of the RON tree. The content hash works without git at build time.

## Decisions taken in the discussion

- No intermediate storage struct between the RON tree and the archive. The
  archive holds the domain types. A layout mismatch is rejected by the schema
  hash and fixed by a re-upload.
- The schema hash is a fixture hash, not a hand maintained version number.
- Ids are never stored in RON. `markets.csv` is the ledger and the guard.
- Assets and schedules are separate file trees referenced by key.
