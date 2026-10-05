---
create_time: 2026-10-06T07:20:47Z
summary: "No decisions yet. CME options (options on futures) for market-info + cme-market-info-gen: proposed GlobexOption identity, OptionMarketTrait, Underlying::Contract, PriceIncrement; open: catalog shape at ~171k options, families, intraday strikes"
related_sessions: []
---

# SESS-00PXT2F: CME options in market info

## Request (2026-10-06)

Add CME options markets to `market-info/src/market_info.rs`, populated by
`market-info/crates/cme-market-info-gen`. CME Group venues only for now. The
user asked what to know about CME options and how the traits would be added.
No decision has been made yet.

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
- Replace min_px_inc or add a separate method for variable ticks.
