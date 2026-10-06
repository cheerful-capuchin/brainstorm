---
create_time: 2026-10-06T07:20:47Z
title: "CME options in market info"
summary: "Tick tables implemented (D13): computed TickTableId (tick_ prefix) + display_name + description, tick-tables/*.ron, tick = price, lot = qty; replaces price rules; Globex min_qty from tag 562; kind traits open"
related_sessions: []
---

# SESS-00PXT2F: CME options in market info

## Request (2026-10-06)

Add CME options markets to `market-info/src/market_info.rs`, populated by
`market-info/crates/cme-market-info-gen`. CME Group venues only for now. The
user asked what to know about CME options and how the traits would be added.
The options model itself is still undecided; decisions D1-D5 below cover
min_qty and price increments.

## Facts gathered (for later agents)

- Knowledge base: DEC-0AFBN and SPEC:cme-futures-catalog-production exclude
  options; DEC-0BR2T lists "Options are modeled" as a revisit trigger, so a
  new or revised DEC is needed.
- Checked-in secdef snapshot: about 814k outright options (167=OOF with 201,
  202 and one 309 underlying) against 152k futures; about 171k options sit on
  the 140 futures the policy selects today (CL 18.5k, ES 17.8k).
  `ron_tree.rs` caps a directory at 4096 entries.
- Each future has many option product codes (ES: ES, EW, EW1-4, E1A-E5D);
  SecurityGroup 1151 is shared. ES quarterly options use product code ES and
  maturity 202612 like the future, so only the instrument id tag separates them.
- Serial, end-of-month and weekly options exercise into the next quarterly
  future; read the underlying from tag 309, do not derive it. Most metals
  options sit on futures outside the front-two selection.
- Strike tag 202 scaling differs per product (OG, SO, PO, SR3 do not follow
  202 x underlying DisplayFactor); negative strikes exist; symbol strike text is
  truncated or scaled and must not be parsed.
- ES/NQ/BTC options use variable tick tables (tag 6350, 969 absent); CME
  publishes the bands only on its wiki and in the Reference Data API.
- An options product reference file exists:
  `ftp.cmegroup.com/fprf/csv/cmeg.opt.prf.YYYYMMDD.csv.zip`, one row per strike,
  with SeriesExerStyle, SeriesSettlMeth (cash/physical), SeriesValMeth
  (premium/futures style), SeriesMult. The secdef CFI byte 5 is always P.
- Premium style on CME/CBOT/COMEX; futures style on some NYMEX products (BZO,
  7FO, ...). secdef.dat is daily and misses intraday and user-defined strikes
  (9779=Y, about 7.5%).

## Proposal presented (not accepted yet)

- Core: InstrumentType::OPTION = 3; InstrumentIdTag CmeOption..ComexOption =
  9..12; GlobexOption { product_code, maturity, put_or_call, strike (raw tag
  202, 1e-9 units), venue_symbol }; GlobexVenueOption<V> aliases.
- market-info: shared dated supertrait for activation/termination;
  OptionMarketTrait (put_or_call, strike_price, exercise_style,
  settlement_method, premium style); Underlying::Contract(ContractId);
  PriceIncrement (Fixed | Banded) replacing min_px_inc; OptionMarketInfo enum;
  MarketInfo::Option with a fourth dispatch closure.

## Open questions

- Catalog shape: one RON file per option with a narrow policy, one file per
  option series expanded at build, or a separate archive.
- Which option families (quarterly/monthly only, or weeklies and dailies).
- Accept the one-day lag for intraday and user-defined strikes, or plan a
  runtime path.
- Include futures-style NYMEX options in the first version or not.
- Hash the raw tag 202 strike or a scaled strike.
- Replace min_px_inc or add a separate method for variable ticks. Settled:
  replace it, see D2 below.

## Facts gathered later (2026-10-06)

- Tag 1142 MatchAlgorithm and tag 6350 TickRule are CME-assigned codes. No
  data file in the repo defines them: `templates_v13.xml` says "CME assigned
  values" and `OrchestraFIXLatest.xml` has field 1142 without a code set.
  Letter meanings (F = FIFO, K, O, Q, S, T, A, C) come from CME docs.
- VTT bands: CME Client Systems Wiki page "MDP 3.0 - CME Globex Pricing",
  page id 457225869, version 7 (2026-01-15). Readable without login at
  `https://cmegroupclientsite.atlassian.net/wiki/rest/api/content/457225869?expand=body.storage,version`.
  The page lists codes 1-4 and 10-18; codes 5-9 are absent. Values are raw
  Globex price units, multiplied by tag 9787 for display. Code 17 (ES
  options): P < -10000 -> 50; -10000 <= P < -2000 -> 25; -2000 <= P < -500
  -> 10; -500 <= P <= 500 -> 5; 500 < P <= 2000 -> 10; 2000 < P <= 10000 ->
  25; P > 10000 -> 50. With 9787 = 0.01: 0.05 up to 5, 0.10 to 20, 0.25 to
  100, 0.50 above. The wiki revision history says codes 17 and 18 were added
  2026-01-12; a CME notice (seen only as a search summary) says they went
  from two to four levels effective 2026-06-28.
- The wiki says 6350 = null means not VTT eligible and 6350 = 00 means a
  standard tick with the size in 969. Treat both as "no table".
- CME Reference Data API v3 has per-instrument `variableTickTable` and
  `vttLowTick`, `vttLowThreshold`, `vttMidLowTick`, `vttMidLowThreshold`,
  `vttMidHighTick`, `vttMidHighThreshold`, `vttHighTick`, `vttHighThreshold`,
  `vttPriceThreshold` (wiki page 457413632). Needs an OAuth API ID from CME
  Customer Center; not called. Unverified: whether the fields are filled for
  codes 1-16 and whether `variableTickTable` equals tag 6350.
- No public data file lists the VTT bands. The FPRF `PxTickRule` column holds
  codes only (`05`, `07` on futures, not wiki VTT codes).
- Databento GLBX.MDP3 definitions carry `tick_rule: u8` (tag 6350),
  `min_price_increment`, `match_algorithm` and `display_factor`, but no band
  fields (`dbn-0.70.0/src/record.rs`). Databento does not resell the RDA.
- Option strikes use the underlying future's 9787, the option trade price and
  tick use the option's own 9787 (wiki, SOFR example: option 9787 = 1.0,
  underlying 0.01).
- Hyperliquid already has a price-dependent tick (5 significant figures,
  capped by `max_px_decimals`). `live_min_px_inc(mid_price)` has no callers
  outside market-info; `strats_v2/src/calculation.rs` `compute_valid_px`
  rounds with the stored snapshot tick and truncates toward zero for both
  sides, so Hyperliquid rounding is stale when price crosses a power of ten.
- Secdef MinTradeVol (562) on FUT: 1 for all 140 selected futures; 2, 5 or
  15 only on unselected FX futures (EURUSD 5, USDMXN 15, ...) and ABY (2).

## Decisions (2026-10-06)

### D1. Globex `min_qty` comes from secdef tag 562 MinTradeVol (implemented)

The user asked the generator to use MinTradeVol instead of the hardcoded 1.

- `GlobexFutureMarketInfoParams`, `GlobexFutureMarketInfo` and the RON
  contract `GlobexFutureMarketParams` carry `min_qty: NonZeroU32` (whole
  contracts). `min_qty()` returns it. `min_qty_inc()` stays 1 because Globex
  trades whole contracts.
- `cme-market-info-gen` reads 562 as required and fails on missing, zero or
  non-numeric values.
- Archive schema hash changed (`EXPECTED_SCHEMA_HASH` 0x930e_6df5_b72d_470a),
  `assets/market-info.rkyv` rebuilt, 140 RON files gained `min_qty: 1`.
  Existing files were seeded with `min_qty: 1` before the run because the
  merge decodes them first.
- Test fixtures updated in `databento-mkt-data` (3 test_support files) and
  `trade-core` (`accounting/portfolio_value.rs`). Not committed.

### D2. The price increment is a function of price

The user asked for "a function that takes in a price and returns the
increment", and accepted it.

- `MarketInfoTrait::min_px_inc(&self, px: Price) -> Price` replaces the fixed
  `min_px_inc()`. It returns the tick of the band `px` falls in, using CME's
  boundary rules (20.00 belongs to the 0.10 band in table 17).
- Rounding and stepping are built on it: `is_valid(px)` = px is a multiple of
  `min_px_inc(px)`; `round_down` / `round_up` floor or ceil to
  `min_px_inc(px)`; `next_above(px)` = `round_up(px + min_px_inc(px))`;
  `next_below(px)` = `round_down(px - min_px_inc(px))`. Plain
  `px + min_px_inc(px)` is wrong at band edges.
- Invariant, checked when a table is loaded: every band edge is a multiple of
  the ticks on both sides. All CME tables and Hyperliquid's powers of ten meet
  it.
- Callers without a price (display) use `quote_decimals`, never a made-up
  price.
- Rounding direction belongs to the caller (resting buy rounds down, resting
  sell rounds up); `compute_valid_px` in strats_v2 should take the side.

### D3. Each market stores its price grid; VTT tables live in dated files

The user asked where the grid is stored and accepted the answer.

- Closed enum `PriceGrid { Fixed(Price), Banded(Arc<TickTable>),
  SignificantFigures { figures, max_decimals } }` held by every market struct.
  Fixed: CME futures, Drift. SignificantFigures: Hyperliquid, built from
  existing fields. Banded: CME VTT.
- Market files name the grid (`price_grid: Fixed("0.25")`,
  `price_grid: Vtt(17)`). VTT tables are separate files, e.g.
  `market-info/assets/tick-tables/cme-vtt-17.ron`, holding bands, boundary
  inclusivity, source page id and version, and versions with start dates.
- The catalog build (`mkt-info-gen`) replaces `Vtt(n)` with the table, the
  same way `settlement_asset_id` is resolved to an `Asset`. It refuses unknown
  table codes and tables whose edges break the D2 invariant. The archive holds
  the resolved table, so consumers never read the table files.
- Later, the CME Reference Data API can feed the same table files if an API
  ID is obtained.

### D4. Backtests build the catalog from the replayed security definitions

The user said backtests will pull the security definitions and rules for the
replayed period, so the catalog is updated from them.

- Consequence: `min_px_inc(px)` takes no time argument. The VTT table version
  is chosen when the catalog is built, for the build's date; strategies never
  see a time. Rejected alternative: markets holding every table version and
  `min_px_inc(px, at)`.
- Multi-day runs: definition updates (Databento daily 00:00 UTC snapshots plus
  intraday updates) are events on the replay timeline, a feed like the other
  replayed wires; the catalog rebuilds the affected markets at their
  timestamp, as live would. Covers listings, expiries, security id reuse and
  table changes mid-run (2026-06-28).
- Backtest results record the catalog inputs (definition source, market-info
  revision / tick table version), like the archive's `source_revision` and
  `generated_at`.

### D5. Quantity rules stay fixed (accepted with the rest)

- No venue has a price-dependent size step. Group the size limits as
  `QtyRule { min, step, min_notional: Option<Notional> }` with
  `round_down(qty)` and `admits(qty, px)`; Hyperliquid's minimum order value
  is the only price-dependent size rule.

### Order of work (accepted with the rest)

1. `PriceGrid` with `Fixed` and `SignificantFigures`, Hyperliquid moved onto
   it (fixes the stale tick).
2. Side-aware rounding in `compute_valid_px` and the target executor.
3. `Banded`, the VTT table files and the generator check, with CME options.
4. `QtyRule` with `min_notional`.

### D6. No shared dated trait (2026-10-06)

The user rejected `DatedMarketTrait`: "I don't need one more level of
inheritance". `OptionMarketTrait` extends `DerivativeMarketTrait` directly and
declares its own `activation_time` and `trading_termination_time`;
`FutureMarketTrait` keeps its own.

### D7. No `MarketInfo::Option`; replace `MarketInfoType` (direction, design open)

The user does not want a fourth `MarketInfo` variant with a fourth `dispatch`
closure and wants to drop `MarketInfoType`. Goal in their words: "specify what
kinds of markets I can handle or what kinds of markets I exclusively require
through traits", e.g. a spot-only component iterates the repository
(`market-info/crates/market-info-repo/src/market.rs`) and gets spot markets
without calling `.as_spot()`. Proposal presented, not accepted yet: record
type chosen at the composition root (exclusive requirement as a bound such as
`M: SpotMarketTrait`), `AsKind<K>` + `iter_kind::<K>()` for mixed
repositories, `Visit<K>`/`Accept<V>` replacing `dispatch` so a handler must
cover every kind its record can hold, and a `market_set!` macro for records
holding a subset of kinds.

### D8. Price steps: steps 1 and 2 implemented (2026-10-06, not committed)

Follows D2-D5. The user chose "Steps 1 and 2" for the code update.

- market-info: `price_grid::PriceGrid { Fixed(Price), SignificantFigures
  { figures, max_decimals } }` with `min_px_inc(px)` and `finest_px_inc()`.
  `MarketInfoTrait::price_grid()` is required; `min_px_inc(px)` is a provided
  method. `Banded` is not added yet (step 3, with options).
- Globex and Drift markets hold `PriceGrid::Fixed`. Globex market files keep
  `min_px_inc: "0.25"`; the `price_grid: Fixed(..) / Vtt(n)` file shape comes
  with step 3.
- Hyperliquid markets build `SignificantFigures { figures: 5, max_decimals:
  MAX - sz_decimals }` in `try_new`, which no longer takes a tick. Removed:
  `update_mid_price`, `live_min_px_inc`, `compute_min_px_inc`, `floor_log10`,
  `HlMarketInfoError::ZeroPriceIncrement`, the store field
  `minimum_price_increment` (stripped from 542 Hyperliquid RON files), and
  `hl-market-list-gen`'s allMids fetch, `TickInput` / `snapshot_tick` and the
  tick change detection. The untracked `crates/hl-market-list-gen/tests/`
  directory (fixtures, incl. `all-mids.json`) was left in place.
- Archive schema hash now 0x5e3e_2f66_a268_fb1f; `market-info.rkyv` rebuilt.
- strats_v2: `compute_valid_px(px, side, mkt_info)` uses
  `numerics::price_math::snap_to_outside_tick` with the step at `px`: bid
  rounds down, ask rounds up. Previously it truncated toward zero with a fixed
  tick for both sides.
- client-core keeps the API field `minimumPriceIncrement`, filled with
  `price_grid().finest_px_inc()`, so the TypeScript client contract is
  unchanged. Exposing the full grid to the client is open.
- Callers updated: coin-api tests, backtest-post-processor `asset_repo.rs`.
- Pre-existing failures seen, not caused by this: client-core
  `price::registry` tests expect the old MBTU6 contract id
  `cntr_89HQTP9GJKMWC`; realtime-gateway, logger2 tests, discord-webhook and
  notify-gw do not compile.

### D9. Price steps come from a separate price rules catalog (2026-10-06)

Replaces the per-market `PriceGrid` of D3 and the `price_grid()` /
`min_px_inc(px)` market methods of D8. The user said `price_grid()` should
not be public API, then asked to treat market info as pure data with no
compute, then proposed "a reference into the lookup table", a newtype, with
the table "populated differently from the market info". Accepted: "There is
a separate source where the logic handles the price increments. It's not
attached directly to market info."

- Market info holds only `PriceRuleId` (newtype, e.g. `"cme-vtt-17"`,
  `"hl-5sf-3dp"`, `"fixed-0.25"`). No venue-specific variants, no step logic
  in market info.
- A price rules catalog, filled separately (like trading schedules), holds a
  band table per rule: sorted bands covering every price, each with a step
  and which side owns its edge (CME: 20.00 in the lower band; Hyperliquid:
  100 in the upper band). Fixed ticks are one-band rules. Hyperliquid's
  5-figure rule becomes at most 9 tables (one per max decimals 0-8), written
  by hl-market-list-gen; CME fixed rules from tag 969 by cme-market-info-gen;
  CME VTT tables from the wiki / RDA.
- `step_at(rule, px)` and side-aware rounding live with the rules catalog,
  not on market info. The catalog build refuses unknown rule ids, gaps or
  overlaps, and band edges that are not multiples of the steps on both sides.
- Client summary: carry the rule id instead of `minimumPriceIncrement`
  (proposed with this design; client side not yet decided in detail).
- Open: where the rules catalog lives (module in the market-info crate like
  `trading_schedule`, a separate crate, or a separate repo).

### D10. Price rules catalog implemented (2026-10-06, not committed)

Implements D9. The user: "no fucking JSON for storage" (RON only), "I like
the idea, implement it". Replaces the D8 `PriceGrid` code.

- market-info: `src/price_rule.rs` with `PriceRuleId`, `PriceBandEdge
  { Below, Through, Unbounded }`, `PriceBand { up_to, step }`,
  `PriceRuleRecord { id, bands }` (serde + rkyv, the file format) and
  `PriceRuleRepository` (`try_new` validates, `step_at(id, px) ->
  Option<Price>`). `MarketInfoTrait::price_rule() -> &PriceRuleId`;
  `min_px_inc` removed. Globex params, Hyperliquid `try_new`, Drift configs
  and mocks take a rule id.
- No dated revisions yet: every rule has one version today; dated revisions
  come with the CME VTT tables (D4 picks the version at build).
- Store: `price-rules/<id>.ron`, `PriceRulePath`, catalog errors
  (UnknownPriceRule, InvalidPriceRule, DuplicatePriceRuleId,
  PriceRulePathMismatch), `MarketInfoFile.price_rules` in the archive; schema
  hash 0xe67c_13b2_5976_c1f4.
- Generators: cme-market-info-gen writes `fixed-<tick>` rules (14 files);
  hl-market-list-gen writes `hl-5sf-<0..8>dp` tables from the formula.
  Migrated 140 CME and 542 Hyperliquid market files.
- strats_v2: `PriceRuleRepository` built from the archive in `rt_config.rs`,
  held in Init/Ready state, passed to `compute_valid_px(px, side, mkt_info,
  price_rules) -> Option<Price>`; an unknown rule logs
  `target_executor.order.price_rule_not_found` and skips the place.
- client-core summary: `priceRuleId` replaces `minimumPriceIncrement`;
  stxr-client-app TS type, test fixture and generated skill reference updated.
  Not done: `stxr-client-app/client/client_core.d.ts` needs a wasm rebuild
  (`just build` in `client/`, which also force-adds build output).
- Not done: CME VTT tables (with options work); a reviewed VTT source input,
  if added, must be RON.

### D11. Price rule id is a computed number, with a display name and description (2026-10-06)

The user: "I would rather use a u32/u64 id and a display name", then "I need
an id, display name, description for sure", "option one - computed".
Reason given: a file like `fixed-0.0078125` (1/128, ZF Treasury notes) says
nothing about what it is.

- `PriceRuleId` becomes a numeric newtype (u64 proposed, prefixed text form
  like `asst_` / `inst_`), computed by hashing the bands, so identical tables
  share an id and two generators cannot collide. Changing a table yields a new
  id; generators re-point their markets.
- Every rule file carries `display_name` and `description`: generator
  defaults, curated by people, preserved on regeneration, not hashed.
- Rejected: ids assigned through a ledger (stable across edits, but needs
  allocation and coordination between generators).
- Not implemented yet.

### D12. Naming: tick for price, lot for quantity; "tick table" (2026-10-06)

The user: "then use tick", "tick is for prices, lot is for qty", and asked to
add both to the knowledge-base glossary (done: REF:glossary, Lot and Tick).

- Rename price rules to tick tables: `TickTableId`, `TickTableRecord`,
  `TickRange { up_to, tick_size }`, files `tick-tables/<id>.ron`, market
  field `tick_table`, lookup `tick_size_at`. "Band" is dropped: it reads as a
  price limit (CME price banding, RDA `priceBand`). "Tick rule" is avoided:
  it also names the US short-sale uptick rule and a trade-sign test.
- Quantity steps keep lot naming (`min_qty_inc` is the lot size).
- Combined with D11 (computed numeric id, display name, description).

### D13. Tick tables implemented (2026-10-06, not committed)

Implements D11 and D12, replacing the D10 price rules code.

- market-info `src/tick_table.rs`: `TickTableId(u64)` via the `DomainId`
  derive (prefix `tick`), computed by `TickTableId::of(ranges)` with
  `IdHasher` seed `0x7449_434B_5441_424C`; range end tags Below=1, Through=2,
  Unbounded=3 are hash inputs; prices hashed as normalized decimal text.
  `TickTableRecord { id, display_name, description, ranges }`,
  `TickRange { up_to: TickRangeEnd, tick_size }`, `TickTableRecord::fixed`.
  `TickTableRepository::tick_size_at(id, px)`; validation also checks the
  declared id equals the computed id and that both names are non-empty.
  `MarketInfoTrait::tick_table() -> TickTableId`.
- Store: `tick-tables/<id>.ron`, file stem is the id text; archive field
  `tick_tables`; schema hash 0x6e34_4d01_c048_2b63.
- Generators keep curated display names and descriptions of existing tables.
  CME: one fixed-tick table per tick (14). Hyperliquid: one table per decimal
  limit 0-8 (9). 682 market files point at the computed ids.
- Consumers renamed: strats_v2 (`TickTableRepository`, event
  `target_executor.order.tick_table_not_found`), client-core and
  stxr-client-app `tickTableId`, test fixtures in trade, sim-gw,
  databento-mkt-data, backtest-post-processor.


## Facts gathered: catalog size, ids and consumers (2026-10-07)

- Checked-in `secdef.dat.gz` today: 1,077,901 lines (OOF 894,259, FUT
  152,175, MLEG 31,406). User-defined (9779=Y): 166,523 OOF, all 31,406
  MLEG, 1,493 FUT.
- Listing rate estimated from the snapshot (active count / lifetime from
  tag 865 events 5 and 7, lifetimes floored at 1 day): exchange-listed options
  about 18k/day (6.5M/year), futures about 800/day; user-defined options about
  118k/day and user-defined spreads about 31k/day (overestimates, most live a
  day or less). 2010-2026 exchange-listed CME Group instruments: at most about
  100M; with user-defined instruments, several hundred million.
- Ids: XXH64, one seed per id kind, all 64 bits are hash output (the
  venue/type tag is a hash input, not reserved bits). P(any collision) for n
  ids is about n^2 / 2^65: 1e8 -> 0.03%, 1e9 -> 2.7%, 2e9 -> 10%, 50% at about
  5.1e9. Reserving 8 bits for a tag would make 1e8 ids in one 56-bit space
  about 6.7%.
- Duplicate ids are already refused by the catalog build, the ledger guard,
  both generators and the runtime repositories.
- Widening ids: `DomainId` is a single u64, 24 proto files, ClickHouse
  columns, warehouse paths and price subject keys carry the u64.
- Every service loads the whole `market-info.rkyv` at startup into an
  immutable fixed-capacity repository (event-gw and sim-gw cap 1024,
  Databento server and download job 4096). The client bundles its own copy.
  market-info-server is a NATS request/reply prototype with a linear filter
  over the archive; nothing calls it.

## Proposal presented: storage and serving at options scale (not accepted yet)

- Ids: keep the computed u64. One registry enforces uniqueness on insert; a
  collision stops ingestion and is fixed by an override entry in
  market-info-core keyed by identity fields. No u128, no reserved tag bits.
  Do not catalog user-defined instruments up front.
- Storage: git RON keeps curated, low-volume records (assets, schedules, tick
  tables, per-product option/future rules). Generated per-instrument records
  (options, historical futures) live in a database owned by
  market-info-server (Postgres: unique key on instrument id), with listing
  windows and dated attribute revisions. Filled from Databento definitions,
  daily and as a 2010+ backfill.
- Serving: consumers stop loading the whole catalog. They fetch slices (venue,
  product or underlying, as-of time or window) as rkyv archives in the
  existing format, look up misses by id, and receive new listings as a change
  feed. Backtests record the slice they ran on.

## Proposal presented: log, folded revisions, live set (2026-10-07, not accepted yet)

The user split the problem into a historical log and the state now, wants
snapshots (not events) returned for queries like "all ES futures since 2010",
keeps staff additions (display_name) as events, and weighed flat files,
Postgres, DuckDB on ephemeral disk with RAM/SSD tiers, and RocksDB-like
stores. Proposal:

- The fold runs once per instrument at write time, not per query. Stored
  shape: per-instrument revisions `[valid_from, valid_to)`; a new revision only
  when a field changes. Daily 00:00 UTC definition snapshots repeat every
  listed instrument and must be diffed away. A list query returns one revision
  per instrument (at `as_of`, default its last).
- Logs (source of truth): venue definitions from the historical data service;
  staff overlay events (latest wins per instrument or product, history kept for
  audit), merged at read, so no ordering between the two logs is needed.
- Folded revisions: Parquet in GCS partitioned by venue/kind/product, written
  by a fold job (compaction). History queries read one partition through
  DuckDB inside market-info-server.
- Hot/cold split by listing time, not popularity: markets listed now (about
  1M rows, a few hundred MB) in RAM, booted from a checkpoint tagged with log
  positions plus replay of the log tail. Expired markets stay cold in Parquet.
- Rejected for now: rebuilding a DuckDB file from the raw log at boot (billions
  of daily records); an embedded KV store (own indexes, checkpoint upload and
  restore, compaction tuning, for a lookup rate history does not have).
  Postgres stays the fallback if many writers or transactional edits appear.
- Gaps found: the download job's daily `definition` object holds only the
  wanted markets' records, not the whole venue; Cloud Run ephemeral disk is
  documented in REF:cloud-run for jobs only (BETA, >= 10Gi).

## Proposal presented: per-instrument change lists, packed per product (2026-10-07, not accepted yet)

The user asked why not keep each instrument's few changes in one file and
replay them on load. Answer given:

- Agreed on the record shape: each instrument keeps its own short list of
  changes, read by replaying them. Each change stores the full definition (a
  Databento definition is full state), so reading at time t picks the last
  change at or before t.
- Rejected one GCS object per instrument: about 1M objects to fetch on every
  boot of every replica (minutes, growing with listings); no append on GCS, so
  each change rewrites an object; a day's changes to thousands of instruments
  cannot land at once; queries across instruments need an index outside the
  object names.
- Proposed: pack the per-instrument lists by product, one file per
  (venue, kind, product), instruments sorted inside. New days arrive as small
  extra files per product and are merged periodically. Thousands of files
  instead of millions; "ES futures since 2010" reads one file.
