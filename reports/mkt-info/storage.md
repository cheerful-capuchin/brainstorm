# Market Info Storage

Date: 2026-09-07

Status: implemented for CME futures on 2026-09-07. The section
"Implementation notes" at the end records where the code differs from the
design below and why.

Scope of this revision: CME futures only. Hyperliquid and Drift keep their
current code paths and are handled later.

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
- Hyperliquid and Drift RON files and generator changes.

## Overview

```
market-info/assets/
  markets/<venue>/<instrument_type>/<symbol>.ron   human edited, generator edited
  schedules/<schedule_id>.ron                      referenced by markets
  markets.csv                                      derived, checked in
  market-info.rkyv                                 derived, checked in

market-info/crates/market-info-store               library: tree rules, RON codec,
                                                   ledger, archive, catalog build
market-info/crates/mkt-info-gen                    the CLI

  walk RON tree
    -> decode the params struct of each venue and type
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
assets/markets/nymex/future/CLZ6.ron
assets/markets/comex/future/GCZ6.ron
assets/schedules/continuous-v1.ron
assets/schedules/cbot-grains-1900-1320-ct-v1.ron
```

Rules:

- Directory names are the lower case `Venue` and `InstrumentType` display
  strings. The file stem is the venue symbol. The CLI checks that the path
  agrees with the fields inside the file and refuses a mismatch.
- A symbol that is not a legal file name is percent encoded. CME symbols are
  plain ASCII, so no encoding applies today.
- A file is never deleted when a venue delists a market. `listing_status`
  changes to `Delisted`. Historical data references the id.
- One market per file. One asset per file. One schedule per file.

### What a market file stores

A market file stores the existing params struct of its venue and type. For
CME futures that is `CmeFutureMarketInfoParams`. No new struct is added.

```ron
CmeFutureMarketInfoParams(
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

The file does not store `CmeFutureMarketInfo` itself, for three reasons:

- It holds computed data. `instrument` carries the instrument id, and
  `settlement_asset` is always the USD fiat asset. Storing them invites a
  file that disagrees with its own inputs.
- Decoding it would bypass `try_new`. The params struct is the input of the
  constructor, so every file goes through validation when it is built.
- Its fields are private, which is right for the domain type and wrong for
  a file a human edits.

The params struct gains `Serialize`, `Deserialize`, and `PartialEq`. Its
field types need serde derives where they are missing today:

- `QuoteUnit` in market-info-core. It is `#[non_exhaustive]` and has no
  serde derive.
- `ListingStatus` and `FutureSettlementMethod` in market-info.
- `Venue`, `TradingScheduleId`, `NanoTimestamp`, `Decimal`, and `Price`
  already derive serde.

No file stores `instrument_id` or `contract_id`. Those are computed.

### Assets and schedules

For CME the only asset is USD, and the constructor supplies it. The
archive's asset table is collected from the markets. An `assets/assets`
tree is added when a venue needs an asset that no market carries, for
example a quote token on a spot venue.

`assets/schedules/<id>.ron` stores a `TradingScheduleRecord`, which already
derives serde. The CME schedule JSON catalog in
`crates/cme-market-info-gen/assets` converts to this tree once and is then
retired.

### References between files

A market refers to a schedule by `TradingScheduleId`, which is the file
stem. A market that needs an asset refers to it by the path relative to
`assets/assets` without the extension, for example `"fiat/USD"`. CME futures
do not reference an asset in the file. The constructor picks USD.

The CLI resolves every reference and fails with the referencing file path
and the missing key when one does not resolve.

Numeric types `Price`, `Qty`, and `Decimal` are written as decimal strings.
Timestamps are written as integer nanoseconds. Both already round trip
through serde.

### Field ownership

Generators rewrite files, and humans edit files by hand. Without a rule, the
next generator run reverts the hand edit. The params struct documents which
fields the generator owns. The generator reads the file, replaces only its
own fields, and writes the file back. Fields it does not own are left as
read.

For CME, the generator owns everything that comes from the secdef and FPRF
inputs. `display_name` and `trading_schedule_id` come from the reviewed
policy in `policy.rs` and the schedule catalog, so the generator owns them
too. A human edit to a CME file is therefore expected to be rare and to be a
correction that the next generator run confirms or reverts.

The RON pretty printer configuration is fixed in one place and used by every
writer, so a generator run that changes one field produces a one line diff.

## The identity ledger: markets.csv

`assets/markets.csv` is derived by the CLI and checked in. It is the only
place where an instrument id is written in a human readable form. It is
written as aligned columns so that a person can read it without a tool.

```
instrument_id           , instrument_id_u64   , contract_id             , contract_id_u64     , venue , type  , symbol  , status  , display_name          , filepath
inst_0143FK9S4J45C      , 40655105779372204   , cntr_0143FK9S4J45C      , 40655105779372204   , cbot  , future, ZCN2027 , active  , ZCN2027 CORN FUTURES  , markets/cbot/future/ZCN2027.ron
inst_06Q383CN8R1RM      , 242182945858389780  , cntr_06Q383CN8R1RM      , 242182945858389780  , cbot  , future, ZMV2026 , active  , ZMV2026 SOYBEAN MEAL  , markets/cbot/future/ZMV2026.ron
```

Format rules:

- The separator is `, `. Every value is padded with spaces on the right to
  the width of its column. Readers parse with whitespace trimming, which the
  `csv` crate supports with `Trim::All`.
- Each column has a fixed minimum width. Ids are fixed length, and the
  minimum widths for venue, type, symbol, and status cover every value we
  have. Only `display_name` and `filepath` can grow. This keeps a one market
  change to a one line diff in most cases. When a longer value appears, the
  column reflows and the diff is wider once.
- A value that contains a comma or a double quote is quoted the CSV way.
  Display names can contain commas.
- Rows are sorted by `instrument_id`. `contract_id` is empty for spot.

`display_name` is in the file because it helps a human find a row. It is
presentation data in an identity file, and that is accepted.

The CLI compares the ledger it just built with the checked in one and
refuses to write when:

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

`markets` holds `MarketInfo`, not `FutureMarketInfo`, so that the file does
not change shape when spot and perp venues move to this path. For CME only,
every element is `MarketInfo::Future`.

`assets` is needed even though every market embeds its assets. The asset
repository serves assets that no market references. Assets duplicated inside
markets are a few hundred kilobytes at the current collection size and are
not worth normalizing.

### The schema hash

rkyv has no reflection, so the schema hash is a fixture hash.

`market_info::schema_fixture()` returns one `MarketInfoFile` value with every
variant of every enum present and a distinct value in every field. Both the
CLI and the loader serialize the fixture with rkyv and hash the bytes with
blake3. The first eight bytes of the digest are the `schema_hash`.

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

These changes are prerequisites. Most are in other repositories.

For the RON files, in market-info and market-info-core:

- `CmeFutureMarketInfoParams` derives `Serialize`, `Deserialize`,
  `PartialEq`.
- `ListingStatus` and `FutureSettlementMethod` derive serde.
- `QuoteUnit` derives serde.

For the archive, `FutureMarketInfo` and everything it contains must derive
rkyv. `MarketInfo` itself does not, see "Implementation notes":

- market-info: `FutureMarketInfo`, the CME struct, `Underlying`,
  `ListingStatus`, `FutureSettlementMethod`, `Asset`, `CryptoAsset`,
  `FiatAsset`, `TradingScheduleId`, and the schedule types derive
  `rkyv::Archive`, `rkyv::Serialize`, `rkyv::Deserialize`. Fields of type
  `Decimal` get `#[rkyv(with = RkyvDecimal)]`. `FiatAsset` keeps its
  `Cow<'static, str>` fields through `rkyv::with::AsOwned`.
- numerics: `Price`, `Qty`, and `Notional` derive rkyv behind the existing
  `rkyv` feature.
- market-info: rkyv becomes a required dependency, not a feature.
- market-info-core: `Instrument`, `InstrumentId`, `InstrumentType`, `Venue`
  and its unit structs, `Asset`, `CryptoAsset`, `FiatAsset`, `AssetId`,
  `CryptoAssetType`, `Blockchain`, `Fiat`, `QuoteUnit`, `ContractId` derive
  rkyv. Private fields are fine because the derive is in the defining crate.
  `numerics` is enabled with the `rkyv` feature.
- utils `time`: `NanoTimestamp` derives rkyv.

## The CLI: mkt-info-gen

Location: `market-info/crates/mkt-info-gen`. Binary name `mkt-info-gen`.

```
mkt-info-gen build   --assets market-info/assets [--allow-id-change]
mkt-info-gen check   --assets market-info/assets
mkt-info-gen inspect --file market-info/assets/market-info.rkyv [--instrument inst_...]
```

`build` runs the pipeline and writes `markets.csv` and `market-info.rkyv`
next to the tree. `check` runs the same pipeline and exits non zero when
either output would change or any validation fails. It is the CI command.
`inspect` prints the header, the schema hash, the counts, and optionally one
market as RON, so an operator can look inside a file pulled from the bucket.

Pipeline, each step fails with the file path and the reason:

1. Walk `assets/assets`, decode every asset, index by reference key. Fail on
   duplicate `asset_id`.
2. Walk `assets/schedules`, decode every `TradingScheduleRecord`. Fail on
   duplicate id or on a file stem that differs from the id inside.
3. Walk `assets/markets`, decode every file into the params struct chosen by
   the directory pair. Fail on a path and content mismatch.
4. Resolve schedule references, and asset references where a venue has
   them.
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

`cme-market-info-gen` stops emitting the JSON catalog. It:

1. Reads secdef and the FPRF files as it does today.
2. For each contract, reads the existing RON file if present, decodes it
   into `CmeFutureMarketInfoParams`, replaces the fields it owns, and writes
   the file back with the shared pretty printer. If the file is absent, it
   writes a new one.
3. For each existing file under the four CME venues that the input no
   longer mentions, sets `listing_status` to `Delisted`. It never deletes.
4. Keeps its `--check` mode, now defined as "no RON file would change".
5. Does not touch `markets.csv` or the rkyv file. The user runs
   `mkt-info-gen build` after.

The generator depends on the params struct and the shared pretty printer and
on nothing else new.

## Bucket and runtime

Objects are named `market-info/<generated_at>-<source_revision>.rkyv`. A
small `market-info/latest` object holds the name of the current file. A
service reads `latest`, then the file it names. A partial upload can never be
picked up, and rollback is one write of `latest`.

The reload command and the repository ingestion are out of scope for this
report.

## Tests

Property tests are the main tool. The workspace already uses proptest
`1.11.0` in market-info-repo.

- RON round trip. A proptest strategy produces arbitrary
  `CmeFutureMarketInfoParams` values, including every `QuoteUnit` variant,
  both settlement methods, and every listing status. Serialize with the
  shared pretty printer, parse, assert equality. The same for
  `TradingScheduleRecord` and `Asset`. This proves the params struct and its
  field types survive the file format.
- Constructor agreement. For arbitrary params, `try_new` on the parsed value
  returns the same result as `try_new` on the original, both the `Ok` and
  every `Err` variant. This proves the file cannot change what the
  constructor decides.
- Ledger round trip. Arbitrary ledgers, including display names with commas
  and quotes, write to the aligned format and parse back unchanged.
- Ledger guard. Arbitrary old and new ledgers with a random id change or a
  random row removal are refused without the flag and accepted with it.
- Archive round trip. Arbitrary `MarketInfoFile` values serialize with rkyv,
  pass bytecheck, and deserialize equal.
- Schema fixture. Serialize the fixture, compare the hash with a checked in
  constant. When a domain type changes on purpose, the failure tells the
  author to bump the constant. This is the test that proves the hash tracks
  layout.
- Full build. `mkt-info-gen check` over the real tree in CI.
- Load. Decode the checked in `market-info.rkyv` and compare every market
  with the one built directly from the RON tree. This is the test that
  proves the dataset loads.

## Open questions

- CME symbols are plain ASCII. If a later venue uses `/` or another reserved
  character in a symbol, percent encoding of file stems starts to apply.
  Decide the encoding then, or now.

## Implementation notes

Where the code differs from the design above, and why.

- The archive holds `Vec<FutureMarketInfo>`, not `Vec<MarketInfo>`. A rkyv
  derive on `MarketInfo` needs derives on every variant, and the Drift types
  hold `&'static Asset` and `Vec<(SpotMarket, &'static str)>`, which rkyv
  cannot archive. Reworking Drift is deferred with the rest of Drift. The
  schema hash will change when the field type changes, which is the expected
  path. The Hyperliquid `&'static str` display names were therefore not
  changed either.
- There is no `assets/assets` tree yet. The archive's asset table is
  collected from each market's settlement asset, deduplicated by id. The tree
  is added when a venue needs an asset that no market carries.
- `source_revision` is a blake3 content hash of the RON files, 16 hex
  characters, not a git sha. `check` stays deterministic and free of git.
- `check` compares the existing archive with the new one on `markets`,
  `assets`, `schedules`, and `source_revision`, not on bytes, because
  `generated_at` changes on every run. `build` leaves the archive untouched
  when only `generated_at` would change, so the checked in file does not
  churn.
- The library and the CLI are separate crates. `market-info-store` holds the
  tree rules, the RON codec, the ledger and its guard, the archive with its
  header and schema hash, the schema fixture, and the in-memory catalog
  build. `mkt-info-gen` does the file walk, the atomic writes, and the exit
  codes: 1 failure, 2 usage, 3 guard refused, 4 stale output in `check`.
- The RON codec uses ron 0.12.2 with newtypes unwrapped, so `Price` and
  `Decimal` fields render as plain decimal strings. The extension is a
  default of the codec's `Options` on both sides, so files carry no
  `#![enable(...)]` header, and a file that has one still parses. `venue`
  renders as serde gives it for a newtype variant of a unit struct.
- The ledger carries each id twice: the base32 display form and the plain
  `u64`. The parser refuses a row where the two disagree.
- The ledger's last column is not padded, so lines carry no trailing
  whitespace. The parser trims, so padded input is accepted too.
- `schema_hash()` and `schema_fixture()` return `Result`, because the fixture
  goes through `try_new` and the no-panic rule forbids `expect`.
- The guard's `IdChanged` rule cannot fire for CME: the path encodes symbol,
  venue, and type, which are exactly the id inputs, so an id change always
  moves the file and shows up as `RowRemoved`. The rule stays for venues
  whose id inputs are not all in the path.
- The CME generator keeps its JSON output. `client-core` bundles that JSON
  with `include_str!` and a Python tool regenerates it, so removing it is a
  separate change. `--markets-dir` writes the RON tree next to it, and at
  least one of the two outputs must be requested. CME files are replaced
  whole when they differ; there is no field merge, because the generator
  owns every field of a CME file.
- The bundled secdef snapshot in the generator's assets is partial and lacks
  most policy products, so the tree could not be generated from raw inputs.
  A second binary, `cme-catalog-import`, seeds the tree from the reviewed
  JSON catalog and refuses any market whose recomputed instrument or
  contract id differs from the canonical one in the JSON.
- `market_info.rs` and `trading_schedule.rs` were over the file size limit
  and were split into submodules with unchanged public paths.
- `cargo fmt` on market-info reformatted the two generated Hyperliquid files
  under `src/generated`, which were already modified in the working tree
  before this work. The content changes there predate this work.

## Decisions taken in the discussion

- No intermediate storage struct between the RON tree and the archive. The
  archive holds the domain types. A layout mismatch is rejected by the schema
  hash and fixed by a re-upload.
- The RON files store the existing params struct of each venue and type, not
  the market info type and not a new source struct.
- The schema hash is a fixture hash, not a hand maintained version number.
- Ids are never stored in RON. `markets.csv` is the ledger and the guard. It
  is column aligned and carries `display_name`.
- Assets and schedules are separate file trees referenced by key.
- `market-info.rkyv` is checked in next to the tree.
- Hyperliquid and Drift are deferred. Only the rkyv derives and the
  `Arc<str>` display name change touch them, because the `MarketInfo` enum
  contains their types.
