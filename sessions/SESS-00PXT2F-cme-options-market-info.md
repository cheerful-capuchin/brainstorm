---
create_time: 2026-10-06T07:20:47Z
summary: "No DatedMarketTrait; MarketInfoType to be replaced by kind traits (open); Globex min_qty from tag 562; PriceGrid + min_px_inc(px) and side-aware compute_valid_px done (D8); dated VTT tables next"
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
