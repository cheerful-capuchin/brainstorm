# Structure v0.0 demo — Linear reconciliation

Date: 2026-08-17

Linear project: [Structure v0.0: Demo app](https://linear.app/stxr/project/structure-v00-demo-app-f783a56b24eb)

This is a local, read-only reconciliation. Nothing in Linear was changed.

## Summary

The project has 16 milestones and 144 issues. The proposed work contains 20
tasks, but several already exist under different milestones or broader issues.
Creating all 20 as new issues would introduce duplicates.

The clearest gaps are:

- the client-side Rust/WASM market-info module;
- CME venue and futures-domain support;
- the historical Databento download and replay path;
- the Rust backtest post-processor file ingress;
- Sim GW and Event GW work for the deployment performance feed;
- demo authentication; and
- the library UI, if it is not included in the existing library issues.

The main decisions still needed are:

- which ten CME futures are in scope, because the supplied top-ten list contains
  two options and therefore only eight futures;
- whether the demo claims live Databento data or historical data replayed as a
  live stream;
- whether Databento records stay provider-native or are converted into the
  message shape consumed by the historical replayer;
- whether a fill triggers a valuation-price batch, because the current
  backtest-feed decision explicitly says that it does not; and
- whether Group Library means node groups only or both node groups and custom
  functions.

## Milestone reconciliation

| Proposed milestone | Current Linear location | Reconciliation |
| --- | --- | --- |
| Market Info | No dedicated milestone | New milestone, or place the task under Portfolio Value. The production debt issue ENG-1624 is related but is not the same work. |
| CME Markets | `CME Mkt Data` | Reuse the existing milestone. It currently has no issues. |
| Strategy Variables | `Strategy Builder` | Reuse ENG-1685. Do not create a new milestone. |
| Backtest | `Backtest` and `Backtest Feed` | Reuse both. The feed is already designed; implementation and reconciliation remain. |
| Backtest Performance View | `Backtest` | Reuse the Backtest milestone. The UI exists; its data and query path remain incomplete. |
| Strategy Deployment Feed | `Strategy Deployment` | Reuse the existing milestone. |
| Strategy Deployment Performance View | `Strategy Deployment` | Reuse the existing milestone and umbrella issue ENG-1618. |
| Portfolio Value Sidebar | `Portfolio Value` | Reuse the existing milestone. The static UI is done in ENG-1603; real data remains in ENG-1318. |
| Authentication | No dedicated milestone | Put the demo-only task under Demo Infra unless a separate milestone is useful. |
| Tick Navigator | `Tick Navigator` | Reuse the existing milestone and ENG-1621. |
| Group Library | `Node Group Library` and `Custom Function Library` | Decide whether the proposed UI covers one or both libraries. |

## Task reconciliation

### Market Info

#### Create a Rust/WASM client-core module containing `StaticMktInfoRepo`

**Proposed:** 2 points; Negative Nilgiri

**Verdict:** Missing as an actionable issue. ENG-1318 and ENG-1600 mention a
Rust/WASM client core, while ENG-1624 tracks the longer-term problem with static
market info. None of them owns the concrete setup described here.

**Concise context:** Embed the demo market-info dataset in the client so the
client does not need a market-info request or a new network contract.

**Task:**

- create the GitHub repository and Rust crate;
- add `StaticMktInfoRepo`;
- expose a small TypeScript API that includes presentation information; and
- build the crate as WebAssembly.

### CME Markets

The existing `CME Mkt Data` milestone has no issues. All tasks below are missing
from this project, although some related Databento work exists in the separate
`Structure v0.1: MD Breadth & UI Polish` project.

#### Add CME Group venues

**Proposed:** 1 point; Cheerful Capuchin

**Verdict:** Missing. The narrow enum change may fit one point, but it does not
by itself make the platform CME-capable.

Keep the supplied venue context unchanged. The task should say:

> Add `Cme`, `Cbot`, `Nymex`, and `Comex` to the Rust and TypeScript venue
> models. Append stable numeric values; do not insert or renumber existing
> values. Resolve `GLBX.MDP3` instruments from the definition record's exchange
> MIC, not from `GLBX`, `publisher_id`, or the symbol alone.

When this issue is created, add the complete contents of
`brainstorm/reports/demo/venue-blast-radius.md` as a comment. That report shows
the required codec, schema, conversion, exhaustive-match, and runtime follow-up
work.

#### Design CME futures and asset-class groupings

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Missing, but the current title is ambiguous.

**Concise context:** Structure currently models spot and perpetual markets. CME
requires a futures market type and enough contract information to calculate
quantity, notional value, and PnL correctly. Interest Rates, Commodities, and
Equities are useful presentation groupings, but they do not replace the futures
domain type.

**Task:** Design the minimum futures model for the demo, including contract
identity, expiry, multiplier, tick size, settlement asset, and asset-class
grouping for Interest Rates, Commodities, and Equities.

#### Finish the Databento market-data server design for the demo

**Proposed:** Design; 2 points; Cheerful Capuchin

**Verdict:** Do not start from scratch. DEC-08T3R already designs the live
`dbn-md-server`, and ENG-1488 tracks the prototype in another project. The
consumer contract and historical replay are still undecided.

**Concise context:** Paper deployments need CME market data. The existing
[Databento prototype](https://github.com/stxr-prop/prototypes/tree/main/databento-md)
can decode market data and definitions, while DEC-08T3R proposes the live server.
The missing design is how the demo consumer and historical replayer read the
published data.

**Task:** Reconcile the existing live-server design with the demo path. Decide
whether consumers decode provider-native DBN records or receive normalized
Structure messages, and define the bridge into paper deployment and historical
replay.

#### Design the historical market-data download job

**Proposed:** Design; 2 points; Cheerful Capuchin

**Verdict:** Missing. DEC-08T3R explicitly leaves historical replay and backfill
undecided.

**Concise context:** Download the last three months of data for the selected CME
futures. The output must preserve the definitions and ordering information that
the backtest historical-data replayer needs.

**Task:** Define the symbols and dated contracts, schemas, definition cut,
storage format, ordering data, validation, and handoff to the historical-data
replayer.

#### Add the ten selected highest-volume CME futures

**Proposed:** 1 point; Cheerful Capuchin; blocked by the futures model

**Verdict:** Missing and blocked by a product-scope decision.

The current list contains two option products: options on Three-Month SOFR
futures and options on 10-Year T-Note futures. Either select two replacement
futures or explicitly reduce the scope to eight futures before creating this
issue.

### Strategy Variables

#### Review the Application Server API updates for strategy variables

**Proposed:** Code review; 1 point; Cheerful Capuchin

**Verdict:** Already exists as [ENG-1685](https://linear.app/stxr/issue/ENG-1685),
which is Ready For Review with a 2-point estimate. Do not create a duplicate.

**Concise context:** The Application Server must accept and validate variable
bindings when creating both a backtest and a strategy deployment. Review
[structure-web PR #152](https://github.com/stxr-prop/structure-web/pull/152) and
the linked client and messaging changes as one contract change.

### Backtest

#### Reconcile the demo requirements with the existing backtest feed

**Proposed:** Design; 2 points; Cheerful Capuchin

**Verdict:** Partly covered. ENG-1291 is complete, DEC-07Z4J and
`SPEC:backtest-feed` already define the feed, and ENG-1544 owns remaining
provenance and ordering questions. Reuse ENG-1544 or explicitly replace its
scope; do not create another general feed-design issue.

**Concise context:** Confirm that the existing feed covers fills, target
positions, logs, triggering source-event provenance, and valuation prices. Also
resolve the price-sampling conflict: DEC-07Z4J emits complete price batches
before position updates and on a maximum interval, and explicitly says a fill
does not trigger a batch. The proposed fill, timer, and volatility triggers are
a semantic change.

#### Design the Rust post-processor ingress producer

**Proposed:** Design; 1 point; Cheerful Capuchin; blocked by feed reconciliation

**Verdict:** Missing. ENG-1309 covered a Python post-processor and is canceled.

**Concise context:** Make the Rust backtest post-processor read the ordered
backtest feed from its JSONL artifact and report malformed, incomplete, or
out-of-order input explicitly.

#### Design the backtest DuckDB schema

**Proposed:** Design; 2 points; Cheerful Capuchin; blocked by feed reconciliation

**Verdict:** Already exists as [ENG-1642](https://linear.app/stxr/issue/ENG-1642),
assigned to Malicious Marmoset with an 8-point estimate. Reconcile ownership,
estimate, and whether its experimental UI work is still required; do not create
a duplicate.

#### Design the backtest simulator to emit the feed

**Proposed:** Design; 2 points; Cheerful Capuchin; blocked by feed reconciliation

**Verdict:** Already covered by ENG-1382 and ENG-1327. ENG-1382 specifically
owns definition-first output, dictionary encoding, and price updates. Reuse
those issues.

### Backtest Performance View

#### Design the Backtest Performance View

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Mostly covered. ENG-1310 owns the visualizer design, ENG-1642 owns
the DuckDB/query experiment, and ENG-1653 completed the chart and position UI.
The remaining work is the real data contract and accounting, not another
general UI design.

The view should read positions, trades, logs, prices, target positions, PnL,
volume, and return from DuckDB. ENG-1659 remains required for volume and
slippage data, and ENG-1634 remains required for cash-flow-correct portfolio
value and return.

### Strategy Deployment Feed

The umbrella issue [ENG-1618](https://linear.app/stxr/issue/ENG-1618) already
owns the deployment feed and live performance view.

#### Design events emitted by the strategy component

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Partly covered. ENG-1485 owns target-position emission, and the
strategy-logging work owns logs. Triggering source events and their provenance
still need to be reconciled with DEC-09S6G.

**Concise context:** The strategy component must emit target positions,
triggering source events, and logs with enough shared identity to explain why a
deployment traded.

#### Design events emitted by Sim GW

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Missing as a focused issue.

**Concise context:** Sim GW must emit fills, position updates without cost basis,
and deposits or withdrawals. The events must carry the identity and ordering
needed by Event GW to derive deployment performance.

#### Design the Event GW accounting module

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Missing as a deployment issue. ENG-1659 covers related backtest
accounting but not this live Event GW path.

**Concise context:** For every fill, store the source event and derive the
position, realized PnL, and trading volume in base and quote units. Store
triggering source events, target positions, fills, position updates, logs,
volume, and realized PnL so the deployment can be replayed and explained.

### Strategy Deployment Performance View

#### Design the Strategy Deployment Performance View

**Proposed:** Design; 4 points; Cheerful Capuchin

**Verdict:** Covered by ENG-1618 at the milestone level and by ENG-1600 as the
shared prototype. Create a separate design issue only if ENG-1618 is intended
to remain an umbrella.

**Concise context:** Show deployment performance over selectable time windows.
Use live prices to maintain the current one-minute candle, load historical
candles for the visible period, poll recent ClickHouse data, and calculate
unrealized PnL, portfolio value, return, volume, and rolling metrics such as
Sharpe. For the demo, settlement assets are treated as 1:1 with USD.

The view needs the listed position and trade fields. It also depends on:

- ENG-1586 for deployment-owned trading accounts;
- the deployment feed tasks above;
- ENG-1659 for volume and execution-cost data; and
- ENG-1634 for cash-flow-correct portfolio value and return.

### Portfolio Value Sidebar

#### Connect the Portfolio Value Sidebar to real data

**Proposed:** Design; 2 points; Cheerful Capuchin

**Verdict:** The UI is already complete with static data in ENG-1603. Do not
create another design issue. The remaining work belongs to ENG-1318 and the
shared valuation path.

**Concise context:** Show total portfolio value and capital allocated to each
deployment. Replace the static values with the bounded historical and live
state described by DEC-099MV and NOTE-097X4. Deployment allocation also depends
on ENG-1586.

### Authentication

#### Implement demo-client authentication

**Proposed:** 1 point; Malicious Marmoset

**Verdict:** Missing. It appears only as a comment on ENG-1620.

**Concise context:** For the internal demo only, bundle a dedicated demo Solana
keypair and automatically authenticate the same demo user at startup. Keep this
path isolated from production authentication and never use a production key.

### Tick Navigator

#### Design the Tick Navigator UI

**Proposed:** Design; 4 points; Grumpy Gorilla

**Verdict:** Partly covered by ENG-1621, which already owns the trace contract,
loader, and UI. Use it as the parent or expand it instead of creating an
unrelated issue.

**Concise context:** Let the presenter follow one prepared evaluation from its
source event through evaluated nodes, target positions, egress, and logs. Use a
trace captured from real data, but keep the prepared-trace shortcut explicit.
The strategy and dataset that produce the clearest bad-trade example still need
to be selected.

### Group Library

#### Design the library UI

**Proposed:** Design; 2 points; Grumpy Gorilla

**Verdict:** The exact UI task is missing, but related work exists in ENG-1622,
ENG-1486, ENG-1623, and ENG-170.

**Concise context:** Design a small library view for browsing, opening, and
using saved node groups. If the same view also includes custom functions, say so
explicitly and account for the accepted demo limitation that custom functions
can be defined but cannot execute in strategies.

## Required work absent from the proposed list

These are already known and should not disappear when the new tasks are added:

- **ENG-1586 — Attach Trading Accounts To Strategy Deployments.** Required for
  deployment-specific allocation and performance.
- **ENG-1659 — Backtest Results Accounting.** This existing unprojected issue is
  required for volume, slippage, and persisted economic events. Decide whether
  it belongs in the demo project.
- **ENG-1634 — Portfolio Return And Value Do Not Account For Cash Flows.**
  Required for correct return and value when deposits or withdrawals occur.
- **Databento consumer integration.** The server and download job are not
  sufficient until the paper-deployment and backtest consumers can read the
  chosen message contract.
- **Futures contract economics.** Adding venue values and asset-class labels is
  not sufficient without contract identity, expiry, multiplier, tick size, and
  settlement semantics.

## Suggested next reconciliation pass

Before changing Linear:

1. Select the final ten futures or approve an eight-future scope.
2. Choose historical replay or a genuine live Databento claim for the demo.
3. Resolve the DBN provider-native versus normalized consumer contract.
4. Resolve the backtest price-sampling conflict with DEC-07Z4J.
5. Decide whether the library UI covers node groups only or both libraries.
6. Confirm which existing umbrella issues should receive sub-issues and which
   should be edited in place.
