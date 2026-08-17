# Portfolio Value — source index

Date: 2026-08-18

Every artifact consolidated into [README.md](README.md), what it contributed,
and its state. Paths are relative to the workspace root unless they are URLs.

## Knowledge base — decisions

| Record | Status | Contribution |
|--------|--------|--------------|
| `DEC-08C01-accounting-module.md` | proposed 2026-07-10 | Model A formula, `f64` + `ReportingScale` rationale, trait interface, Lean proof reference |
| `DEC-09S6G-strategy-performance-feed.md` | proposed 2026-08-11 | Model B P&L decomposition, four engine responsibilities, `DataFeedOrderand`, ledger deferral |
| `DEC-099MV-client-historical-price-caching-for-portfolio-views.md` | proposed 2026-07-31, review **blocked** | 2,424 bars/subject budget, four warm series, independent view buffers, five blocking questions |
| `DEC-09GKC-demo-app-backtest-view-and-reusable-chart.md` | proposed 2026-08-05 | `TimeSeriesChart` boundary, bounded queries, DuckDB artifact |
| `DEC-08ABG-price-tracker.md` | proposed | One current price per subject; time and staleness unsettled |
| `DEC-088YR-price-source-resolver.md` | — | Exact-market contract prices, bounded asset-price paths |
| `DEC-0892S-coin-api-current-price-resolver.md` | — | CoinAPI as current-price source |
| `DEC-08VKD-trading-account-position-update-feed.md` | proposed | Full/partial, absolute/increment position updates |
| `DEC-08NS2-mkt-data-feed-price-update.md` | proposed | Price update feed shape |

## Knowledge base — notes, issues, references, specs

| Record | Status | Contribution |
|--------|--------|--------------|
| `NOTE-097X4-strategy-performance-view-prototype.md` | raw 2026-07-30 | ENG-1600 prototype goal, missing pieces, Q&A, open questions |
| `NOTE-093V8-demo-app-v0-0.md` | — | Demo app v0.0 context |
| `ISS-099NW-...-cash-flows.md` | open, [ENG-1634](https://linear.app/stxr/issue/ENG-1634) | Return/value ignore deposits, withdrawals, funding, fees |
| `ISS-09K80-backtest-results-accounting.md` | open, [ENG-1659](https://linear.app/stxr/issue/ENG-1659) | Per-position volume, slippage, fee-as-%-of-slippage approximation |
| `ISS-099M7-demo-client-fetches-vendor-market-data-directly.md` | open | Client-to-vendor access is demo-only |
| `REF:portfolio-value-services` | living, reviewed 2026-07-27 | The three-implementations table and every current-path defect |
| `REF:coin-api-market-data` | living, reviewed 2026-07-30 | Endpoints, symbol discovery, all vendor limits |
| `REF:client-views` | living, reviewed 2026-07-31 | Strategy Performance is a component, planned — not built |
| `SPEC:accounting-module` | current text | Still describes Model A |
| `SPEC:backtest-feed` | current text | Still describes Model A |

## Prototypes

| Path | State | Contribution |
|------|-------|--------------|
| `prototypes/accounting/docs/pnl.md` | 971 lines, complete | The full Model B write-up with worked examples. Not in the knowledge base. |
| `prototypes/accounting/docs/storage.md` | complete | Three-model storage rationale, four multi-currency challenges |
| `prototypes/accounting/docs/storage2.md` | sketch + TODOs | Ledger/posting/economic-account schema; unresolved intents, flows, interval |
| `prototypes/accounting/docs/feed.md` | 494 lines | Feed event trait shapes |
| `prototypes/accounting/src/vibing_pnl/logic.rs` | 879 lines, tested | The only working Model B implementation |
| `prototypes/accounting/src/vibing_pnl/bench.rs` | complete | The 1/7/30-day fold benchmark |
| `prototypes/accounting/README.md` | complete | Engine descriptions and benchmark table |
| `prototypes/accounting/plan.md` | complete | Event-heap replay design, milestone slices |
| `prototypes/accounting/src/accounting/mod.rs` | **0 lines** | The "proper" line, never started |
| `prototypes/accounting/bin/accounting.rs` | commented-out stub | Replay engine, canceled as [ENG-1733](https://linear.app/stxr/issue/ENG-1733) |
| `prototypes/accounting/db/schema.sql` | partial | DuckDB `feed_data` and `fills` tables only |
| `prototypes/portfolio-value-feed-bandwidth/RESULTS.md` | complete 2026-07-24 | All bandwidth, compression, and egress-cost numbers |
| `prototypes/strategy-perf-view/` | bootstrap shell | Vite + Hono + WASM wiring; renders "Hello, world." |
| `prototypes/price-source-resolver/` | design sketches | `PriceSourcePlanner`, `CoinApiRequestPlan`, three-layer pattern |
| `prototypes/component-feed/` | design sketches | Component/consumer/handler layering |
| `prototypes/portfolio-value-pyo3-prototype/` | experiment | PyO3 path for the Python post-processor |
| `prototypes/chart-proto/` | complete | TradingView Lightweight Charts |
| `prototypes/component-host-wasm/` | complete | Rust component driven from TypeScript |

## Implementation

| Path | Model | State |
|------|-------|-------|
| `trade/crates/trade-core/src/accounting/portfolio_value.rs` | A | Implemented; no application service calls it |
| `trade/proofs/TradeProofs/PortfolioValue.lean` | A | Lean proof |
| `structure-web/packages/api/src/portfolio/portfolio-service.ts` | — | Current portfolio API; returns inputs, not value |
| `structure-web/packages/api/src/portfolio/portfolio-history-service.ts` | — | History API; no prices, no values |
| `structure-web/packages/client/src/portfolio/portfolio-derived-snapshot.ts` | partial A | Position notional only; ignores cost basis and balances |
| `backtest-post-processor/src/pv_fold.rs` | A-ish | Own fold with temporary pricing assumptions |
| `trade/crates/coin-api/` | — | Current-price resolution; historical and WS endpoints missing |
| `stxr-ui/packages/ui/src/portfolio/lite-portfolio-view/` | — | Specified; `24H`/`7D`/`30D`, one environment at a time |

## Prompt transcripts

| Path | Contribution |
|------|--------------|
| `notes/2026-07-02-portfolio-value.md` | Original architecture: one Rust implementation, WASM boundary shape, SSE feed design, Cloud Run timeout |
| `notes/2026-07-02-portfolio-value-python.md` | `PriceTracker` / `MutablePriceTracker` traits, feed-consumer handler pattern |
| `prompts/2026-07-30-strategy-performance-prototype.md` | `PV_end/PV_start − 1` consensus, prototype scope, storage Q&A |
| `prompts/2026-08-03-strategy-performance.md` | Three-layer fetching pattern, `PriceSourcePlanner`, four open design questions |
| `prompts/2026-08-07-accounting.md` | Checkpoint requirement, multi-currency constraints, feed traits, Q&A |
| `prompts/2026-08-07-financial-accounting.md` | Double-entry background |
| `prompts/2026-08-14-accounting.md` | **The 8-second finding and the pivot to checkpoints** |
| `brainstorm/prompts/accounting/progress-update.md` | The five-milestone vertical slice plan behind the Linear project |
| `p.md` | The positions/trades table column list, and the UI mismatch questions |
| `prototypes/accounting/tasks/ENG-1733: Create the replay engine.md` | Replay engine design; issue since canceled |

## Linear

| Issue | Status | Note |
|-------|--------|------|
| [ENG-1600](https://linear.app/stxr/issue/ENG-1600) | Todo | This issue. In Progress 2026-07-30 → Todo 2026-08-03 |
| [ENG-1318](https://linear.app/stxr/issue/ENG-1318) | Todo | Parent. Due 2026-07-14; Todo since 2026-07-01 |
| [ENG-1639](https://linear.app/stxr/issue/ENG-1639) | Todo | CoinAPI historical + live feed |
| [ENG-1607](https://linear.app/stxr/issue/ENG-1607) | Done | Embedding ClickHouse on the client |
| [ENG-1657](https://linear.app/stxr/issue/ENG-1657) | **Canceled** | Design Accounting |
| [ENG-1731](https://linear.app/stxr/issue/ENG-1731) | Done | Download CoinAPI quotes |
| [ENG-1732](https://linear.app/stxr/issue/ENG-1732) | Done | Simulate fills |
| [ENG-1733](https://linear.app/stxr/issue/ENG-1733) | **Canceled** 2026-08-17 | Replay engine |
| [ENG-1734](https://linear.app/stxr/issue/ENG-1734) | **Canceled** 2026-08-17 | Database egress consumer |
| [ENG-1735](https://linear.app/stxr/issue/ENG-1735) | **Canceled** 2026-08-17 | GUI |
| [ENG-1736](https://linear.app/stxr/issue/ENG-1736) | **Canceled** 2026-08-17 | Logic module writing fills |
| [ENG-1763](https://linear.app/stxr/issue/ENG-1763) | — | Related to ENG-1600: client market info repo |

Projects: [Structure v0.0: Demo app](https://linear.app/stxr/project/structure-v00-demo-app-f783a56b24eb)
(milestone `Portfolio Value`) and
[Strategy Performance Accounting](https://linear.app/stxr/project/strategy-performance-accounting-ed0369fde5bc)
(milestones `Fills`, `Volume`, `Unrealized Pnl`, `Realized Sell`, `Fees`, `Tracing`).
