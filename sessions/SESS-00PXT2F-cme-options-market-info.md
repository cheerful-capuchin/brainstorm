---
create_time: 2026-10-06T07:20:47Z
title: "CME options in market info"
summary: "Options domain (D14-D19), id hash venue+type (D21), Databento migration (D22-D24, D27; D51: 840 folders copied and verified, old folders not deleted), consumers (D25), #[kind] derive (D26), backtest feed (D28), review fixes, docs, IdHashInput, asset ids in market-info-core, CME data in cme-globex (D29-D38). 2026-10-10: market-info-core #19 merged; instruments typed by market + venue kinds + MarketInfo::Option (D40, DEC-0CDBZ proposed); option arms downstream (D41); portfolio value on contract terms (D42); trading schedules in market-info-repo (D43). D45: pushed and in PRs (market-info-core #20 new, market-info #27, trade #14, backtest-post-processor #14, sim-gw #16, databento-mkt-data #5, event-gw #16, knowledge-base #137); not committed: option arms and schedule repo in application-server, client, dsl-runtime, strats_v2, structure-strat-template-core (need market-info-release branches). D46: structure-web salvage of the deployment branch (logs event_time #172, small fixes #173 merged; Avro waits). D47: snowflake backtest ids + per-start/per-backtest limit_order_offset_bps, 11 PRs open (template-core #29, structure-web #174/#175, infra #29, dfd #13/#14, domain #20, dsl-runtime #27, strategy-core #16, dsl-processor-core #18, structure-sdk #1). D48: msg-schemas #31 + messaging #52 remove ComputeBacktestIdRequest; KB #138 (DEC-0CDPA, DEC-0CDPB); protocol Backtest response carries the offset. D49: Avro blobs #176 with backtests.strategy_config; #175 force-pushed (offset in StrategyConfig, no column); strategy-core #17 node mappings; drop-strategies.sql. D50: deployed to production (template #9, runtime d5c6044, migration, pulumi up)"
related_sessions:
  - SESS-00RR74R
agents:
  - claude-code:47546fef-123a-48ba-86d5-074d82bf7c20
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

### D14. Option instruments implemented (2026-10-08, not committed)

The user asked to create the instruments first: the instrument trait must
carry the venue, then CME Globex option instruments.

- market-info-core: `InstrumentTrait::venue() -> Venue` (required); the
  inherent `venue()` on Globex futures moved onto the trait. Drift and
  Hyperliquid structs return their venue constant.
- `InstrumentType::OPTION = 3` (serde/Display `option`); `InstrumentIdTag`
  `CmeOption..ComexOption = 9..12`.
- `GlobexOption { product_code, maturity, put_or_call, strike_price,
  venue_symbol }`, `GlobexVenueOption<V>` with `CmeOption`, `CbotOption`,
  `NymexOption`, `ComexOption`. Id inputs: option tag, product code, maturity
  (same encoding as futures), put/call byte, strike mantissa (`IdHasher::i64`).
  Underlying (tag 309) is not identity. Checked on the snapshot: (MIC, 6937,
  200, 201, 202) is unique across all 699,458 exchange-listed options.
- `GlobexVenue` and the shared maturity hashing moved to
  `instrument/globex.rs`; future ids unchanged (golden test still passes).
- cme-globex: `PutOrCall` (tag 201, Put = 0, Call = 1) and `StrikePrice`
  (tag 202, raw `PRICENULL9` mantissa, null rejected, text form is the
  shortest decimal, e.g. `"-450"`, `"108.5"`).
- market-info: `MockInstrument` implements `venue()` via the trait;
  market-info-repo dense `InstrumentType` index has 4 slots.
- Not updated (exhaustive matches on `InstrumentType` that need an options
  decision): trade_v2 `position.rs` / `order/manager.rs`, trade-core
  `position/tracker.rs`, backtest-post-processor `duckdb_artifact/codes.rs`,
  messaging `conversion.rs`, hyperliquid `hl-mkt-info-service`.

### D15. OptionType in common, u16 id tag, ids regenerated (2026-10-08, not committed)

The user: keep `PutOrCall` as the CME name, add a venue-neutral `OptionType`
to `common` (like `Side` / `TradeSide`), convert with `From` in cme-globex;
the instrument id tag is `u16`, breaking ids is fine for now.

- common: `option_type::OptionType { Put = 0, Call = 1 }`, `repr(u8)`
  like `Side` (the user: "put is zero value"). cme-globex depends on `common` and has
  `From<PutOrCall> for OptionType` and back. `GlobexOption` still stores
  `PutOrCall`. Later the user set `Put = 0, Call = 1` ("put is zero value")
  and, after weighing `OptionRight` ("the right an option gives"), kept the
  name `OptionType` ("nevermind").
- market-info-core: `InstrumentIdTag` is `repr(u16)` and hashed with
  `IdHasher::u16`. Every instrument id changed; 12 golden values updated.
- market-info: 140 CME market files re-annotated (`instrument_id`,
  `contract_id`), `markets.csv` and `market-info.rkyv` rebuilt;
  `EXPECTED_SCHEMA_HASH` 0x86e3_fa63_c6a2_35c8 (the fixture hash covers id
  values). Backup of the old tree: `/private/tmp/mi-build/assets-backup-*`.
- Not regenerated: client-core `build/release/market-info.rkyv` (client and
  stxr-client-app), configs and fixtures elsewhere that hold old ids.
- Null strike: CME's tag usage page sends 202 only for option outrights;
  option spreads and UDS combos also have 167=OOF but no 202 and carry legs.
  Snapshot: all 699,458 exchange-listed and 56,864 user-defined outright
  options carry 202; 33,993 user-defined option spreads (762 = VT, GN, SG...,
  with 555 legs) do not. In SBE, spreads come in message 56, so in message 55
  the null should not appear; `StrikePrice` keeps rejecting it. The doc
  comment on `StrikePrice` cites the tag usage page and explains this.

### D16. Option market domain types (2026-10-08, not committed)

The user: define the option market types, `ExerciseStyle` in common; no RON
or storage yet (text files are not the place for option data; the user is
building the storage); market-kind exposure (D7) is another agent's work.

- common: `exercise_style::ExerciseStyle { American = 0, European = 1 }`.
- market-info `src/market_info/option.rs`: `OptionSettlementMethod { Cash,
  PhysicalDelivery }`, `OptionValuationMethod { PremiumStyle, FuturesStyle }`
  (FIX 1197, FPRF `SeriesValMeth`).
- `traits::OptionMarketTrait: DerivativeMarketTrait` with `activation_time`,
  `trading_termination_time`, `option_type`, `strike_price -> Price`,
  `exercise_style`, `settlement_method`, `valuation_method`.
- `Underlying::Contract(ContractId)`; store schema hash unchanged.
- `globex/option.rs`: `GlobexOptionMarketInfo<V>` + params + error
  (thiserror), aliases `CmeOptionMarketInfo`..`ComexOptionMarketInfo`;
  underlying always `Underlying::Contract`, rejects an option naming its own
  contract. No rkyv/serde derives (storage open).
- Facts: every outright option's tag 309 is a FUT (432,886 on CFI `FC`,
  208,772 `FF`, 114,664 `FX`); no bond, spread or option underlyings. Option
  CFI (tag 461): char 2 C/P, char 3 A (339,510) / E (416,812), char 4 F or X,
  char 5 always P, char 6 always S. CFI is the secdef source for exercise
  style; settlement and valuation need the FPRF.
- No VTT table files exist on any market-info branch or stash; only the
  "CME VTT 17" table in the market-info-store fixture.
- Not updated: `Underlying` matches in application-server `data.rs`,
  client-core `market_info.rs` / `market_info/catalog.rs` (client and
  stxr-client-app).

### D17. Lot tables, module only (2026-10-08, not committed)

The user: "similarly to tick table, I want to have the lot table"; the lot
size might depend on some factor. Chosen: module only (no trait, market,
RON, archive or consumer wiring while another agent rewrites
`MarketInfoTrait`); each range carries lot size and minimum ("the min lot qty
may change in case there is some threshold reached"). Revises D5 (quantity
rules no longer fixed).

- market-info `src/price_range.rs` (private): `PriceRangeEnd` (moved from
  tick tables; `tick_table::TickRangeEnd` stays as a re-export alias for the
  store, generators and strats_v2 until they are renamed), id hash encoding,
  `check_range_ends`. Tick table ids unchanged (`mkt-info-gen check` up to
  date).
- `src/lot_table.rs`: `LotTableId` (prefix `lot`, seed `0x4C4F_5454_4142_4C45`
  "LOTTABLE"), `LotRange { up_to, lot_size, min_qty }`, `LotTableRecord`
  (`fixed(lot, min)`), `LotTableError` (thiserror), `LotTableRepository::
  lot_range_at(id, px) -> Option<LotRange>`. Rules: min_qty positive and a
  multiple of lot_size; no range-end-on-lot rule (ends are prices).
- Next, when the trait settles: `MarketInfoTrait::lot_table()` replacing
  `min_qty_inc()` and `min_qty()`, `lot-tables/` in the store and archive,
  generators, strats_v2 / sim-gw quantity rounding. Hyperliquid minimum
  order value stays a separate rule.

### D18. Tick and lot table repositories moved to market-info-repo (2026-10-08, not committed)

The user: "move the repos into the repo crate" (the market-kind agent had
stopped).

- market-info keeps the records as data: `TickTableRecord::validate()` /
  `tick_size_at(px)`, `LotTableRecord::validate()` / `lot_range_at(px)`.
  `TickTableRepository` and `LotTableRepository` structs and the
  `DuplicateId` error variants are gone from market-info.
- market-info-repo: `tick_table` / `lot_table` modules with `ByTickTableId`
  / `ByLotTableId` primary keys, `FixedTickTableRepository<S>` /
  `FixedLotTableRepository<S>` aliases of the core `FixedRepository`,
  `from_records(records)` (validates each, sizes the repository to the
  records, duplicate id -> `TableLoadError::Duplicate`), and the traits
  `TickTableRepository::tick_size_at(id, px)` /
  `LotTableRepository::lot_range_at(id, px)`, blanket-implemented over
  `Repository<_, Primary = By*TableId>`. Shared loader in private `table.rs`.
  `numerics` is now a regular dependency of market-info-repo.
- market-info-store catalog validates with `record.validate()`;
  hl-market-list-gen tests use the record methods.
- Not migrated: strats_v2 (`TickTableRepository::try_new` ->
  `FixedTickTableRepository::<HashIndex<TickTableRecord, ByTickTableId>>::from_records`,
  import the `TickTableRepository` trait from market-info-repo). strats_v2 is
  already broken by the removed `market_info::mkt_info_repo` (67 uses).

### D18a. `RepositoryCapacity::markets_max` renamed to `records_max` (2026-10-08, not committed)

The user: "rename the RepositoryCapacity markets_max to records_max". The field
bounds records of any kind (markets, assets, tables).

- market-info-repo: field, docs, tests, bench, usage example; the "keeps its
  historical name" note removed.
- Call sites that build a capacity: sim-gw (`init.rs`, `data.rs`, e2e
  fixtures), event-gw `market_info_repo.rs`, application-server `mkt_info.rs`,
  strats_v2 `target_executor/mkt_info.rs`, dsl-runtime `mkt_info.rs`, trade
  coin-api `generate.rs`, databento-mkt-data-server `main.rs` and one test,
  client-core `catalog.rs` (both copies).
- Kept as `markets_max`: each service's own config key (sim-gw, event-gw,
  databento and runtime config structs, YAML, infra Pulumi, dev-docs
  configuration guide); call sites read `records_max: config.markets_max`.
  Skipped the untracked `strats_v2/component.debug.rs`.

### D19. Options kind, lot tables wired, consumers, knowledge base (2026-10-08, not committed)

The user: (1) add the options market kind; (2) wire lot tables into markets,
no `min_notional` in lot ranges; (3-5, 7) no storage, generator or data for
options; (6) fix option matches except hyperliquid, no trading logic;
(8) update the knowledge base.

- market-info: `OptionMarketInfo` enum (Cme/Cbot/Nymex/Comex) in
  `market_info/option.rs` with `try_new_globex`, all traits;
  `GlobexOptionMarketInfoError::UnsupportedVenue`. market-info-repo: `Options`
  kind (`repository.access(Options)`), usage test `market/tests/options.rs`.
- `MarketInfoTrait::lot_table() -> LotTableId` replaces `min_qty_inc()` /
  `min_qty()`; Globex params `lot_table` (lot 1, minimum tag 562); HL
  `try_new(.., tick_table, lot_table, ..)`; Drift configs `lot_table`;
  `lot_table::PriceRangeEnd` re-exported. Store: `lot-tables/<id>.ron`,
  `LotTablePath`, `LotTableSource`, `MAX_LOT_TABLES`, catalog errors, archive
  `lot_tables` / `lot_table_count`; schema hash 0xc3b9_ae46_3cd0_607f.
  Generators: cme `whole_contract_lot_table(min_qty)`, `GeneratedMarkets`;
  hl `lot_table` module (one table per szDecimals 0-8, lot = min =
  10^-sz). Catalog migrated offline: 140 CME + 542 HL files, 9 lot tables
  (CME lot 1 / min 1 equals HL 0 decimals; neutral names), archive rebuilt,
  `markets.csv` unchanged.
- Consumers: client-core summary `lotTableId` replaces
  `minimumQuantityIncrement` / `minimumQuantity` (client/ only); fixtures in
  trade-core, coin-api, databento (3), sim-gw e2e, backtest-post-processor.
  Not migrated: strats_v2 quantity rounding (`calculation.rs`,
  `execution.rs`, test helpers); stxr-client-app's embedded client-core is an
  older checkout (still `min_px_inc`).
- Item 6 (subagent): trade_v2 / trade-core return `BadInstrumentType` or new
  `OrderManagerError::UnsupportedInstrumentType` for options; DuckDB artifact
  code 3 (schema.sql, client mapping); `StxrUnderlying::Contract`; messaging
  already handled. Compiled only in a scratch copy with stand-ins.
- Knowledge base (on branch dec-per-kind-market-info-repository, working tree,
  not committed): DEC-0CAHA (tick and lot tables), DEC-0CAHB (CME Globex
  options); REF:instrument, REF:market-info, REF:glossary (lot table) updated
  with provenance rows. Left: DEC-0AB71 documents instrument_type 0-2
  (append-only); SPEC:backtest-feed `MarketInfoView` still lists
  `min_px_inc` / `min_qty_inc` / `min_qty`.

### D20. Market info server direction, decided elsewhere (2026-10-08)

The user, in dev-env annotations: markets will live in a database behind
market-info-server, with no RON files and a GUI to inspect markets (like
`cme-globex/tools/secdef-viewer`); parsers in the server replace the
generators. Asked about follow-ups (which database, revisions, how consumers
get markets, which source the parsers read), the user said these are not
decided in this session but in a different one. Not open questions here.

### D21. Instrument id inputs: venue and instrument type (2026-10-08, not committed)

The user asked whether to hash the u8 instrument type and the venue instead of
the u16 `InstrumentIdTag`, since both are required parts of `InstrumentTrait`;
accepted ("Yeah").

- market-info-core: `InstrumentIdTag` removed. `instrument_id_hasher(venue,
  instrument_type)` hashes `venue_id_code` (u8, the messaging `Venue` enum
  numbers: Structure 0 ... Cme 9, Cbot 10, Nymex 11, Comex 12) then
  `instrument_type_id_code` (u8, SPOT 0 ... OPTION 3); both private, marked as
  hash inputs. Globex structs pass `V::VENUE`; Drift and Hyperliquid use a
  module `VENUE` const shared with their `venue()`. `GlobexVenue`'s sealed
  trait lost its hasher methods. 12 golden ids updated.
- market-info: CME annotations stripped, catalog rebuilt with
  `--allow-id-change`, 140 files re-annotated from `markets.csv`, rebuilt;
  `mkt-info-gen check` up to date; `EXPECTED_SCHEMA_HASH` 0xab00_24b2_a679_ba72.
  Backup of the old tree: `/private/tmp/mi-build/assets-backup-20261008-174252`.
- Every instrument id changed again; ids outside market-info (configs,
  fixtures, client rkyv) are still old.
- Not taken: `Underlying::Ticker` -> `Reference` rename (user: needs more
  thought); `FixedRepository` -> `Store` rename (user: no).

## Proposal presented: reading without missing updates (2026-10-08, not accepted yet)

The user asked how a reader avoids missing an update that arrives while it
reads the files. Answer given:

- One writer gives every change (venue or staff) the next sequence number and
  appends it to a durable log that can replay from a given number (NATS
  JetStream proposed: per-stream sequence, start-from-sequence delivery).
- Files are never edited in place. The writer adds new files, then swaps a
  manifest with a GCS generation precondition. The manifest records the last
  sequence its files cover (S). Replaced files are deleted only after a grace
  period, so readers holding an old manifest can finish.
- Reader: read the manifest (S), load its files, then replay the log from
  S + 1 and keep following it. Anything written after the manifest has a
  number above S, so nothing falls in between. Skip numbers already applied;
  a gap means re-request from the last applied number.
- The same contract holds one level up: a slice from market-info-server
  carries its sequence, and the consumer follows the change feed from there.
- Ingest: a market update exists for readers only once it is in the log. After
  an ingest crash, re-read Databento (the weekly session replay with start=0)
  and drop records equal to the instrument's last change, so re-ingesting is
  harmless.

## Facts gathered: stored data keyed by instrument id (2026-10-08)

The user asked what historical data depended on the instrument id hash after
D21 ("I broke the hashing of the instrument id"), guessing Databento file
names and backtests; backtests can go while in the demo.

- Every id changed between the deployed catalogs and the current one: 140 CME
  Group futures and all 542 Hyperliquid markets. Infra pins market-info
  `b34b5df` in production and `a7c65b6` in dev (`market_info:revision` in
  `infra/infra/Pulumi.{production,dev}.yaml`), uploaded as
  `mkt-info/market-info.rkyv` to the config bucket and read by sim-gw,
  event-gw, target-exec, the Databento server and download job, the
  application-server and backtests. Example: ESU6 `inst_6297ED0JB67DD`
  (b34b5df) -> `inst_DQV390JWC74KJ`.
- Old -> new mapping, matched by market file path between `b34b5df` and the
  current `assets/markets.csv`: all 682 markets in
  `/private/tmp/inst-id-remap/instrument-id-map.csv` (text and u64 forms,
  contract ids too); the 140 CME Group rows are checked in with the copy
  script (D24).
- Databento MBP-1 files: `gs://stxr-prop-asia-historical-data-qmdzj/data/`
  (download job `directory: data`)
  `databento/GLBX.MDP3/mbp-1/{InstrumentId}/{YYYY-MM-DD}.dbn.zst`, 140 folders,
  9,232 files, 129.6 GB; all 140 folder names are b34b5df ids, none are new
  ids, none are unknown. Day markers `.../definition/{YYYY-MM-DD}.dbn.zst`, 68
  days, 2026-08-01 to 2026-10-07. The path is built by the shared
  `databento-hist-layout` crate (structure-strat-template-core), used by both
  the download job and the strategy replay (`hist_replay.rs`, which fails with
  `MissingFile` when a day's file is absent).
- The file contents hold Databento's own instrument ids (CME security ids),
  not ours, so only the folder names are stale.
- The download job plans days by marker only: a day with a marker is skipped
  unless `--overwrite=always`. The marker path has no instrument id, so after
  the catalog bump the job would never refill old days under the new ids.
- Hyperliquid live market data in the same bucket:
  `{dataset}/live_md_server/{u64 id}/YYYY/MM/DD/*.arrow`
  (`hist-data-common/src/warehouse_utils.rs`, writer `mkt_data_persister`,
  `subject` column `md.instruments.<u64>.*`). The local mirror folder
  `2389587362508017378` matches neither catalog, so it was already orphaned
  by an earlier id change.
- ClickHouse event-gw tables store ids as UInt64: `target_positions`,
  `fills`, `demo_fees`, `position_updates`, `account_trading_volume`,
  `account_position_aggregate`. event-gw seeds its accounting from them at
  startup and `resolve_market(...)?` returns `UnknownInstrument` on an old id
  (`event-gw/.../logic/accounting_seed.rs`), so event-gw will not start on the
  new catalog until those rows are gone.
- sim-gw snapshot (`stxr-prop-asia-engine-snapshots`, `/mnt/snapshots/sim-gw`)
  stores raw u64 instrument ids (`snapshot/v1.rs`); production has
  `sim_gw:allow_cold_start: "false"`.
- Backtests: `stxr-prop-asia-backtests-gj7u4` (`results.duckdb` with
  `inst_`/`cntr_` text, `feed.bin`, `target-positions.jsonl`); app-db
  `backtests.arguments`, `strategy_spec_arguments`,
  `strategy_variable_bindings`; strategy revisions in
  `strategy_revisions.arguments` and `stxr-prop-asia-user-strategies` YAML,
  including the four paper strategies deployed 2026-09-18 (ESZ6, NQZ6, CLX6).
- NATS subjects `md.instruments.<u64>.*` and Databento feed ids (hash of the
  instrument subject) change too: publishers and subscribers must switch
  catalogs together. Nothing stored.
- Configs and bundled copies with old ids: infra test backtest
  `infra/infra/strategies/tests/backtest-config.ts:41`
  (`inst_2RCH3R49FDADF`); client price sources `databento-contracts-v1.jsonl`
  (155) and `registry-v1.json` in client and stxr-client-app; coin-api
  `coin-api-price-sources.jsonl` (177); both bundled client
  `market-info.rkyv`.
- Test fixtures with old ids (not changed): client and stxr-client-app
  client-core price tests, stxr-client-app TS tests, structure-web e2e
  `collection.ts` / `config.ts` and `native-fixture.ts`, application-server
  test and `market-info.test.rkyv`, domain `crates/id`, dsl-runtime
  parameters tests, data-feed-definitions `databento_mbo_feed.rs` (expected
  feed id), the download job's `types.rs` / `transfer.rs` tests,
  backtest-post-processor `mnt/backtests/bt_0VSTTPV0YCXPE`.

### D22. Only the Databento data is kept (2026-10-08)

The user: "hyperliquid data we don't care about"; "event gw and sim gw data
we don't care about, I can purge it" (the user purges ClickHouse and the
sim-gw snapshot); backtests and strategy revisions can go while in the demo.
The Databento MBP-1 files are the only stored data to migrate.

### D23. Checked-in historical data renamed (2026-10-08, not committed)

The user: "local checked in files you should rename and fix".

- structure-strat-template-core, `git mv` in both `test_data/` and
  `mnt/historical-data/` under `databento/GLBX.MDP3/mbp-1/`:
  ESU6 `inst_6297ED0JB67DD` -> `inst_DQV390JWC74KJ`; CLV6
  `inst_4NKTGSW9TJ0AX` -> `inst_4NSBJZ2DYBV56`. The CLV6 folder already
  carried a stale id from market-info `8aa0bc5` and no code referenced it.
- Old ESU6 id replaced in `src/hist_replay.rs`,
  `src/hist_replay/dbn_file_stream.rs`,
  `crates/databento-hist-layout/src/lib.rs`, `src/bin/download_hist_data.rs`,
  `src/bin/slice_hist_data.rs`, `README.md`, `justfile`,
  `mnt/local_dev/strat_config.yaml`. No old id left in the repo.
- `databento-hist-layout` tests pass (5). `hist_replay` tests not run: the
  crate does not compile because data-feed-definitions
  `demo/backtest_feed.rs` still imports the removed
  `market_info::traits::MarketInfoType` (market-info rework, not this change).

### D24. Databento folders are copied, not re-downloaded (2026-10-08, not run)

The user asked "how do we fix the databento?" and to keep the script in the
databento repo under `misc`.

- Script: `databento-mkt-data/misc/instrument-id-remap/copy_mbp1_folders.py`
  (standard library only, shells out to `gcloud storage`) with
  `instrument-id-map.csv` (140 CME Group rows) beside it. First written in
  shell; the user: "can you write the script in python? parsing csv with
  shell is not something I would trust", so the shell version was deleted.
  The map is read with `csv.DictReader` and refused on missing columns,
  values that are not `inst_` ids, old == new, duplicate ids, or an id that
  is both old and new. Bucket folders in no row are reported and left alone.
  No argument is a dry run (checked: 140 folders); `--run` does a same-bucket
  `gcloud storage rsync --no-clobber` per folder (server-side copy, no
  Databento cost); `--delete` removes an old folder only when every file name
  in it exists in the new folder (checked read-only on TNZ6: 68 files, new
  folder empty).
- Order: (1) `--run` while production still reads the old ids, old folders
  stay; (2) bump `market_info:revision` in infra; (3) `--run` again to copy
  days the job wrote under the old ids in between; (4) `--delete`.
- Rejected: `--overwrite=always` re-download (pays Databento for 130 GB
  again); a plain re-run of the job (skips every day that has a marker).
- `--verify` (added with the trial map, D27) compares every file of the old
  folder with the new one by name, size and CRC32C and exits 1 if any folder
  fails; `--delete` runs the same check per folder before removing it.
  `--map <file>` selects another map with the same columns.
- Not run yet: step 1 writes to the production bucket and waits for the
  user's go.
- Later: the script was renamed `remap_instrument_folders.py`, covers every
  schema, and the full copy ran and verified; see D51.

### D25. Consumers fixed: marketdata, trade, trade_v2 (2026-10-08, committed locally)

The user: fix every dependency on market info, trade and trade_v2 first;
"price provider can go away as well as the AccountSnapshot if they are
unused". Committed on a new local branch `cme-options-market-info` in each
repo, unsigned (the user signs with `just sign_latest_commits`), not pushed.
Their manifests point market-info at `branch = "main"`, so builds outside
the local patch fail until market-info's `cme-options-market-info` is merged.

- Order found from the manifests: marketdata before trade (trade depended on
  it and it imported the removed `mkt_info_repo`); messaging needs nothing
  (feature only, no code use); repos uses market-info in two tests only.
  Next: timeseries-db, sim-gw, event-gw, application-server, client (on
  trade / trade_v2), then dsl-runtime with data-feed-definitions (they depend
  on each other), then structure-strat-template-core, databento-mkt-data,
  dsl-processor-core, strats_v2.
- marketdata `ab0af64`: `PriceProvider`, `PriceProviderError`,
  `EmptyProviderError` deleted, and the logger2, serde and thiserror
  dependencies with them. `MktDataProvider` is unused too but kept (not
  asked). 5 tests pass.
- trade_v2 `afb2d33`: position accessors and `ExecReportHandler` bound
  `IncludesMkt<Spots>`, lookup `market(id)`, spot assets via
  `as_kind(Spots, ..)`; the old `as_spot().unwrap()` is now
  `BadInstrumentType`. A process using trade_v2 needs a spot store, even a
  futures-only one. `DriftVenueContext::market_ids_from_repo` walks the spot
  and perp stores (`IncludesMkt<Spots> + IncludesMkt<Perps>`). Includes the
  D19 item 6 option arms. Fixture: real Hyperliquid spot and perp records in
  a derived `TestMarketInfoRepository` (`MarketRecord` is sealed, mocks
  cannot be stored). `just check` passes (188 tests, default and all
  features).
- trade `4ecfd5a` (trade-core, trade, coin-api; done by a subagent):
  `AccountSnapshot` trait and the marketdata dependency removed. Bounds:
  position tracker `IncludesMkt<Spots>`; portfolio value
  `IndexedMkt<Perps, ByContractId> + IndexedMkt<Futures, ByContractId>`;
  delta tracker `IndexedMkt<Spots, ByBaseAsset> + IncludesMkt<Perps>`; Drift
  helpers and validators `IncludesMkt<Spots> + IncludesMkt<Perps>`, reading
  the Drift record from the kind store; coin-api spots, perps and futures.
  Behaviour changes: the delta tracker no longer counts futures on an asset
  underlying; portfolio value needs both a perp and a futures store
  (`ContractMarketInfoNotDerivative` can no longer happen); coin-api emits
  records grouped by kind; options rejected or skipped; the position tracker
  needs `drop(mktinfo)` before mutating in the perp / future arms. Also fixed
  coin-api generator tests left half-edited by D19 (`Price` import,
  `lot_table` for the removed `min_qty_inc` / `min_qty`). `just check` passes
  (trade 90, trade-core 55, Lean build); coin-api `--features generator`
  passes (36 + 12 + 7).
- Clippy still reports lints in both repos on lines the migration did not
  touch; left alone.

### D26. Derive names each store's kind (2026-10-08, market-info `7d88157`)

Found while porting the trade_v2 fixture: `#[derive(MarketInfoRepository)]`
with two or more stores failed with E0119 in every crate outside
market-info-repo. The derive keyed each `KindStore` impl on
`<Record as MarketRecord>::Kind`; outside the crate, the overlap check does
not resolve a projection through an upstream trait on an upstream type, so
every pair of impls overlaps. Reproduced in a scratch crate; the in-crate
tests passed only because the trait is local there.

- The user chose a field attribute: `#[kind(Spots)] spots: SpotStore`. Made
  by the market-info session (workspace-a8) with a downstream test,
  `crates/market-info-repo/tests/derive_downstream.rs`; `StoredRecord` is
  gone.
- `KindStore` stays a hidden helper ("if it's a hidden helper, then kind
  store is fine") on condition that its doc comment explains what it is and
  why it exists: `insert` needs `store_mut`, and putting it on `IncludesMkt`
  would let callers skip the check that no instrument id is in two stores.
  The comment is in `market/parts.rs` above `KindStore`.

### D27. Trial on five folders first (2026-10-08, not run)

The user: "for a test, create a slice of instrument id map with only like 5
items, so we can verify beforehand. Write the instructions in the session
file and once I'm ready I'll let the agent run it".

- `databento-mkt-data/misc/instrument-id-remap/instrument-id-map.test.csv`,
  same columns as the full map, one folder per venue plus ESU6 (the folder
  the strategy replay uses):

  | Symbol | Venue | Old id | New id | Files | Size |
  |---|---|---|---|---|---|
  | ESU6 | cme | inst_6297ED0JB67DD | inst_DQV390JWC74KJ | 49 | 3.9 GB |
  | SR3M6 | cme | inst_0MDMKM9B7Z0YJ | inst_78CK91HZY38ZY | 46 | 31 MB |
  | TNH7 | cbot | inst_43HJW2FM9BQW2 | inst_D75R7NZP2YZHG | 57 | 1.6 MB |
  | BZU7 | nymex | inst_BRYEMDZRHPRQR | inst_1Y06M299QK3N1 | 63 | 0.1 MB (mostly empty day files) |
  | HGV6 | comex | inst_0EJP1R26M4KFR | inst_26RY3GDXCBYJW | 68 | 2.3 MB |

  Files and sizes as listed on 2026-10-08; the download job may have added
  days since.
- Checked 2026-10-08 before any copy: dry run with the test map lists the 5
  folders and reports "135 folders in no row of the map"; `--verify` with the
  test map fails all 5 ("2026-08-01.dbn.zst missing"), exit 1, because the
  new folders do not exist yet.
- Not a usable check: the checked-in ESU6 files in
  structure-strat-template-core `mnt/historical-data` are not byte-equal to
  the bucket objects (CRC32C `GA103Q==` / `8I9+DQ==` local vs `O11ERQ==` /
  `XM5lww==` in the bucket for 2026-09-10 / 2026-09-11); they came from a
  separate download.

Later: the trial was skipped; the full copy ran directly (D51). The
commands below use the old script name `copy_mbp1_folders.py`.

#### Trial run instructions (for the agent, once the user says go)

Run from `databento-mkt-data/misc/instrument-id-remap/`. Only the five test
folders are touched; nothing is deleted.

1. `gcloud auth list` shows an active account. If gcloud asks to log in
   again, stop and tell the user (it cannot prompt from the agent).
2. Dry run: `python3 -I copy_mbp1_folders.py --map instrument-id-map.test.csv`.
   Expect the 5 rows of the table and `folders: 5`. Stop if the count or the
   ids differ.
3. Baseline: `python3 -I copy_mbp1_folders.py --map instrument-id-map.test.csv --verify`.
   Expect 5 failures with "missing" and exit 1. Any "differs" line, or a
   folder that already passes, means someone wrote to the new folders: stop
   and report.
4. Copy: `python3 -I copy_mbp1_folders.py --map instrument-id-map.test.csv --run`.
   Server-side copy, about 3.9 GB, mostly ESU6.
5. Check: `python3 -I copy_mbp1_folders.py --map instrument-id-map.test.csv --verify`.
   Expect `ok` for all 5 with file counts equal to the old folders and exit 0.
6. Re-run step 4 once more: it must copy nothing new (rsync with
   `--no-clobber`), and step 5 must still pass.
7. Do not run `--delete`. Production (market-info b34b5df) still reads the
   old folders. The new test folders stay; the full run skips their files.
8. Record the outcome under this decision: commands, exit codes, the
   `--verify` output, and anything unexpected.

#### After the trial (each step needs the user's go)

1. Full copy: `--run`, then `--verify` with the default map (140 folders).
2. Bump `market_info:revision` in `infra/infra/Pulumi.{production,dev}.yaml`
   to the market-info commit with the new ids and deploy.
3. Catch up: `--run` and `--verify` again, for days the download job wrote
   under the old ids between steps 1 and 2.
4. `--delete` with the default map.

### D28. Backtest results feed and post-processor on the new market info (2026-10-09, not committed)

The user: fix the data feed definitions (the backtest feed: producer
structure-strat-template-core, consumer backtest-post-processor), then the
post-processor. The user: the post-processor does not need min price or min
quantity, so the Definition carries no tick or lot tables.

- data-feed-definitions `demo/backtest_feed.rs`: `BacktestDefinition::
  MarketInfo` is bounded by `MarketInfoTrait` only (`MarketInfoType` is gone).
  The trait stays generic; the codec and the post-processor's copier pin
  `market_info::MarketInfo`, because the codec writes rkyv archives of it and
  the post-processor branches on kind. Doc comment: tick, lot and schedule
  ids do not resolve within the feed. `just check` passes.
- backtest-post-processor: `BtestMarketRepository` is gone; the run's
  markets live only in a derived `RunMarketInfoRepository` (spots; perps and
  futures with a `ByContractId` index, `from_markets` checks contract ids are
  unique, which the index does not), which the fold passes to trade-core
  `portfolio_value`. The user asked to use the market-info-repo repositories
  instead of keeping a list beside them: the dictionaries and the fold's
  `Markets` terms are built from the Definition's list (its order is what
  dictionary references index) before the markets move into the repository.
  Test catalog: `catalog_markets()` returns the fixture list. The removed
  `MktInfoRepo` impl went (only `iter()` was used); accounting bounds are `IndexedMkt<Perps, ByContractId> +
  IndexedMkt<Futures, ByContractId>`. `dispatch` / `as_*` replaced by
  `match` on `MarketInfo`; `contract_id_of` shared by artifact, testkit and
  fixtures. New `AssetRepoError` variants: `TooManyMarkets`, `Build`,
  `Insert`. New dependency `market-info-repo`. `just check` passes (85 lib
  tests); the ignored e2e tests need the producer, which is not migrated.
- Left: structure-strat-template-core (after dsl-runtime); SPEC:backtest-feed
  `MarketInfoView` and SPEC-4.1.4 (knowledge base, not asked).

### D29. Review, justfiles, first commits (2026-10-08, committed, workspace-a8)

The user asked whether market-info was sound in code and data after the
breaking changes, then: "fix everything", "create the necessary commits with
explanation of what and why", no session reference in commit messages.

- Review result: data sound (682 markets, every id recomputes, every
  Hyperliquid market names the tick and lot table its size decimals call
  for, CME ticks match contract specs). Defects fixed in later commits (D30).
- justfiles of market-info and market-info-core follow entity-core: a
  `targets` list, `just check [target]`, `just fmt [target]`, one row per
  crate, private cells. User: "Deny the warnings from clippy": every Rust
  row runs `cargo clippy --all-targets --no-deps -- -D warnings`. User: for
  the pre-existing `too_many_arguments` (`HlPerpMarketInfo::try_new`) and
  `type_complexity` cases "shut down the warning" with `#[allow(..)]`;
  `clone` on the now-`Copy` `TickTableId` fixed.
- The user removed `[workspace]` from market-info-server and
  market-info-server-contracts and added both to the local root workspace;
  the server's `signal-hook` pin moved to `=0.3.18` (strats_v2 and notify-gw
  need 0.3.18), `MarketInfo::instrument()` call and unused import fixed,
  `egress_manager.start()?` propagated.
- TypeScript (user: "Remove the Instrument.T and asset.T; fix the
  instrument type"): `Instrument.Type` is `Spot 0, Perp 1, Future 2,
  Option 3` like Rust and messaging (was `None 0, Spot 1, Perp 2,
  Future 3`); `Instrument.T`, `Instrument.nil`, `Asset.T`, `Asset.nil`
  removed (no users). structure-web positions API now sends 1 for a perp.
  `positions-repository.ts:367` still labels every derivative `Perp` (the
  table stores only contract ids), not fixed.
- Branches (unsigned, not pushed): market-info-core `cme-globex-options`,
  market-info `cme-options-market-info`. Commits listed in D37.

### D30. Review fixes in market-info (2026-10-08, committed)

- `#[derive(MarketInfoRepository)]` `build(..)` returns
  `Result<Self, DuplicateMarketError>` and refuses an id held by two stores
  (it only assembled stores before). Derive errors at the field for names
  like `__`, `_1`, `self_`, duplicate variant names, `#[cfg]` on a store.
- `TickTableError` uses thiserror; `TickRangeEnd` alias removed
  (`PriceRangeEnd` everywhere); table file names must be the canonical id
  text; `mkt-info-gen check` compares tick and lot tables; Globex
  constructors refuse blank display names.
- D26 (`#[kind(..)]`) followed.

### D31. Documentation pass (2026-10-09, committed)

Two cold-reading agents reviewed both repos as newcomers; the proposal is
the dev-env notebook *documentation-fixes* in this session. The user's
answers (dev-env annotations):

- D1 agreed: `ByUnderlyingContract` index for options (market-info-repo);
  the options test uses it. D2 agreed: `TickTableRecord::round_down` /
  `round_up` (bid down, ask up, reuse `snap_to_outside_tick`). `inspect`
  prints table counts. D4: `just check` fails when generated `docs/*.md`
  are stale; separate recipes write them (market-info `docs_build`,
  market-info-core `docs`; naming inconsistent, open).
- D3: "for repository, we use `repository` word. if it's called
  instrument_type, then it's instrument_type": prose only; code names
  (`KindStore`, `store()`, `MarketKind`, `#[kind]`, `market-info-store`
  crate) not renamed, open.
- D5 / knowledge base: "Don't forget to mention articles and references in
  the knowledge base": crate overviews and READMEs link the KB records and
  explain `REF:`/`DEC-` markers.
- Options text: "because of options, we understood that we'll have way too
  many markets to store them in the text files. Therefore, we'll implement
  the market info server that will manage the storage of all the markets
  and the services will query it over the rpc protocol to fetch the data
  only they need."
- Hash inputs: "map the variants to hashing ids only in the market info
  crate? Have some private hashing trait": market-info-core private
  `IdHashInput` trait with written-out codes for Venue, InstrumentType,
  ProductCode, MaturityMonthYear/Period, PutOrCall, StrikePrice; ids
  byte-identical, 12 golden ids unchanged, 2 added (a put, a day maturity).
- Annotation replies were drafted but not posted (dev-env app not running).

### D32. Asset ids computed in market-info-core (2026-10-09, committed)

The user asked why market-info computed asset ids; no decision existed (the
asset structs stayed in market-info when instruments moved to core), and the
hash used `blockchain as u64` / `u16::from(fiat)` discriminants. User:
"yeah, move it".

- `AssetId::crypto(symbol, blockchain, asset_type)` and
  `AssetId::fiat(symbol, fiat)` in market-info-core, codes for all 49
  `Blockchain` variants, `Fiat`, `CryptoAssetType` written out through
  `IdHashInput`. Ids byte-identical: 5 golden ids, plus a test that every
  variant's code equals the stored number. market-info `CryptoAsset::new` /
  `FiatAsset::new` call them; records (name, decimals, validation) stay.
- `Blockchain::to_id_bytes` kept: entity-core hashes it into trading account
  ids (same for `Venue::to_id_bytes`); documented as hash input there.

### D33. Position sketch removed (2026-10-09, committed)

The user removed the misleading private `documentation_only` types from
market-info-core `position.rs`; the empty module and its comment went too.
The module keeps its doc and the KB link.

### D34. CME data lives in cme-globex; ZB and UB added (2026-10-09, committed)

User: "we need ZB and UB products added"; refresh the generator data;
"store the assets in the cme-globex, but reference them in the crate, so the
generator just imports the crate". CME's anonymous FTP server needs no login
and allows curl (the https web mirror blocks scripts):
`ftp://ftp.cmegroup.com/SBEFix/Production/secdef.dat.gz`,
`ftp://ftp.cmegroup.com/pub/fprf/csv/cmeg.<x>.fut.prf.<YYYYMMDD>.csv`.

- cme-globex `e156117` (new branch `refresh-reference-data-and-asset-paths`):
  secdef downloaded 2026-10-09T11:34:28Z (tag 779 up to 2026-10-09T04:00Z)
  and the four Product Reference Files of 2026-10-08, replacing 2026-09-10;
  `assets` feature with `cme_globex::assets::{dir, secdef_snapshot,
  sbe_templates, futures_product_reference_files}` (paths from
  `CARGO_MANIFEST_DIR`, valid for path and git deps; tools and tests only).
  Each refresh adds about 60 MB of git history.
- market-info `7895f50`: generator depends on cme-globex `assets`; input
  flags optional; its own secdef/FPRF copies deleted; run is
  `--source-observed-at 2026-10-09T11:34:28Z --markets-dir ./assets`.
- market-info `dec8b0e`: ZB (`US30Y-CTD`) and UB (`US30Y-ULTRA-CTD`), CBOT,
  ParPoint, Front(2), GLOBEX schedule (underlying names chosen by the agent
  after `US10Y-CTD` / `US10Y-ULTRA-CTD`; not confirmed by the user). The
  refresh rolled every product: 25 new contracts, 23 marked `Delisted`
  (incl. the expired ones still `Active`), existing files changed only in
  `listing_status`, no id moved (D27 trial ids still match). New tick table
  `tick_ER4P382NSJMMN` (1/32). Catalog 707 markets, 142 CME active.
- Count guard: kept at 140..=145 (142 inside). Raising by the products
  added would reject 142, because ZL and ZM each lost an October contract.
  Open: per-product guard; the grains' `ThroughNextYear` horizon adds a
  year of contracts each January and will exceed 145.

### D35. Public API index idea (2026-10-09, proposal only)

The user wants people and agents to see public types, docs and source
locations without reading implementations. A design agent spiked it in
`/private/tmp/api-index-spike/`: rustdoc JSON (works on stable 1.97.1 with
`RUSTC_BOOTSTRAP=1`, includes derive output and implementors) plus TypeDoc
JSON, a small `apimap` CLI (`show`/`find`/`impls`/`mod`, cards about 1 KB vs
8-13 KB of source), a committed `API.md` per crate, and the official Claude
Code LSP plugins for references. Not decided: commit `API.md` or cache,
`RUSTC_BOOTSTRAP` vs nightly, where the tool lives, CLI+skill vs MCP.

### D36. Open items after D29-D34

- Merge order: cme-globex `refresh-reference-data-and-asset-paths`, then
  market-info-core `cme-globex-options`, then market-info
  `cme-options-market-info`, then the consumers (D25). Colleagues build from
  `main`; market-info depends on the new cme-globex `assets` feature and the
  new market-info-core APIs.
- infra `market_info:revision` (D27 step 2) should point at market-info
  `dec8b0e` or later.
- Knowledge base, not edited (not asked): DEC-0CAHB and REF:instrument still
  describe the u16 `InstrumentIdTag`; REF:market-info-server says gRPC, the
  code is NATS request/reply; DEC-0CAHA, DEC-0CAHB, DEC-0C9DM are not on KB
  `main`, so new doc links to them 404 until pushed.
- `MarketInfoRepositoryError` in market-info-repo has no users (client-core
  keeps its own private copy): delete or reuse.
- TS `Asset.Type` / `CryptoAssetType` numbering differs from Rust
  (documented "map by name"): renumber or not.
- Code renames for "store"/"kind" (D31 D3).
- Design gaps not fixed (need decisions): option strike stored scaled and
  raw without a cross-check; `KindStore::store_mut` public; tables can be
  replaced after load without validation; Hyperliquid size decimals not
  checked against tables; CME trading schedules verified only through
  2026-09-08.
- strats_v2, sim-gw, event-gw, application-server, client(-core),
  dsl-runtime, structure-strat-template-core, databento-mkt-data not
  migrated (D25 order).

### D37. Commits (2026-10-09; unsigned, not pushed)

- market-info-core `cme-globex-options`: c5683be option instruments and
  venue+type id hash; caf299c TS ContractID; 92da5e0 TS Instrument.Type;
  bf82a60 justfile; e9229e0 `IdHashInput`; 243ab5a docs; 23fa822 docs
  check; a149899 asset ids; 608f213 position sketch removed.
- market-info `cme-options-market-info`: 1297bd6 tables + per-kind
  repositories + option market info + regenerated catalog; 989ec20
  market-info-server; c5ac8a8 justfile; c5b7618 build() duplicate check;
  2553633 tables; 94a4993 blank names; 5aa90c5 READMEs; 7d88157
  `#[kind(..)]`; 027fd87 `ByUnderlyingContract`; ea8f958 rounding; f30c9d5
  tooling; bc0ad3f docs; 3fb8877 asset ids from core; 7895f50 generator
  reads cme-globex; dec8b0e ZB/UB and catalog refresh.
- cme-globex `refresh-reference-data-and-asset-paths`: e156117.
- `just check` passes in all three; trade-core, trade_v2, entity-core
  compile against them.

## Facts gathered: options on the selected futures (2026-10-09)

The user asked how many options sit on the futures the policy selects,
without user-defined ones, to decide between RON files and
market-info-server now. Counted from cme-globex `secdef.dat.gz`
(2026-10-09T11:34:28Z), underlying from tag 309 against the 142 active CME
Group futures in `markets.csv`; scripts in `/private/tmp/opt-count/`.

- 196,688 exchange-listed options (9779=N); 2,840 user-defined on the same
  futures are excluded (the daily file misses intraday user-defined strikes).
  By exchange: CME 61,854, NYMEX 59,154, CBOT 50,396, COMEX 25,284. 1OZ has
  none; GC, SI, HG, SR3 and MNQ have options on only some selected futures.
- Largest: ES 17.7k, CL 17.1k, BZ 15.0k, NG 14.2k, NQ 12.1k, SR3 8.4k, GC 8.0k.
- 501 option product codes, 798 series (product code + expiry date), 89
  distinct expiry dates. Strikes per series (puts and calls): median 188, p90
  476, max 1,680 (GC). Strikes of a series nearly always share one
  activation date (median and p90: 1 distinct day per series, max 37).
- Churn: 24,004 listed in the last 7 days, about 3,000 per day over 30 days
  (max 10,046), about 16 new series per day. Expiry: 75,554 within 7 days,
  120,592 within 31 days, 76,096 later than 31 days.
- 45,678 options carry a variable tick table code (tag 6350).

## Proposal presented: one option file per underlying future (2026-10-09, not accepted yet)

The user asked for one file per underlying future holding lists of options.
Counts (same snapshot): 135 of the 142 futures have options; options per
future median 640, p90 3,788, max 15,684 (ESZ6; NQZ6 11,454, GCZ6 8,022);
series per future median 3, max 37.

- Sibling tree `markets/<venue>/option/<product>_<maturity>.ron`, named
  after the future, so the future file schema stays as is.
- File: underlying, then series (product code, maturity, expiry, activation,
  exercise/settlement/valuation, tick and lot table, strike scale), each with
  one line per strike: put/call, raw tag 202, security id, optional activation
  override (strikes added later in the series' life).
- No per-strike instrument id annotation; ids stay out of `markets.csv`
  (197k rows at about 170 bytes would be about 33 MB).
- Open: expired series removed from the file or kept as delisted (ESZ6 keeps
  gaining weeklies and dailies until December); one option file per future or
  split if the venue of the option differs from the future's.

## Facts gathered: expiry cadence per option product code (2026-10-09)

A colleague said the files should follow the expiry frequency of the series.
Each option product code belongs to one cadence family; the secdef has no
cadence tag, and a code's own expiries can mislead (E1A, week 1 Monday,
expires once a month but belongs to the daily family). Script
`/private/tmp/opt-count/cadence.py`.

- ES (17,664 on ESZ6 + ESH7): Mon-Thu dailies E1A..E5D 11,438 (65%), Friday
  weeklies EW1-EW4 3,888 (22%), end-of-month EW 1,662 (9%), quarterly ES 676
  (4%). Each daily or weekly code has 1-2 expiries listed at once.
- CL: daily ICD (5 expiries, one per weekday), weekday weeklies
  ML/NL/WL/XL/LO1-5, monthly LO 7,692 and LCE 2,526 (12 expiries each).
- ZN: weekday weeklies VY/GY/WY/HY/ZN1-5 (about 200 each, one expiry),
  standard OZN 1,312 (5 expiries).

### D29. The backtest Definition carries the tables its markets name (2026-10-09, not committed)

The user asked how passing the tick tables, lot tables and schedules would
look, then: "fix the traits and codecs and post processor". Revises the D28
doc comment (ids no longer unresolved within the feed).

- data-feed-definitions: `BacktestDefinition::tick_tables()`, `lot_tables()`,
  `trading_schedules()` return the market-info records, exactly one per id a
  market names and no other.
- Backtest codec: proto fields 11-13 (`repeated bytes`, one rkyv archive per
  record). `market_info_schema_hash` now hashes the fixture's markets, tick
  tables, lot tables and schedules (value changed; older feed files are
  rejected). `MarketInfoScratch::decode` checks each list: `invalid_archive`,
  `too_many` (limits = `MAX_MARKET_INFO`), `duplicate`, `unresolved`,
  `unreferenced`. `ProduceError::MarketInfoArchive` became `Archive { field,
  index }`; `archive_try_from` is generic. Tests: one violation row per list
  and check, a producer limit row.
- market-info-store's schema fixture has no `continuous-v1` record although
  fixture markets name it by default; the codec and post-processor test
  helpers add one. Not changed in market-info (the fixture feeds
  `EXPECTED_SCHEMA_HASH`).
- backtest-post-processor: decoded `Definition` carries the lists;
  `ResolvedDefinition` loads `RunTables` (market-info-repo tick and lot table
  repositories, `TradingScheduleRepository`), checking each market's ids
  resolve (`ArtifactError::TablesInvalid`, `Validation`). Nothing reads the
  tables yet (`#[expect(dead_code)]`). Test catalog:
  `catalog_tables_named_by`, `fixtures::set_markets`.
- Not migrated: dsl-runtime `backtest_feed/views/lifecycle.rs` (the real
  producer view) needs the three methods; structure-strat-template-core's
  `load_market_info_catalog` drops the tables today.

## Facts gathered: option volume (2026-10-09)

The user: "we can only do monthly or quarterly for now", and the choice of
what to keep follows the expiry frequency of the series, not how near an
expiry is. Volume is Databento GLBX.MDP3 `ohlcv-1d`, 2026-09-09 to
2026-10-08 (22 weekdays; Sunday-session bars 0.3%), parent symbols
`<code>.OPT` for the 511 option codes on the 31 selected products (cost $0;
`ALL_SYMBOLS` with `map_symbols` is refused, more than about 50 parents per
request times out). Family from the CME Globex Product Reference product name;
scripts `/private/tmp/opt-count/{codes,volume,family_count}.py`, data
`/private/tmp/opt-volume-data/`.

- Outright options: 1.44M contracts per weekday; 67k distinct options traded
  in the month, 90% of volume in 10.4k of them. User-defined option spreads
  (`UD:` symbols, mostly Treasury) add 25.2M (1.15M per day), excluded; not
  checked whether their leg fills also appear on the outrights.
- 80% of live-option volume is on the selected futures; the rest is on later
  months of the same products.
- By product per day: ES 643k, ZN 204k, ZF 86k, CL 70k, NQ 69k, ZB 68k, ZC
  64k, SR3 55k, NG 47k, ZS 34k, GC 26k, ZT 22k; MES, MNQ, TN, UB, RB, crypto
  and MGC under about 2k.
- Top codes per day: OZN 130k, OZC 58k, OZF 57k, EW3 57k, EW2 53k, LO 49k,
  EW 49k, SR3 45k, LNE 44k.
- Family by CME name: weekly 56%, monthly 36.5%, end of month 3.9%,
  quarterly 2.8%. ES and NQ are about 85% weekly; Treasuries 56-73% monthly;
  grains and NG 92-98% monthly.
- CME names do not always match the frequency: EW3 is named "Weekly" but
  lists third-Friday expiries five months out (monthly serial). Codes inside a
  weekday family (E1A, Monday week 1) expire once a month each, so the
  frequency belongs to the family, not the single code.
- Monthly + end of month + quarterly + EW3: about 87k listed options on the
  selected futures and about 47% of outright volume (681k per day).

### D30. Schedules out of the backtest feed; stable numeric schedule ids (2026-10-09, not committed)

The user accepted the proposal: (1) drop schedules from the backtest
Definition (nothing in a backtest evaluates trading hours), (2) stable numeric
schedule ids, (3) knowledge base. Schedule generation is to be discussed
separately ("let's not fuck my mind with this" for now).

- Backtest feed: Definition carries market info, tick tables, lot tables;
  proto field 13 and every schedule check removed in codec and post-processor.
- market-info: `TradingScheduleId(u64)`, `DomainId` prefix `sched`, hashed
  once from a creation key (`from_key`, seed "SCHEDULE"
  0x5343_4845_4455_4C45), stored in the file, never recomputed; records gain
  `display_name` / `description`; files `schedules/<id>.ron`;
  `trading_schedule_id()` by value. Keys: `continuous` ->
  `sched_5HPYXW4XV2K7X`; old string ids for the CME four: Globex
  `sched_B9XXZ9CES94QY`, energy/metals `sched_7NPK682HVF674`, grains
  `sched_91VYY0HJ7K4BG`, crypto `sched_4QTDKBNN7A8DE`. Rejected: content hash
  (amendments would re-point markets), snowflake (fixtures and policy cannot
  name well-known schedules), plain strings.
- Fixture continuous record uses the real id, so the D29 workaround is gone;
  `EXPECTED_SCHEMA_HASH` 0x5805_f3f4_3030_cc18; archive rebuilt; 165 market
  files rewritten.
- `market-info/assets/trading-schedules.json` (user's shape): schema_version,
  source (CME trading-hours URL, observed 2026-09-03T15:35:37Z, verified
  through 2026-09-08, three secondary sources), and per id `{file,
  display_name, description}`. Not read by the build; names duplicated with
  the records.
- Knowledge base: DEC-0CC0S (new, links DEC-0AQV3), SPEC:backtest-feed
  (tables, MarketInfoView table ids, SPEC-4.1.4, new SPEC-4.1.6),
  REF:market-info schedule paragraph.
- Checks 2026-10-09: `just check` exit 0 in market-info, data-feed-definitions,
  backtest-post-processor; `cargo test -p trade-core` exit 0. client-core and
  application-server edits not compiled (pre-existing per-kind repo breaks);
  wasm/TS build output not regenerated.
- Open: schedule data stale (verified through 2026-09-08, only Labor Day);
  producer side (dsl-runtime view, structure-strat-template-core) not migrated.

### D38. Databento server and download job on the new market info (2026-10-09, not committed)

The user: "let's fix the databento servers" (databento-mkt-data, next in the
D25 order).

- databento-cme-globex: `WantedMarket::from_market_info` matches
  `MarketInfo::Future` (`as_future` is gone); new `from_future` for callers
  that already hold a `FutureMarketInfo`.
- Download job: `select_markets` unchanged (plain list, no repository);
  `bin/costs.rs` matches on `MarketInfo`.
- Server: `MarketInfoRepo` is a futures-only store (single-kind repository,
  no derive). Loading skips spot and perp markets; `markets_max` now caps
  futures (doc and example config say so; key name kept). The planner is
  bound by `IncludesMkt<Futures>` and fails with the new
  `UnsupportedInstrumentType` when a dataset's query names anything but
  `future`, instead of failing on the first selected non-future market.
  Startup log field `markets=` renamed `futures=`.
- `just check` exit 0 for databento-cme-globex, databento-mkt-data-download-job
  and databento-mkt-data-server (9, 55, 27 tests).
- Committed 2026-10-09 on a new branch `cme-options-market-info` (unsigned,
  not pushed), rebased on origin/main `fba02f4`: 8cace06 instrument id remap
  script (D24, D27), 98b95a2 the migration. One conflict, `bin/costs.rs`
  imports (main added schema imports); kept main's, without
  `MarketInfoType`. After the rebase the download job does not compile in
  the root workspace: main uses `Schema::Status` / `Ohlcv*` from
  databento-hist-layout, and the local structure-strat-template-core
  checkout (patched in, workspace member) predates them. Checked in a
  scratch workspace with that repo at its origin/main `b6badc9`: clippy -D
  warnings and tests pass (9, 73, 27).

### D39. Review answers on market-info-core #19 (2026-10-09/10)

- XXH64: kept. The odds come from the 64-bit width (about n^2/2^65: 1 in 37
  million at 1M ids, 1 in 370 thousand at 10M); no adversary chooses the
  inputs. `id_hash.rs` now says so (merged in #19 as `438b542`).
- Collisions fail loudly today: the CME generator, the ledger guard and
  market-info-repo `build()`/`insert` refuse a repeated id. No recovery path
  exists (the id is recomputed on decode); market-info-server must refuse an
  insert whose id exists with different identity fields.
- Knowledge base: DEC-0CAHB and REF:instrument describe the venue and type
  bytes (KB `96bbe31`, pushed on `dec-per-kind-market-info-repository`). The
  DEC-0CAHB code link later moved to the #19 merge `1422263` (uncommitted).
- market-info-core #19 merged into `main` (`1422263`); the branch commits
  were rewritten on merge.

### D40. Instruments typed by market, venue kinds, `MarketInfo::Option` (2026-10-10, committed, not pushed)

The user: "we need the MarketInfo::instrument method back"; "we do want the
concrete types sometimes. But ... if I only deal with cme markets, the
hyperliquid instrument is not possible, while we perfectly allow it via a
type"; then "do everything and add the options market info to the pub enum
MarketInfo. Even though it's not stored, let's have it there".

- `MarketInfoTrait` gets `type Instrument<'a>: InstrumentTrait + Copy + Debug`
  and `instrument()`, as narrow as the market: `&CmeFuture` for a venue
  market, `SpotInstrument` / `PerpInstrument` / `FutureInstrument` /
  `OptionInstrument` for the kind enums, `MarketInstrument` for `MarketInfo`.
  The plain `instrument()` methods moved onto the trait. Rejected: one
  `InstrumentRef` over every venue (a CME-only type would allow Hyperliquid);
  inherent methods only (derived repository enums and generic code could not
  reach them).
- `delegate_market_info_trait!(vis Market => Instrument { Variant: Record, .. })`
  defines the instrument enum; the derive generates `<Prefix>Instrument`.
- Venue kinds in market-info-repo: CmeFutures, CbotFutures, NymexFutures,
  ComexFutures, CmeOptions, CbotOptions, NymexOptions, ComexOptions, HlSpots,
  HlPerps, DriftSpots, DriftPerps. Index keys are generic, so they apply.
- `MarketInfo::Option`: the archive writer refuses it with
  `ArchiveError::UnsupportedMarket`, like Drift. The archive stores its own
  `MarketArchive` enum, so layout and schema hash are unchanged. Option types
  derive rkyv; `ExerciseStyle` (common, no rkyv) goes through a remote mirror
  enum.
- The schedule rules close an option outside activation/termination, like a
  future (test fails without the fix).
- market-info-core: `InstrumentTrait` for `&T`, on the new branch
  `market-instrument-types` (`d5c5ce9`, no PR yet). market-info `0787e88` on
  `cme-options-market-info` (with D43).
- Knowledge base: DEC-0CDBZ drafted, `proposed`, uncommitted. Open questions
  for the user: why the option variant while nothing stores options; the
  revisit trigger; whether every service refuses options; observability /
  replay not applicable?; the recorded reason for rejecting inherent methods.
  REF:market-info and REF:instrument wait for acceptance (REF:instrument
  still says "no venue-agnostic instrument value").

### D41. Option arm in every downstream match (2026-10-10, not committed)

Policy: a service loading markets into a repository without options refuses
an option with an error naming its instrument id; code that describes a
market treats it as a dated derivative. No `_ =>` arms.

- Refuse: application-server-core `MarketInfoRepoError::UnsupportedOption`;
  client-core `MarketInfoRepositoryError::UnsupportedOption` (not compiled);
  sim-gw `SimGwMarketInfoInsertError::UnsupportedOption`; event-gw
  `MarketInfoLoadError::UnsupportedOption`; databento server
  `ApplicationError::UnsupportedOptionMarket`; dsl-runtime and strats_v2
  `UnsupportedMarket`; backtest accounting `OptionUnsupported`.
- Describe: application-server asset validation, client contract id,
  backtest artifact symbol/contract/assets, structure-strat-template-core
  catalog assets; costs.rs and fixtures skip.
- Edits sit on each checkout's current branch (event-gw, dsl-runtime,
  strats_v2, structure-strat-template-core on the deployment branch;
  application-server and client on `main`); they belong in the
  `market-info-release` branches.

### D42. Portfolio value takes contract terms (2026-10-10, not committed)

The user asked "why do we need the market info there at all?" (trade-core
`portfolio_value`): it read only the settlement asset and the multiplier per
contract. "Yeah, do that"; the type name is the user's.

- trade-core: `DerivativeContractTerms { settlement_asset_id,
  settlement_qty_per_quote_unit }` with `of_market`, trait
  `DerivativeContractTermsLookup::contract_terms(contract_id)`;
  `portfolio_value` takes it instead of `IndexedMkt<Perps, ByContractId> +
  IndexedMkt<Futures, ByContractId>`. Error `DerivativeContractTermsNotFound`;
  `ContractMarketInfoNotDerivative` (never returned) removed. Lean comment
  updated; `just check` passes with proofs.
- backtest-post-processor: `Markets` indexes terms by contract and
  implements the lookup; `RunMarketInfoRepository` and `AssetRepoError`
  deleted; duplicate instrument/contract checks moved to `Markets::resolve`;
  `ArtifactError::MarketsInvalid` wraps `AccountingError`. `just check`
  passes.
- Not done: knowledge base SPEC-accounting-module (SPEC-7.1.4, 7.1.5) still
  names the old errors (KB not asked). A shared "derivative market" bound was
  dropped in favour of the terms lookup.

### D43. Trading schedules in market-info-repo (2026-10-10, in market-info `0787e88`)

The user: "let's use the market-info-repo for the trading schedules to
enforce consistency".

- market-info-repo: `ByTradingScheduleId`, `FixedTradingScheduleRepository`,
  `TradingScheduleLoadError`; `from_records` = `load_table` with
  `TradingScheduleRecord::validate`, refusing a repeated id.
- market-info: `TradingScheduleRepository` replaced by the trait
  `TradingScheduleLookup` (required `trading_schedule(id)`; provided
  `state_at`, `market_state_at`, `next_close_after`, `next_open_after`).
  `TradingScheduleRecord::validate` public; `TradingScheduleError::DuplicateId`
  removed.
- CME generator loads schedules through the repository (new path dependency
  on market-info-repo); market-info-store validates each schedule file.
- application-server-core (tests pass) and client-core (not compiled) use a
  `FixedTradingScheduleRepository` alias and `get_by_key`; uncommitted.

### D44. State on 2026-10-10

- Open PRs: market-info #27 (local `0787e88` not pushed), trade #14,
  trade_v2 #13, sim-gw #16, backtest-post-processor #14, databento-mkt-data
  #5, event-gw #16 (mixes deployment work), knowledge-base #137 (DEC-0CDBZ
  not committed). Merged: cme-globex #1, market-info-core #19, marketdata
  #4. No PR yet: market-info-core `market-instrument-types`,
  data-feed-definitions, dsl-runtime, application-server, client,
  structure-strat-template-core, strats_v2.
- client-core cannot be compiled in the workspace: `structure-client`
  (structure-sdk `ceb4762`, via structure-client-wasm) does not match the
  current realtime-gateway-client API. Pre-existing; not investigated
  further.
- Docs gap the user set aside: the market-info glossary does not define
  market or market info, nor the instrument as a value; the crate docs still
  say "a two byte tag per venue and instrument type".
- Dev-env notebook *market-instrument-types* explains D40, D41 and D43;
  PR notebooks carry dated update sections.

### D45. Committed, pushed, PR opened (2026-10-10)

The user: "open a pr, commit and push all the necessary changes". Only the
files of D40-D43 were committed; other uncommitted work in each checkout was
left as it was.

| Repository | Branch | Commit | PR |
| --- | --- | --- | --- |
| market-info-core | `market-instrument-types` | `d5c5ce9` | #20 (new; merge before market-info #27) |
| market-info | `cme-options-market-info` | `0787e88` | #27 |
| knowledge-base | `dec-per-kind-market-info-repository` | `cff841d` (DEC-0CDBZ, DEC-0CAHB link) | #137, title now lists DEC-0CDBZ |
| trade | `cme-options-market-info` | `80178ce` | #14 |
| backtest-post-processor | `cme-options-market-info` | `0e0a057` | #14 |
| sim-gw | `cme-options-market-info` | `1152810` | #16 |
| databento-mkt-data | `cme-options-market-info` | `9f7a6ca` | #5 |
| event-gw | `dec-0bzbc-strategy-deployment-entity` | `ecb5cb2` (only `market_info_repo.rs`; no other caller of `insert`) | #16 |

- PR descriptions list the new commits; market-info #27's merge order names
  #20.
- Left out on purpose: backtest-post-processor `tests/backtest_runner.rs`
  (untracked), databento-mkt-data's staged rename of
  `copy_mbp1_folders.py`, sim-gw's untracked docs and logs, event-gw's
  staged deployment work.
- Not committed: the D41 option arms and the D43 schedule repository in
  application-server and client (checkouts on `main` with other uncommitted
  work), and the D41 arms in dsl-runtime, strats_v2 and
  structure-strat-template-core (on the deployment branch, inside the
  uncommitted per-kind migration). They need the `market-info-release`
  branches split out first.


### D46. structure-web pieces kept from the deployment branch (2026-10-10)

The deployment branch (structure-web PR #171) mixed strategy deployments
with unrelated work. The breakdown and the user's choices are in the dev-env
notebook `structure-web-salvage`. Kept: the small fixes, the logs
`event_time`, and the Avro blobs (DEC-0C6J2), which wait for the user's go.
Left out: alert-service incidents (notify-gw covers monitoring), the
backtest callback route move, the shared start checks, the workflow fake,
the completion callback, ERROR to FAILED, the worker pool poll, the
lifecycle fixes, and the deployment entity.

| Repository | Branch | PR | State |
| --- | --- | --- | --- |
| domain | `log-entry-event-time` | #19 | merged |
| structure-web | `logs-event-time` (logs `event_time` + ClickHouse quotes 64-bit integers) | #172 | merged |
| structure-web | `small-fixes` (abort signal, dead e2e wait, `test-api-postgres`, structure-cli skill removed) | #173 | merged |

- The ClickHouse fix (`output_format_json_quote_64bit_integers`, test image
  26.8) came from another agent and went into #172: since ClickHouse 25.8
  the logs query's `event_time_nanos` arrives as a number and fails the row
  schema.
- The positions repository test fails on `main` with or without it: it
  creates `position_updates`, which the shared timeseries-db test schema
  already creates.
- The local codec install was pinned at data-feed-definitions `073709d`,
  which broke `execute-http` locally. Fixed by linking structure-sdk as a
  workspace submodule (pnpm blocks git subdependencies) and moving the codecs
  to data-feed-definitions main.

### D47. Snowflake backtest ids and a per-run limit order offset (2026-10-10, pushed, PRs open)

The user: an optional `limit_order_offset_bps` on strategy start and on
backtest create, any u32 including 0, per start and per backtest; then "get
rid of the hashing of an id, use a regular snowflake ID and if the user wants
to run the same backtest - let them". Plan and progress in the dev-env
notebook `backtest-ids-and-limit-offset`. Replaces DEC-0BQ6R D35 (knowledge
base not edited); closes ISS-0C9C9 item 2.

| Step | Repository | Branch | Commit | PR |
| --- | --- | --- | --- | --- |
| 1 | structure-strat-template-core | `no-backtest-id-check` | `1949dcf`, `53cd6a3` | #29 |
| 1 | structure-web | `snowflake-backtest-ids` | `8194c1b0e` | #174 |
| 1 | infra | `snowflake-backtest-ids` (worktree `/private/tmp/infra-snowflake-backtest-ids`) | `f27ba90` | #29 |
| 1 | data-feed-definitions | `snowflake-backtest-ids` (worktree `/private/tmp/dfd-snowflake-backtest-ids`) | `76d1a6d` | #13 |
| 2 | domain | `remove-backtest-id-hashing` | `e32d46f` | #20 |
| 2 | dsl-runtime | `remove-backtest-id-hashing` | `0cb5458` | #27 |
| 2 | strategy-core | `remove-backtest-id-hashing` | `ae9a09b` | #16 |
| 2 | dsl-processor-core | `remove-backtest-id-hashing` | `437b29c` | #18 |
| 3 | structure-sdk | `limit-order-offset` | `1a4c5d1` | #1 |
| 3 | data-feed-definitions | `limit-order-offset` | `738c7b9` | #14 |
| 3 | structure-web | `limit-order-offset` (base `snowflake-backtest-ids`) | `44c5edf42` | #175 |

- Merge and deploy order:
  1. template-core #29, then rebuild the strategy and backtest images (an
     old runtime rejects every snowflake id);
  2. structure-web #174 and infra #29;
  3. domain #20 and dsl-runtime #27, then strategy-core #16;
  4. structure-sdk #1, then data-feed-definitions #14, then structure-web
     #175, then regenerate application-server-client.
- Backtest offset storage: a nullable `backtests.limit_order_offset_bps`
  column, kept in structure-web. Rows created before #175 are null and run
  with the server default.
- data-feed-definitions #14 removes `tests/crate_name.rs` from both codecs:
  it demands a rename on every service change, which `pinned-crates.md`
  forbids.
- Open:
  - `ComputeBacktestIdRequest`: removed in D48.
  - The protocol `Backtest` message has no offset field.
  - application-server-client is not regenerated: its generator needs a
    running api server.
- Local-only workspace config for these builds:
  - root `Cargo.toml` excludes `structure-sdk`;
  - `.cargo/config.toml` patches the structure-sdk crates and the five
    content-shape codecs to the local checkouts;
  - `pnpm-workspace.yaml` adds the codec folders as packages and links
    them, and links structure-sdk;
  - structure-sdk is a new submodule.

### D48. Messaging, protocol response and knowledge base (2026-10-10)

The user: "messaging -> remove the compute request; protocol -> update;
knowledge base -> update".

| Repository | Branch | Commit | PR |
| --- | --- | --- | --- |
| msg-schemas | `remove-compute-backtest-id-request` | `9f034a4` | #31 (merge first) |
| messaging | `remove-compute-backtest-id-request` | `b07c8d2` | #52 |
| knowledge-base | `backtest-snowflake-ids-and-limit-offset` | see PR | #138 |

- My earlier claim that messaging had not regenerated msg-schemas #30 was
  wrong. messaging main (#51) already regenerated it, and `1ab7852` (the
  recorded pointer) has the same tree as the #30 merge commit `0564824`.
  messaging #52 holds only the removal.
- Knowledge base:
  - DEC-0CDPA (accepted): backtest ids are server-issued snowflakes. It
    supersedes DEC-0A430, which is now `superseded`.
  - DEC-0CDPB (accepted): the limit order offset is chosen per start and
    per backtest.
  - ISS-0C9C9: item 2 is resolved; the issue stays open for the fill
    model.
  - ISS-0A430: notes that `BacktestId` is no longer hashed.
- Protocol: the backtest representation carries `limit_order_offset_bps`
  (absent for older backtests, 0 sent as 0), pushed to the open PRs:
  - structure-sdk #1 `54d6e1d`: `Backtest.limit_order_offset_bps`;
  - data-feed-definitions #14 `c113a85`: `backtests.Backtest`, tag 17,
    with the Backtest, BacktestWithExecution and BacktestPage shape ids
    re-pinned;
  - structure-web #175 `5b1887c77`: the adapter sends the stored value.

### D49. Avro blobs on main; the offset lives in strategy_config (2026-10-10, pushed)

The user rejected the `backtests.limit_order_offset_bps` column: "I don't
want a new column per each property we want to pass to a backtest". Then:
"I'm going to drop all the strategies, there is no need to backfill or
migrate anything". Plan and progress are in the dev-env notebook
`avro-and-backtest-strategy-config`.

| Repository | Branch | Commits | PR |
| --- | --- | --- | --- |
| structure-web | `dec-0c6j2-avro-blobs` (on #174) | `3e743678a`, `a55e9b5f3`, `c230621c7`, `7d91b2925`, `e35a1097e` | #176 |
| structure-web | `limit-order-offset` (force-pushed, base #176) | `49127eb43` | #175 |
| strategy-core | `remove-node-mappings` | `7999e7d` | #17 |
| knowledge-base | `backtest-snowflake-ids-and-limit-offset` | `1c4cf43`, `0914747` | #138 |

- Avro (DEC-0C6J2) is ported from the deployment branch without the
  deployment entity. main's old `strategy_deployments` has its `service`
  and `error` columns converted like every other blob.
- `backtests.strategy_config` is an Avro `StrategyConfig` (policies, typed
  bindings, and a required `limit_order_offset_bps`). It replaces
  `strategy_spec_arguments` and `strategy_variable_bindings`.
- No backfill and no DSL 1.1 purge. The migration fails on NOT NULL if a
  strategy table still has rows. The DSL 1.1 guards and the node mappings
  are removed (the user: "node mappings can be removed").
- `packages/app-db/misc/drop-strategies.sql` deletes strategies, revisions,
  backtests, deployments, both connection tables, templates, images,
  runtime revisions and `strategies_http.*` kv entries. It was tested on a
  database migrated to main. Templates and images must go too: their ids
  are content hashes and nothing re-creates the rows.
- Migration steps are in the `e35a1097e` commit message and in #176.
- The 22 notebooks deleted by mistake in IntelliJ (restored empty) were
  rebuilt by replaying the Claude Code transcripts' Write/Edit calls and
  shell edits in a sandbox (scratch files in `/private/tmp/notebook-recovery`).

### D50. Deployed: Avro blobs, snowflake backtest ids, limit order offset (2026-10-10)

- Signing mistake: `just sign_latest_commits 9` on `snowflake-backtest-ids`
  (after #175 and #176 were merged into it) rebased through main's merges
  and force-pushed linearized copies. The fix rebuilt the branch as
  `origin/main` plus the 7 commits, signed with `cherry-pick -S`, with the
  tree identical to before the signing. #174 was then merged. A branch's own
  commits are signed with `git rebase -S origin/main`, not
  `sign_latest_commits N`.
- The image build failed on unformatted files (fixed in #177) and on a
  missing `structure-sdk` in infra's structure-web image allowlist.
- Template: structure-strat-template #9, template-core `12ba658`.
  - The lock was moved to main outside the workspace, because the
    workspace's `.cargo/config.toml` patches would write local paths into
    it.
  - The builder was rebuilt on Cloud Build after the `strategies-builders`
    team was given `structure-sdk` (infra `github.ts`).
  - infra pins runtime `d5c6044`.
- infra #30: the realtime-gateway parts of #25. Its older
  application-server digest was left out.
- Production: `drop-strategies.sql` committed, migrated, `pulumi up`. The
  public OpenAPI shows the new fields.
- Clients:
  - application-server-client #15: the public client regenerated from the
    production API (no discovery key, so the internal client was not
    regenerated; it contains none of the changed types);
  - stxr-client-app #31: submodule at `2f7de3f`; only test fixtures
    changed.
  Both signed and merged.
- Left: a smoke test backtest, the first real build with the new
  strategy-builder.
- The user: no PRs for one-line changes.

### D51. Databento folders copied to the new ids (2026-10-10/11; checked 2026-10-12)

The user asked to check that the script's later changes and the copy were
recorded and that everything moved. Assembled from databento-mkt-data git
history, the Claude Code transcripts (mainly session `008b1a30`, the release
work of D44-D50) and the bucket.

- Script history, databento-mkt-data:
  - `8cace06` / `301ff88` (2026-10-09, same change on two branches):
    `copy_mbp1_folders.py` with both maps committed.
  - `3b72f53` (2026-10-10): renamed `remap_instrument_folders.py`. The
    download job files every schema under `{schema}/{instrument id}/`, so the
    script works through `mbp-1`, `status`, `ohlcv-1s`, `ohlcv-1m`,
    `ohlcv-1h`, `ohlcv-1d` (those the bucket holds), leaves `definition/` and
    `markers/` alone (their files name no instrument) and reports a top-level
    folder it does not know. Modes, map checks and `--map` are unchanged.
    Shipped in PR #5 (merged, `bc63735`).
- Run (session `008b1a30`, the user approved the full `--run` on 2026-10-10
  22:11 with "Yes"; the five-folder trial of D27 was not run):
  - Order used: production deployed on market-info `480d1b5` first
    (`infra` `8329b9e`, `pulumi up` 2026-10-10 ~21:56), then the copy. ESZ6
    was copied and checked alone first for the 0-slippage backtest
    (`bt_02V24AZFW0400`).
  - First full `--run` stopped at the two-hour command limit after 516 of
    840 folders; a detached rerun failed when the gcloud login expired; the
    third run (after `gcloud auth login`, 2026-10-11 ~09:54) finished:
    `folders: 840`, `run exit=0` (`/tmp/remap-run3.log`).
  - `--verify`: `verify exit=0`, 840 `ok` lines, ended 2026-10-11 16:17
    (`/tmp/remap-verify3.log`).
  - `--delete` not run.
- Checked 2026-10-12 on `mbp-1`: 9,526 files in the 140 old folders, 9,649 in
  the 140 new ones, 25 in folders of markets not in the map (added to the
  catalog after b34b5df). The last write to an old folder was
  2026-10-10T06:33Z, before the copy and the verify, so nothing written
  under the old ids is missing from the new folders. The newest object in the
  bucket is 2026-10-11T06:31Z. ESZ6 new folder ends at 2026-10-10, old at
  2026-10-09.
- Readers: production pins market-info `480d1b5` (new ids). Dev still pins
  `a7c65b6`, which has no CME Group futures, so dev reads none of these
  folders.
- The download job no longer uses markers (databento-mkt-data `6282881`,
  2026-10-12): a (market, day) is done when its object exists. D24's reason
  for copying ("a plain re-run skips every marked day") no longer holds for
  the new job; the copy still saves the Databento cost. With the new job, an
  old-id file the copy had missed would have been downloaded again under the
  new id, not lost.
- `/private/tmp/inst-id-remap/` (D21 facts: the 682-row mapping incl.
  Hyperliquid) is gone. The 140 CME Group rows survive in
  `databento-mkt-data/misc/instrument-id-remap/instrument-id-map.csv`;
  Hyperliquid data is not kept (D22).
- Left: `--delete` (removes the 840 old folders, about 130 GB in `mbp-1`
  alone), on the user's go. Release notes notebook step 10 lists it.
- Session file numbering: D29 and D30 each appear twice (two sessions wrote
  at once on 2026-10-09); not renumbered.
