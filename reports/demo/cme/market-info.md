# CME Futures Market Info Model

Date: 2026-08-27

## Scope

Proposed changes to the market-info traits and types
(`market-info/src/market_info.rs`, `market-info-core`) needed to represent CME
Group futures markets. Covers the top-10 CME futures products by volume,
futures only (no options). Assumes the `Venue` enum already carries `Cme`,
`Cbot`, `Nymex`, and `Comex`.

This lands on the stated revisit trigger of
[DEC-08Y0M: First-Class Perpetual Quote Unit](../../../../knowledge-base/docs/decisions/records/DEC-08Y0M-first-class-perpetual-quote-unit.md)
("a supported market needs a non-asset quote unit"), so the quote-unit and
trait changes below warrant a DEC record before implementation.

## Trait Restructure

Almost everything on today's `PerpMarketTrait` is generic derivative
machinery, not perp machinery — only `funding_asset` is perp-specific. Factor
the shared part into a `DerivativeMarketTrait`:

```rust
/// Common to every derivative market (perps and dated futures).
pub trait DerivativeMarketTrait: MarketInfoTrait {
    fn underlying(&self) -> &Underlying;            // renamed from PerpUnderlying
    fn settlement_asset(&self) -> &Asset;           // USD FiatAsset for CME
    fn quote_unit(&self) -> QuoteUnit;
    fn settlement_qty_per_quote_unit(&self) -> Decimal;  // the contract multiplier
    fn contract_id(&self) -> ContractId;
}

pub trait PerpMarketTrait: DerivativeMarketTrait {
    fn funding_asset(&self) -> &Asset;              // funding is the perp-only mechanism
}

pub trait FutureMarketTrait: DerivativeMarketTrait {
    fn trading_termination_time(&self) -> Timestamp;
    fn settlement_method(&self) -> &FutureSettlementMethod;
}
```

There is deliberately no `expiration()` method. In CME vocabulary "expiration"
is options language (the CME glossary defines the expiration date as the last
day an *option* may be exercised); for futures it appears only loosely in
education material as a synonym for the last trade date, which
`trading_termination_time` already models. The dates that end a future's life
differ by settlement method, so they live inside `FutureSettlementMethod`
(see [Settlement](#settlement)) under CME's exact terms.

Structural points:

- **Each contract month is its own market.** ZN Dec-2026 gets its own
  `Instrument` (symbol like `ZNZ2026`, venue `Cbot`), its own `MarketInfo`
  entry, and its own `ContractId`. The 1:1 instrument/contract mapping from
  the perp world still holds, so the existing `ContractId`-from-`InstrumentId`
  derivation survives.
- **`ListingStatus` fits futures as-is**: `Upcoming` before CME lists the
  month, `Active` while trading, `Delisted` after expiry. The "delisted
  markets must be retained for history" rationale is exactly the
  futures-expiry situation. No change needed.
- **`InstrumentType` gains `FUTURE = 2`.** The enum is used for deterministic
  instrument-id hashing, so the change must be append-only; existing SPOT/PERP
  ids stay stable. Same discipline for the manual `Hash for Venue` impl when
  the four venues land: append, never reorder.
- **`MarketInfoType` becomes three-way**: a `FutureType` associated type,
  `as_future()`, and a three-closure `dispatch`. This is the expensive part —
  every implementor and every `dispatch` call site breaks. Do it properly
  rather than bolting on a side-trait; the compiler walks the call sites.
- New enums mirror the existing shape: `MarketInfo::Future(FutureMarketInfo)`
  and `FutureMarketInfo::CmeFutureMarketInfo(...)` — one impl struct covering
  all four CME-group exchanges, since Globex/MDP3 mechanics are identical and
  the exchange distinction already lives in `Instrument::venue`.

### Property Definitions

Precise meaning of every property, so no consumer has to guess semantics from
the venue or the market name.

`DerivativeMarketTrait` (shared by perps and futures):

- **`underlying()`** — the reference whose price the contract derives its
  value from. For every CME launch product this is a `Ticker` ("NDX", "SOFR",
  "WTI", corn, the treasury baskets); for crypto perps it is an `Asset`. For
  physically delivered contracts the underlying is also *what gets delivered*;
  the exact deliverable grade/basket (CTD conversion factors, corn grade No. 2
  yellow) is deliberately not modeled.
- **`settlement_asset()`** — the asset in which **every cash flow the contract
  generates is denominated**: daily variation margin, cash final settlement,
  and the payment leg of physical delivery. It is also the denomination of
  `settlement_qty_per_quote_unit`. It says nothing about *how* the contract
  terminates — that is `settlement_method()`. The current perp-flavored
  docstring ("the asset P&L is paid out in") should be rewritten to this
  definition. Note it is genuinely per-market, not per-venue: CME lists the
  same underlying under different settlement currencies (Nikkei 225 futures
  exist USD-denominated and JPY-denominated), even though all ten launch
  products settle `Asset::FiatAsset(USD)`.
- **`quote_unit()`** — *names* what one unit of price means (a scaled asset,
  an index point, a par point), per DEC-08Y0M. Purely denotational: notional
  and P&L math never touch it. A consumer reads it to know that ZC's `450.25`
  is cents per bushel (`scale_exponent: -2`), not dollars, applying
  `price_in_asset = price × 10^scale_exponent` when a currency price is
  needed.
- **`settlement_qty_per_quote_unit()`** — the contract multiplier: how many
  units of the settlement asset a one-quote-unit price move on **one
  contract** is worth. The *only* conversion input in the model.
  `notional = price × multiplier × contracts`, denominated in the settlement
  asset.
- **`contract_id()`** — identity of the economic contract terms. Each CME
  contract month is its own contract; the 1:1 mapping to `InstrumentId`
  holds.

`FutureMarketTrait`:

- **`trading_termination_time()`** — the venue-scheduled instant after which
  order entry in this contract ceases forever. CME rulebook rule
  "Termination of Trading", materialized per contract month as the specs-page
  "Last Trade Date". A static contract term fixed at listing — **not** the
  time of the most recent trade on the market.
- **`settlement_method()`** — how the contract terminates, as a closed set:
  - **`Cash::final_settlement_time`** — when the contract cash-settles to the
    CME *Final Settlement Price* (SR3: the benchmark fixing; MNQ: the Special
    Opening Quotation). The contract's last cash flow.
  - **`PhysicalDelivery::first_notice_time`** — CME *First Notice Day*: the
    first instant a short can tender a delivery notice, i.e. the first moment
    a long position can be assigned delivery. Operationally: the flatten-by
    risk deadline — positions we hold must be closed before this.
  - **`PhysicalDelivery::last_delivery_time`** — CME *Last Delivery Day*: the
    end of the delivery window and the contract's economically-final moment
    (for treasuries, the last business day of the delivery month). The
    delivery exchange itself is `underlying()` against payment in
    `settlement_asset()`, so the variant carries no asset of its own.

Inherited `MarketInfoTrait` properties, as they apply to futures:

- **`min_px_inc`** — the venue tick, expressed in the venue-native quote unit
  named by `quote_unit()` (treasury ticks are exact binary fractions).
- **`min_qty` / `min_qty_inc`** — `1`: futures trade in whole contracts.
- **`base_decimals`** — `0`; for futures "base" means contracts.
- **`quote_decimals`** — decimals of the venue-native price representation.
  Precision only — how finely prices are represented — and defined for every
  market, including non-asset-quoted ones (a `ParPoint` treasury price still
  has precision). Distinct from `QuoteUnit::Asset::scale_exponent`, which is
  denomination — what one price unit *is*. CL vs ZC shows they cannot be
  merged: both have 2-decimal prices, but CL quotes dollars
  (`scale_exponent: 0`) and ZC quotes cents (`scale_exponent: -2`).
  Overloading `quote_decimals` with scale would also silently re-denominate
  every existing crypto market (USDC's 6 decimals ≠ a 10⁻⁶ price unit).
- **`listing_status`** — the `Upcoming`/`Active`/`Delisted` lifecycle state.
  Carries no transition timestamps; in particular it does **not** substitute
  for `trading_termination_time`.

### Why `trading_termination_time` is load-bearing

Without its dates a dated future is just a perp with a different name. All
three consumers already exist for perps:

- **Order validation / execution**: after termination the venue rejects
  everything; the layer that checks `min_px_inc` and `min_qty` needs to know
  the market is dead.
- **Backtest simulator**: a replay must stop filling an expired contract and
  force-settle the position, or every backtest quietly holds contracts that no
  longer exist.
- **Risk**: for physically delivered contracts the flatten-by deadline (first
  notice / trading termination) is the most important operational fact about
  the position.

It is not derivable from anything else: CL stops trading in the month *before*
its named delivery month; treasury trading termination and final delivery are
different days. `ListingStatus` does not cover it — that is current lifecycle
state only, with no transition timestamps.

The value stored is the **materialized instant per contract month** (CME's
"Last Trade Date" calendar), not the rulebook business-day formula. The
market-info generation step reads the computed dates from CME reference data;
we never encode the formulas.

### Deliberately excluded

- `asset_class` — pure classification with no behavior behind it; nothing in
  execution, simulation, or accounting branches on it. Defer until a concrete
  consumer (margin grouping, risk bucketing) defines the semantics.
- `contract_month` — identity, already encoded in the instrument symbol
  (each month is its own instrument). Consumers needing contract ordering can
  sort by `expiration`.
- `product_code` — the family prefix ("ZN") shared by every contract month.
  Not the same thing as the instrument symbol (`ZNZ2026` names one month), and
  only recoverable from the symbol by parsing venue naming conventions. No
  current consumer needs the family, so it is deferred — but when rolls,
  continuous series, or subscribe-all-months land, it must come back as a
  stored fact, not a symbol parser.

## Quote Unit

Invariants to preserve:

1. Prices stay in the venue's own quote convention — that is what MDP3 market
   data and iLink order entry speak, and what `min_px_inc` is defined in.
2. `settlement_qty_per_quote_unit` remains the *only* conversion input.
3. `QuoteUnit` *names* the unit so consumers do not guess (the point of
   DEC-08Y0M).

```rust
#[non_exhaustive]
pub enum QuoteUnit {
    /// Price is measured in this asset, scaled: one price unit =
    /// 10^scale_exponent units of the asset. Consumers apply it as
    /// `price_in_asset = price * 10^scale_exponent`.
    /// 0 -> direct quote (crypto perps; CL: USD per barrel);
    /// -2 -> cents (ZC: US cents per bushel).
    Asset { asset_id: AssetId, scale_exponent: i8 },
    /// A point of a named index (MNQ: Nasdaq-100; SR3: the IMM index, 100 - rate).
    IndexPoint { ticker: Arc<str> },
    /// One percent of contract face value (treasury futures).
    ParPoint,
}
```

Design notes on `Asset::scale_exponent`:

- **Variants encode kinds; scale is data, not a kind.** A cents-quoted USD
  market is still an asset-quoted market — cents are USD. A separate
  `AssetFraction` variant was considered and rejected: it would force every
  consumer to treat one kind of market as two.
- **Exponent, not a free `Decimal` factor.** Quote conventions are always
  powers of ten (cents, pence/GBX, mils). An `i8` exponent makes the nonsense
  states a free factor admits (`0`, `0.3`, negatives) unrepresentable, per
  the no-undefined-behavior standard, and matches the `(mantissa, decimals)`
  idiom `numerics` already uses.
- **The scale lives here and nowhere else.** Not on the asset — scale is a
  property of a market's quote convention, not of USD (CL quotes USD in
  dollars, ZC in cents). Not as a separate accessor on the market trait —
  that would split "what does a price unit mean" across two places and force
  an answer where scale is meaningless (a `ParPoint` has no scale).
- **The field is mandatory, so this breaks every existing
  `QuoteUnit::Asset` construction and match**; perps set `0`. That is the
  right kind of breakage: no consumer can silently keep assuming a 1:1
  quote unit.
- **Denotational only.** `scale_exponent` tells consumers what a price means;
  the multiplier stays the sole conversion authority for notional/P&L, with
  `multiplier = contract_size × 10^scale_exponent` for ZC
  (`5,000 × 10⁻² = 50`). Worth stating as an invariant in the DEC.

Rejected alternative for corn: normalize to dollars-per-bushel at the adapter
and use a directly-quoted `Asset`. That diverges from the exchange price
representation, so every tick, displayed price, and order round-trip needs a
silent ×100 — exactly the guess-from-context failure DEC-08Y0M was written to
kill.

Treasury ticks are binary fractions (1/32 down to 1/256), so `Decimal`
`min_px_inc` represents them exactly. The 32nds display convention
("112-16+") is presentation only — a future `price_display_format()` on
`MarketPresentationTrait`, not part of this change.

## Settlement

Cash/physical is a closed set, with delivery-only facts inside the variant so
"first notice date on a cash-settled contract" is unrepresentable:

```rust
pub enum FutureSettlementMethod {
    /// SR3, MNQ — the contract cash-settles to the CME Final Settlement
    /// Price at `final_settlement_time`, in the settlement asset.
    Cash {
        final_settlement_time: Timestamp,
    },
    /// ZT/ZF/ZN/TN/ZB/UB (CTD treasury basket), ZC, CL.
    PhysicalDelivery {
        /// CME First Notice Day — positions must be flat before this to
        /// avoid delivery obligations.
        first_notice_time: Timestamp,
        /// CME Last Delivery Day — end of the delivery window; the
        /// contract's economically-final moment.
        last_delivery_time: Timestamp,
    },
}
```

The termination dates live inside the variants rather than on the trait
because the vocabulary and the facts differ by method: a cash-settled contract
has a single Final Settlement instant; a delivered contract has a delivery
*window*. A shared `expiration()` accessor would either mean nothing for one
variant or silently mean two different things.

`FutureSettlementMethod` is orthogonal to `settlement_asset()`: the enum says
*how* the contract terminates, the asset says *in what* every cash flow is
denominated. Both variants pay in the same settlement asset, which is why the
asset stays on `DerivativeMarketTrait` and neither variant repeats it.

We never take delivery, so the operational meaning of `PhysicalDelivery` is a
hard flatten-by deadline for risk. The CTD basket / conversion-factor
machinery of treasury delivery deliberately stays out of the model. Daily
variation-margin settlement is an accounting concern, not market info;
`settlement_asset() = USD` is all market info needs to carry for it
(`Asset::FiatAsset` already exists).

## Underlying

Rename `PerpUnderlying` -> `Underlying`, keep its two variants (`Asset`,
`Ticker`). Every CME underlying is a `Ticker` ("NDX", "SOFR", "WTI",
"US10Y-CTD").

Caution: `PerpUnderlying::asset_id()` panics on the `Ticker` variant.
Tolerable while tickers were rare (PAXG, SPX); with CME *every* underlying is
a ticker, so the accessor must go `Option`/`Result` as part of this change.

## Top-10 Products Mapped

| Product | Venue | Quote unit | `min_px_inc` | Multiplier ($/unit) | Settlement | Underlying |
|---|---|---|---|---|---|---|
| ZT | Cbot | ParPoint | 0.00390625 (1/8 of 1/32) | 2,000 ($200k face) | Physical | 2Y T-note basket |
| ZF | Cbot | ParPoint | 0.0078125 (1/4 of 1/32) | 1,000 | Physical | 5Y basket |
| ZN | Cbot | ParPoint | 0.015625 (1/2 of 1/32) | 1,000 | Physical | 10Y basket |
| TN | Cbot | ParPoint | 0.015625 | 1,000 | Physical | Ultra-10Y basket |
| ZB | Cbot | ParPoint | 0.03125 (1/32) | 1,000 | Physical | 15–25Y bond basket |
| UB | Cbot | ParPoint | 0.03125 | 1,000 | Physical | ≥25Y bond basket |
| SR3 | Cme | IndexPoint("SOFR-IMM") | 0.005 | 2,500 | Cash | 3M compounded SOFR |
| MNQ | Cme | IndexPoint("NDX") | 0.25 | 2 | Cash | Nasdaq-100 |
| ZC | Cbot | Asset(USD, e⁻²) | 0.25 (1/4 cent/bu) | 50 | Physical | Corn, 5,000 bu |
| CL | Nymex | Asset(USD, e⁰) | 0.01 | 1,000 | Physical | WTI, 1,000 bbl |

For all ten: `min_qty = min_qty_inc = 1` (whole contracts) and
`base_decimals = 0`. The existing generic fields absorb this; document that
for futures "base" means contracts.

## Caveats and Deferred Items

- **SR3 front-month tick** is 0.0025 while deferred months tick at 0.005 —
  the first case where `min_px_inc` depends on calendar state (faint echo of
  HL's `live_min_px_inc`). Store the standard tick; handle the front-month
  reduction when SR3 execution lands.
- **Trading hours / sessions / daily settlement times** do not exist in the
  model (crypto is 24/7). A venue-or-product-level calendar concept, not a
  per-`MarketInfoTrait` field. Needs its own design before live CME trading;
  does not block the type work.
- **Ripple**: messaging protos (`InstrumentType`, `Venue`, quote-unit wire
  encoding), the TS mirror types, mocks, and every `MarketInfoType::dispatch`
  call site. See the venue-enum blast radius report
  ([venue-blast-radius.md](../venue-blast-radius.md)) for the venue side.

## Sourcing From Databento (GLBX.MDP3)

Evaluated whether the model can be populated from Databento's CME feed
(dataset `GLBX.MDP3`, `definition` schema / `InstrumentDefMsg`). Verdict: most
properties populate directly; the settlement dates cannot, which makes the
"generation reads CME reference data" step mandatory, not optional.

Verification note: databento.com doc pages were timing out during research;
field existence was verified against the `dbn` Rust crate (Databento's
open-source DBN encoding library — authoritative for the schema), plus
Databento's tutorial/blog material.

### Direct mappings

| Model property | Databento field | Notes |
|---|---|---|
| `min_px_inc` | `min_price_increment` | Prices are fixed-precision 1e-9 integers |
| `trading_termination_time` | `expiration` | Databento defines it as "last eligible trade time" — exactly our deadline |
| `settlement_asset` | `settl_currency` | |
| `underlying` | `underlying` / `asset` | |
| `listing_status` | derived | From `activation`, `expiration`, and the separate `status` schema; not an atomic field |
| 32nds display | `price_display_format`, `main_fraction`, `sub_fraction` | Confirms fractional quoting is presentation-layer, as modeled |

### Assembled or needs verification

- **`quote_unit`** has no single source field — the Asset/IndexPoint/ParPoint
  classification is assembled from `currency`, `unit_of_measure`, and
  `display_factor` in our generation logic, per product. Acceptable for a
  curated top-10 catalog.
- **Prices arrive venue-native with `display_factor` pre-applied.**
  Databento's DBN price fields are the venue display price at 1e-9 scale
  ("Databento already handles scaling of the display factor for you"). Their
  tick-value tutorial confirms the CBOT cents convention: ZC ticks arrive as
  `0.25` (quarter-cent) and XCBT tick values need ×0.01 to reach dollars —
  which is exactly what `QuoteUnit::Asset { USD, scale_exponent: -2 }`
  encodes. Treasuries arrive as decimal points (`110.265625`), matching
  `ParPoint` + binary-fraction `min_px_inc`. `display_factor` itself is
  Databento's raw-feed normalization artifact; our adapter does not apply it.
- **The multiplier derivation needs a per-family check**: Databento carries
  both `contract_multiplier` ("deliverables per instrument") and
  `unit_of_measure_qty` (contract size; quoted in cents on XCBT). Which one,
  combined with the scale, yields `settlement_qty_per_quote_unit` differs by
  product family — verify against a pulled `definition` record per product
  before freezing the catalog.

### Not available from Databento — CME reference data required

- `settlement_method` (cash vs physical): no field anywhere in the schema.
- `PhysicalDelivery::first_notice_time` and `last_delivery_time`: Databento
  carries only the last-trade `expiration`.

### Explicitly out of model scope

CME definitions include multi-leg spread/strategy instruments
(`instrument_class = FutureSpread`, `leg_*` fields). The model represents
outrights only; generation filters on `instrument_class == Future`. Spreads
do not fall out for free — modeling them is a separate decision.

## Sources

- [CME Glossary](https://www.cmegroup.com/education/glossary)
- [CME — Get to Know Futures Expiration and Settlement](https://www.cmegroup.com/education/courses/introduction-to-futures/get-to-know-futures-expiration-and-settlement)
- [CME — Learn about the Treasuries Delivery Process](https://www.cmegroup.com/education/courses/introduction-to-treasuries/learn-about-the-treasuries-delivery-process)
- [CME — The Treasury Futures Delivery Process (PDF)](https://www.cmegroup.com/trading/interest-rates/files/us-treasury-futures-delivery-process.pdf)
- [CME — Understanding Futures Expiration & Contract Roll](https://www.cmegroup.com/education/courses/introduction-to-futures/understanding-futures-expiration-contract-roll)
- [10-Year U.S. Treasury Note futures spec sheet (Duke mirror)](https://people.duke.edu/%7Echarvey/options/cs/tnotef.htm)
- [Databento — GLBX.MDP3 dataset](https://databento.com/docs/venues-and-datasets/glbx-mdp3)
- [Databento — Getting futures tick sizes & notional tick values](https://databento.com/blog/tick-sizes-and-values)
- [Databento — definition schema updates (display_factor scaling)](https://databento.com/blog/definition-schema-updates-may)
- [Databento issue board — imprecise display_factor for fractional pricing](https://issues.databento.com/b/6vrl98vl/feature-ideas/imprecise-display-factor-for-cme-globex-instruments-with-fractional-pricing)
- [dbn crate — InstrumentDefMsg (field-level source of truth)](https://docs.rs/dbn/latest/dbn/struct.InstrumentDefMsg.html)
