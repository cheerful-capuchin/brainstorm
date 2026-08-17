# Portfolio Value — consolidated knowledge

Date: 2026-08-18

Linear: [ENG-1600 — Create strategy performance view prototype](https://linear.app/stxr/issue/ENG-1600)
(Todo, milestone `Portfolio Value`, parent
[ENG-1318 — Demo app | Portfolio Value](https://linear.app/stxr/issue/ENG-1318))

Companion index: [sources.md](sources.md) — every artifact this report was built
from and what it contributed.

## Why this document exists

Portfolio-value knowledge is spread across four knowledge-base decisions, two
notes, two issues, one reference, five prototypes, three separate code
implementations, and roughly a dozen prompt transcripts. Several of those
records disagree with each other, and the disagreement is not marked anywhere.

This report states what is decided, what is built, where the models conflict,
and what is still open.

## Summary

1. **There is no shared portfolio-value calculation today.** Three independent
   implementations exist — the TypeScript client, the backtest post-processor,
   and the Rust accounting module — and no consumer calls the module that was
   chosen as canonical.
2. **Two accounting models are both live in the knowledge base.**
   [DEC-08C01] defines portfolio value as spot value plus derivative unrealized
   P&L. [DEC-09S6G] defines a different, richer model and states that it
   replaces the existing specs. The specs were never updated, so
   `SPEC:accounting-module` and `SPEC:backtest-feed` still describe the older
   model.
3. **The ENG-1600 prototype is a bootstrap shell, not a portfolio view.**
   `prototypes/strategy-perf-view` renders "Hello, world." The actual
   portfolio-value work moved to `prototypes/accounting`, which is not linked
   from ENG-1600.
4. **The measurement work is done and is the most reusable output.** Feed
   bandwidth, client memory budget, and cold-fold cost are all measured with
   concrete numbers. They constrain the design more than any open decision does.
5. **The main structural blocker is cold-start cost.** A 30-day fold takes
   ~7.7 s from raw events, which is why the work pivoted from "store raw events,
   fold on load" to "store intermediate checkpoints". That pivot is in progress
   and undecided.

## 1. What portfolio value means

Two definitions are in play. They are not reconcilable by wording; they compute
different numbers.

### Model A — accounting module ([DEC-08C01], proposed, 2026-07-10)

```text
portfolio value =
    sum(spot quantity × spot-to-valuation price)
  + sum(
        derivative quantity
      × (contract price − cost basis)
      × quote-to-settlement conversion
      × settlement-to-valuation price
    )
```

- Implemented at `trade/crates/trade-core/src/accounting/portfolio_value.rs`.
- Returns `f64`, not `Decimal`. Every `Decimal` is rounded to a caller-supplied
  `ReportingScale` (max 9 fractional digits) at the single float boundary.
- Non-finite results are rejected as `AccountingError::ValueNotFinite` rather
  than returned.
- Explicitly a one-way reporting boundary: output must never re-enter accounting.
- Compiles to WASM, so one implementation can serve the client and the Python
  post-processor.
- A Lean proof exists at `trade/proofs/TradeProofs/PortfolioValue.lean`.
- Fees, funding, and realized P&L are explicitly **out of scope**.

### Model B — strategy performance feed ([DEC-09S6G], proposed, 2026-08-11)

```text
total_pnl      = unrealized_pnl + realized_price_pnl + funding_pnl − realized_fees
unrealized_pnl = quantity × (assumed_liquidation_price − avg_entry_price)
                 − assumed_liquidation_fees
```

- P&L is four independent components that are never mixed.
- `avg_entry_price` is built from execution prices and quantities **only**. Fees
  are never in the basis, and are never reallocated when part of a position
  closes.
- Unrealized P&L answers "what would remain if we liquidated now", so it uses a
  live assumed liquidation price and assumed liquidation fees rather than
  historical trades.
- An execution larger than the open position splits at the zero-crossing: close
  everything, open the remainder in the opposite direction at the execution
  price.
- Implemented and unit-tested in `prototypes/accounting/src/vibing_pnl/logic.rs`;
  the model is written up in full, with worked examples, in
  `prototypes/accounting/docs/pnl.md`.

### The conflict

[DEC-09S6G] says directly that it diverges from `SPEC:backtest-feed` and
`SPEC:accounting-module` on cost-basis and accounting treatment, that those
records are references only rather than sources of truth, and that "the existing
accounting-related specs must be updated or superseded to match this model;
until then they disagree with this decision."

They were not updated. As of today:

| Record | Model | Status |
|--------|-------|--------|
| `SPEC:accounting-module` | A | current spec text |
| `SPEC:backtest-feed` | A | current spec text |
| [DEC-08C01] | A | proposed |
| [DEC-09S6G] | B | proposed |
| `trade-core/accounting/portfolio_value.rs` | A | implemented, unused by consumers |
| `prototypes/accounting/vibing_pnl/logic.rs` | B | implemented, prototype only |

Both decisions are `proposed`. Neither supersedes the other. **This is the
single highest-value thing to resolve** — every downstream storage, feed, and
UI question depends on which model wins.

## 2. What is actually built

### Three separate implementations, none shared

From `REF:portfolio-value-services`:

| Path | Returns | Calculates portfolio value? |
|------|---------|-----------------------------|
| `GET /api/v0/portfolio/current` | Latest positions and balances plus proxy USD prices | No — the client does an incomplete calculation |
| `GET /api/v0/portfolio/history` | Position bars, cashflows, attachment intervals | No — no prices, no aggregate values |
| Backtest post-processor (`pv_fold.rs`) | A historical portfolio-value series | Yes, with temporary pricing assumptions |
| `trade-core` accounting module | The intended shared formula | Yes — but no application service calls it |

The client-side calculation in
`structure-web/packages/client/src/portfolio/portfolio-derived-snapshot.ts` is
`sum(signed base quantity × returned price)` — position notional, not portfolio
value. It ignores derivative cost basis (so derivative unrealized P&L is never
computed), returns `pending` whenever any non-zero balance exists, and never
adds balance values to the total.

Known defects carried by the current path:

- A perpetual is priced from the underlying asset's Pyth USD price, not the
  exact contract's venue price. It is labelled `mark_price` regardless.
- Prices are always requested in USD; the returned `home_asset_id` is a
  placeholder.
- Position state and price time are not aligned — the latest stored snapshot is
  combined with the latest returned Pyth close.
- The history response has an optional `equity` field the service never sets,
  and the price field is commented out.
- History only queries events inside the requested window, without loading the
  last checkpoint before it, so the starting state can be missing.
- ClickHouse returns events newest-first and the service appends bars without
  re-sorting them chronologically.
- One strategy is assigned to an entire instrument history from a single bar.
- Data older than the 90-day ClickHouse retention is silently absent.

### Prototype trajectory

The work moved between prototypes without the Linear issues following it.

| Prototype | State | What it proves |
|-----------|-------|----------------|
| `prototypes/strategy-perf-view` | Bootstrap shell only | Vite + React + Hono + Rust/WASM `client-core` wire up. The component has one `on_feed_message` handler that increments a counter; the UI renders "Hello, world." |
| `prototypes/accounting` (`vibing_pnl`) | Runs end to end | Position, turnover, and valuation engines over generated parquet events; replays ~48 s of scenario then switches to live CoinAPI quotes; renders the strategy performance table once per second. ~880 lines of tested fold logic. |
| `prototypes/accounting` (`src/accounting`, `bin/accounting.rs`) | Empty stubs | The "proper" replay-engine line. `accounting/mod.rs` is 0 lines; `bin/accounting.rs` is a commented-out tick loop. |
| `prototypes/portfolio-value-feed-bandwidth` | Complete, measured | SSE feed sizing and market-info compression, native and WASM |
| `prototypes/portfolio-value-pyo3-prototype` | Experiment | PyO3/maturin path for the Python post-processor |
| `prototypes/chart-proto` | Complete | TradingView Lightweight Charts |
| `prototypes/component-host-wasm` | Complete | Rust component driven from TypeScript in WASM |

`vibing_pnl` is the name of the directory in the repository. Despite the name it
is the only end-to-end portfolio-value implementation that exists, it carries
the unit tests that replicate the `pnl.md` worked examples, and it holds the
benchmark harness.

### Linear reality

The `Strategy Performance Accounting` project's `Fills` milestone was closed out
on 2026-08-17: `ENG-1731` (download CoinAPI quotes) and `ENG-1732` (simulate
fills) are Done; `ENG-1733` (replay engine), `ENG-1734` (database egress
consumer), `ENG-1735` (GUI), and `ENG-1736` (logic module) were all **Canceled**
the same day. `ENG-1657` (Design Accounting) in the `Portfolio Value` milestone
is also Canceled.

ENG-1600 itself was In Progress from 2026-07-30 to 2026-08-03 and has been Todo
since. Its parent ENG-1318 has been Todo since 2026-07-01 with a due date of
2026-07-14.

## 3. Measurements

These are the most durable outputs of the work so far. All three constrain the
design directly.

### Feed bandwidth — 2026-07-24, per client, one multiplexed SSE connection

Uncompressed message sizes:

| Event | Raw protobuf | SSE data+id |
|-------|-------------:|------------:|
| Price update, 1 subject | 103 B | 160 B |
| Positions update, 1 position | 205 B | 296 B |
| Market-info catalog, 300 markets | 27.5 KiB | 36.6 KiB |

Market-info compression, Rust/WASM client decode:

| Codec | Payload | Decode | Throughput |
|-------|--------:|-------:|-----------:|
| gzip | 18,892 B | 233.2 µs | 115 MiB/s |
| **LZ4** | 21,111 B | **119.1 µs** | **225 MiB/s** |
| zstd | **17,712 B** | 262.8 µs | 102 MiB/s |

LZ4 is the recommendation for this workload: speed and WASM support are the
criteria, and it decodes ~2× faster than the alternatives at a modest size cost.
The optimized combined WASM module is 207.4 KiB.

Monthly egress at `$0.12/GiB`, 730 hours, uncompressed catalog, 5-minute stream
lifetime:

| Positions | 60 s tick | 5 s tick | 1 s tick |
|----------:|----------:|---------:|---------:|
| 10 | $0.05 | $0.22 | $0.94 |
| 50 | $0.10 | $0.74 | $3.55 |
| 100 | $0.15 | $1.39 | $6.83 |

The tick interval dominates cost far more than the position count. Moving from a
1 s to a 5 s tick is roughly a 4–5× saving at every position count.

### Client memory — [DEC-099MV], proposed, 2026-07-31

Startup warms four historical CoinAPI OHLCV series per price subject:

| Use | Lookback | Period | Bars |
|-----|----------|--------|-----:|
| Initial detailed history | 24 h | `1MIN` | 1,440 |
| 24-hour sparkline | 24 h | `5MIN` | 288 |
| 7-day sparkline | 7 d | `30MIN` | 336 |
| 30-day sparkline | 30 d | `2HRS` | 360 |
| **Total per subject** | | | **2,424** |

Coarse series are queried directly rather than derived from `1MIN` data —
deriving them is deferred. `1MIN` updates drive the current total portfolio
value; coarser updates only maintain their own buffers.

Every opened portfolio view owns **independent** ring buffers. Two views of the
same portfolio do not share or synchronize. This deliberately permits duplicate
in-memory bars and duplicate vendor requests, in exchange for interaction
isolation.

The architect review marks this decision **blocked**. Unsettled: which price
subjects belong in the startup hot set, which OHLC field and timestamp price a
historical point, exact buffer capacities and prefetch thresholds, missing-price
UI behavior, and live-subscription reconnect recovery.

### Cold fold cost — 2026-08-11, M-series MacBook, native release

Workload: 1 fill/sec on 2 markets, `1MIN` prices plus exrate, 8 h funding,
alternating sides so every second fill realizes P&L.

| Days | Rows | Parquet | Fold | Mevts/s | Samples | Sample time |
|-----:|-----:|--------:|-----:|--------:|--------:|------------:|
| 1 | 349,925 | 36 MB | 0.20 s | 1.77 | 1,441 | ~0 |
| 7 | 2,449,481 | 253 MB | 1.43 s | 1.72 | 10,081 | ~0 |
| 30 | 10,497,779 | 1.08 GB | 7.74 s | 1.36 | 43,201 | 0.01 s |

Fold throughput is flat at ~1.4–1.8M events/s, so cold start scales linearly at
~0.26 s/day. The engines themselves are a small fraction of that — parquet
decode of string-heavy prototype rows dominates. Report sampling is effectively
free: 43k report builds in 10 ms.

**This is the finding that redirected the work.** ~8 s with local files and no
network is unacceptable for a demo that should feel instant, so
"store only raw events, fold on client load" does not survive contact with a
30-day window. Intermediate checkpoints became necessary, and designing them is
where the effort went from 2026-08-12 onward.

## 4. Storage and checkpointing — in progress, undecided

The problem: total, realized, and unrealized P&L must be shown both since
inception and for an arbitrary window, without folding from the beginning of
time on every load.

Four constraints make a naive schema wrong:

1. Funding P&L applies only to perps and has its own currency.
2. Fee currency differs again.
3. Price quote units differ — the same spot asset sells on venues with different
   quote units.
4. The valuation asset is a client-side convenience and must not be baked into
   the dataset.

And one durability constraint: adding a new event kind — a new fee type,
rebate, borrowing cost, liquidation charge, tax — must not require a schema
change or a client update.

Three models are sketched in `prototypes/accounting/docs/storage.md` and
`storage2.md`:

1. **Postings** record every completed economic event.
2. **Account balances** give fast hourly realized-P&L totals.
3. **Position checkpoints** carry the state needed for unrealized P&L.

Native amounts stay the source of truth; valuation-asset conversions are derived
records that can be rebuilt. Every conversion must identify its price source,
market or conversion path, price type, observation time, and pricing-rule
version — because BTC/USDT on Binance is not BTC/USDT on Coinbase, and there is
no universal rate.

The sketched schema borrows double-entry structure (`Ledger`,
`EconomicAccount`, `Posting`, `EconomicAccountBalance`) with TigerBeetle's
currency-exchange recipe cited as the reference. Its own TODOs are unresolved:

- clear "intents" so a client knows whether a new account kind adds or subtracts
  from P&L, without updating every client;
- walking the full flow of fill, buy, partial sell, close, flip, and the same
  for fees;
- how to express the checkpoint interval instead of hard-coding an hour.

[DEC-09S6G] deliberately defers the ledger: journal entries are interpretations
of raw events, not original facts, so a ledger can be derived later without
changing the persisted events. Storage target is ClickHouse for deployments and
DuckDB for backtests.

## 5. Ordering across feeds

Every venue has its own orderand — CME is `{year, week, sequence_number}`,
Hyperliquid is `{block, transaction, instruction}`. Adding a venue would
otherwise break types and storage each time.

[DEC-09S6G] resolves this with one shared shape:

```rust
struct DataFeedOrderand { feed_id: FeedId, sn: u64 }
```

Rules:

1. Per-feed `sn` is monotone but sparse. Gaps are normal and never mean data
   loss — source-level gap detection stays in the feed adapter, using the
   venue-native orderand preserved as opaque bytes on the event.
2. A derived view includes an event when `sn <= frontier[feed_id]`.

The design deliberately does **not** claim cross-feed causal ordering. It cannot
tell you whether a CME trade happened before a Hyperliquid trade. It can tell you
exactly which fills contributed to a position quantity, which is what the fold
needs — a BTC spot position can be built from fills on many venues.

## 6. Demo-scope simplifications

These are accepted, deliberate, and must not be presented as the real behavior.

- **Return ignores cash flows.** The correct formula accounts for deposits and
  withdrawals. We have no deposit/withdrawal events and handling them properly
  costs more time than the demo has, so team consensus is `PV_end / PV_start − 1`.
  Tracked as [ISS-099NW] / [ENG-1634].
- **The live strategy is not really live.** Backtest data is inserted as paper
  deployment info, so attach and detach of the trading account never appear.
- **The client talks to the vendor directly.** Acceptable for an internal demo;
  tracked as `ISS-099M7` / [ENG-1625].
- **Fees are approximated as a percentage of slippage** rather than modelled per
  venue. The percentage and the fact that it is an approximation must be
  explicit. Tracked in [ISS-09K80] / [ENG-1659].
- **No storage schema for prototype positions.** The generator writes serialized
  protobuf messages to one file in chronological order. DuckDB and chDB were
  considered and rejected for the prototype.

## 7. Price data

CoinAPI is the source. `REF:coin-api-market-data` is current and complete; the
limits below are the ones that shape the design.

- Symbol IDs **must** come from `GET /v1/symbols/map/HYPERLIQUID` or
  `/v1/symbols/HYPERLIQUID/active`, never derived from Hyperliquid market names.
- Historical OHLCV below `1MIN` must stay within one calendar day when reaching
  data older than 12 hours — confirmed by an HTTP 400 on 2026-07-30.
- Historical OHLCV responses cap at 100,000 items, default 100. Each 100 output
  items bills as one request.
- WebSocket sequence numbers are scoped to one `(type, symbol_id)` pair and one
  connection lifetime, so they cannot establish continuity across reconnects.
- On backpressure CoinAPI disconnects and drops buffered messages without
  replay. An independent reconnect and historical-gap recovery path is required.
- REST limits are plan-dependent and reported in response headers. The observed
  2026-07-30 tier was concurrency 2, 40 requests/minute.

The client does not build candles from quotes. CoinAPI streams provisional OHLCV
updates for the current period and then a closing update; the client keys bars by
subject, period, and period start, and a later message replaces the same entry.

Fetching architecture is designed but not built. The recurring shape across
prices, positions, market info, and logs is three layers: core logic that knows
where to fetch and how to build efficient batched requests; a transport decoder
that identifies and decodes messages; and a NATS-like dispatch layer that routes
decoded data to subscribed business units. `PriceSourcePlanner` and
`CoinApiRequestPlan` in `prototypes/price-source-resolver` are the current
sketch. The open questions — what to name the fetcher, how a component knows a
given transport message belongs to it, and how one message reaches several
independent handlers — are recorded but unanswered.

## 8. Client architecture

The intended shape, consistent across every source:

- Portfolio-value logic lives in Rust and compiles to WASM as `client-core`.
  JavaScript owns only the view.
- The WASM boundary passes pointers and primitives, not serialized position
  arrays. The position tracker already lives in WASM, so
  `portfolio_value_wasm(price_tracker, position_tracker, &account_ids, valuation_asset_id) -> Vec<f64>`
  avoids marshalling cost. `Vec<f64>` is only appropriate when the result is
  visualized rather than computed on.
- Market info is sent on connect/reconnect as rkyv-encoded domain entities inside
  a protobuf envelope — rkyv specifically to avoid authoring intermediate message
  schemas for internal domain entities.
- Positions and prices arrive on a timer; everything is base64-encoded inside a
  protobuf envelope over SSE.
- Cloud Run's request timeout defaults to 5 minutes and extends to 60, which is
  what makes stream lifetime a bandwidth variable.

`TimeSeriesChart` ([DEC-09GKC]) is host- and domain-neutral, owns its visible
range and series kind after initialization, and reports the selected observation
timestamp to its consumer. The consumer owns the full time range and supplies
bounded loaders. Queries are bounded by requested range and display resolution.
The strategy performance component is meant to reuse it.

`LitePortfolioView` in `stxr-ui` is specified and represents exactly one trading
environment (Live or Paper) at a time, never aggregating across them. It offers
`24H` / `7D` / `30D` ranges — which is exactly what [DEC-099MV]'s three sparkline
series were sized for.

## 9. Open questions

Ordered by how much else depends on them.

1. **Which accounting model is canonical — [DEC-08C01] or [DEC-09S6G]?** Both are
   proposed; neither supersedes the other; the specs still describe the first.
   Everything below is downstream of this.
2. **What is the checkpoint schema?** Explicitly deferred by the decision writer.
   Without it the 30-day cold start stays at ~7.7 s.
3. **Which OHLC field and timestamp price a historical portfolio-value point?**
   Blocks [DEC-099MV] acceptance.
4. **Which `PriceSubject` values belong in the startup hot set?** Determines
   whether "2,424 bars per subject" is cheap or ruinous.
5. **How does a newly added position get a price it does not have yet?** Open in
   `NOTE-097X4`; no path exists.
6. **Do we retain historical prices?** Open in `NOTE-097X4`.
7. **How does the live subscription recover bars missed during disconnection?**
   CoinAPI drops without replay, so this is required, not optional.
8. **Does the position table show every event, or one reconstructed row per
   account and position at the selected time?**
9. **How much history does the browser retain after a range change?**
10. **How is the Rust function exposed — PyO3, WASM bindings, or both?**
    [DEC-08C01] adopts the interface, not the binding.
11. **What is the provenance link type from a target position back to its
    triggering source event?** Open in [DEC-09S6G].

## 10. Suggested next steps

1. **Resolve the model conflict.** Either accept [DEC-09S6G] and supersede
   [DEC-08C01] plus both specs, or scope [DEC-09S6G] to strategy performance and
   say explicitly that [DEC-08C01] remains canonical for portfolio value. The
   current ambiguity silently invalidates the Lean proof's relevance and leaves
   two implementations diverging.
2. **Point ENG-1600 at reality.** The issue describes `strategy-perf-view`, but
   the work happened in `prototypes/accounting`. Either update the issue to
   reference the accounting prototype, or close it and open one that matches.
3. **Record the 2026-08-17 cancellations.** Four `Fills` milestone issues were
   canceled the same day with no note explaining the pivot. The reason —
   cold-fold cost forcing checkpoints — is real and worth capturing before it is
   forgotten.
4. **Write the checkpoint decision.** It is the blocker for a demo-quality load
   time, and the constraints are already fully enumerated in `storage.md`.
5. **Unblock [DEC-099MV]** by answering the OHLC-field, startup-subject, and
   reconnect-recovery questions its architect review names.
6. **Fold `prototypes/accounting/docs/pnl.md` into the knowledge base.** It is
   the most complete written artifact on this topic and currently lives only in
   a prototype directory.

[DEC-08C01]: https://github.com/stxr-prop/knowledge-base/blob/main/docs/decisions/records/DEC-08C01-accounting-module.md
[DEC-099MV]: https://github.com/stxr-prop/knowledge-base/blob/main/docs/decisions/records/DEC-099MV-client-historical-price-caching-for-portfolio-views.md
[DEC-09GKC]: https://github.com/stxr-prop/knowledge-base/blob/main/docs/decisions/records/DEC-09GKC-demo-app-backtest-view-and-reusable-chart.md
[DEC-09S6G]: https://github.com/stxr-prop/knowledge-base/blob/main/docs/decisions/records/DEC-09S6G-strategy-performance-feed.md
[ISS-099NW]: https://github.com/stxr-prop/knowledge-base/blob/main/docs/issues/records/ISS-099NW-portfolio-return-and-value-do-not-account-for-cash-flows.md
[ISS-09K80]: https://github.com/stxr-prop/knowledge-base/blob/main/docs/issues/records/ISS-09K80-backtest-results-accounting.md
[ENG-1625]: https://linear.app/stxr/issue/ENG-1625
[ENG-1634]: https://linear.app/stxr/issue/ENG-1634
[ENG-1659]: https://linear.app/stxr/issue/ENG-1659
