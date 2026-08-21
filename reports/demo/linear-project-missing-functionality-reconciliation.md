# Structure v0.0 demo — Linear reconciliation

Date: 2026-08-17

Source: [fill-in-linear.md](../../prompts/demo/fill-in-linear.md)

Current Linear project: [Structure v0.0: Demo app](https://linear.app/stxr/project/structure-v00-demo-app-f783a56b24eb)

Existing Linear initiative: **Demo Structure v0**

This is a local, read-only reconciliation. Nothing in Linear was changed.

## Summary

The current project mixes major product features and engineering components as
flat milestones. The proposed structure uses projects for the product view,
milestones for delivery gates, and a Component issue-label group for the
engineering view.

Several proposed tasks are already covered by issues in the demo project.
Existing work is referenced by its ENG identifier instead of being restated as
a new task.

The clearest gaps remain:

- the client-side Rust/WASM market-info module;
- CME venue and futures-domain support;
- the historical Databento download and replay path;
- the Rust backtest post-processor file ingress;
- Sim GW and Event GW work for the deployment performance feed;
- demo authentication; and
- the Group Library design, Strategy Builder integration, testing, and founder
  verification around the existing node-group and custom-function work.

## Linear structure

The hierarchy is:

1. **Initiative** — Demo Structure v0
2. **Project** — a major demo feature
3. **Milestone** — the delivery gate an issue advances
4. **Component label** — the system component affected by the issue
5. **Issue** — a concrete unit of work

Milestone placement in this document identifies the gate that an issue advances.
It does not claim that the issue has reached that gate, and it does not replace
the issue's workflow status.

Issue descriptions should contain only the reconciled context and task. Do not
add generated acceptance criteria or expand the scope beyond the source
document.

### Projects

Create the following projects under the existing initiative:

- **Structure Demo: Market Info**
- **Structure Demo: CME Markets**
- **Structure Demo: Strategy Variables**
- **Structure Demo: Backtest**
- **Structure Demo: Strategy Deployment**
- **Structure Demo: Portfolio Value**
- **Structure Demo: Client App**
- **Structure Demo: Group Library**

Backtest Feed, Backtest Simulator, and Backtest Post-Processor are components of
**Structure Demo: Backtest**, not separate product projects. The same principle
applies to the strategy, Sim GW, Event GW, and performance-view components of
**Structure Demo: Strategy Deployment**.

### Milestones

Every project uses the same milestones:

- **Designed** — The intended behavior, boundaries, and contracts are captured
  in an accepted DEC or SPEC. Design questions that block implementation are
  resolved.
- **Ready for Integration** — The code is written, reviewed, and verified in
  isolation. Other components can begin integrating with it, but no end-to-end
  integration is claimed yet.
- **Integrated** — The necessary system components use the feature through its
  agreed contracts. The relevant end-to-end paths work.
- **Deployed** — The integrated feature is running in Structure-managed
  infrastructure with the configuration and operational dependencies required
  by the demo.
- **Founder Approved** — The deployed feature has been tested through its
  intended demo flow and approved by the founder. Blocking feedback has been
  resolved.
- **Done** — The feature is complete for the agreed demo scope, with no
  remaining work required for that scope.

### Issue-label group

Create one mutually exclusive issue-label group named **Component**. An issue
gets the single component label that owns the work, while unrelated labels such
as Design or Code Review can still be applied independently.

| Project | Component labels |
| --- | --- |
| Structure Demo: Market Info | Market Info |
| Structure Demo: CME Markets | CME Domain Model; Databento Market Data Server; Historical Market Data |
| Structure Demo: Strategy Variables | Strategy Variables |
| Structure Demo: Backtest | Backtest Feed; Backtest Simulator; Backtest Post-Processor; Backtest Performance View |
| Structure Demo: Strategy Deployment | Strategy Component; Sim GW; Event GW; Strategy Deployment Performance View |
| Structure Demo: Portfolio Value | Portfolio Value Sidebar |
| Structure Demo: Client App | Demo Authentication |
| Structure Demo: Group Library | Node Group Library; Custom Function Library |

The Group Library includes both node groups and custom functions. Apply the
component label for the library affected by each issue.

## Project reconciliation

### Structure Demo: Market Info

#### Ready for Integration

##### Create a Rust/WASM client-core module containing StaticMktInfoRepo

**Component:** Market Info

**Proposed:** 2 points; Negative Nilgiri

**Verdict:** Missing as an actionable issue. The related existing issues do not
own the concrete setup described here.

**Context:** Embed the demo market-information dataset in the client so the
client does not need a market-information request or a new network contract.

**Task:**

- pull the [client repository](https://github.com/stxr-prop/client);
- add StaticMktInfoRepo;
- expose a small TypeScript API that includes presentation information; and
- build the crate as WebAssembly.

Related existing issue references:

- ENG-1318
- ENG-1600
- ENG-1624

### Structure Demo: CME Markets

#### Designed

##### Design CME futures and asset-class groupings

**Component:** CME Domain Model

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Missing. The source title, “Design the new market types,” is
ambiguous because Interest Rates, Commodities, and Equities are presentation
groupings rather than market types.

**Context:** Structure currently models spot and perpetual markets. CME
requires a futures market type and enough contract information to calculate
quantity, notional value, and PnL correctly.

**Task:** Design the minimum futures model for the demo, including contract
identity, expiry, multiplier, tick size, settlement asset, and asset-class
grouping for Interest Rates, Commodities, and Equities.

##### Finish the Databento market-data server design for the demo

**Component:** Databento Market Data Server

**Proposed:** Design; 2 points; Cheerful Capuchin

**Verdict:** Do not start from scratch. DEC-08T3R already designs the live
dbn-md-server, and ENG-1488 tracks the prototype in another project. The
consumer contract and historical replay are still undecided.

**Context:** Paper deployments need CME market data. The existing
[Databento prototype](https://github.com/stxr-prop/prototypes/tree/main/databento-md)
can decode market data and definitions. The remaining design must explain how
the demo consumer and historical replayer read the published data.

**Task:** Reconcile the existing live-server design with the demo path. Decide
whether consumers decode provider-native DBN records or receive normalized
Structure messages, and define the bridge into paper deployment and historical
replay.

##### Design the historical market-data download job

**Component:** Historical Market Data

**Proposed:** Design; 2 points; Cheerful Capuchin

**Verdict:** Missing. DEC-08T3R explicitly leaves historical replay and backfill
undecided.

**Context:** Download the last three months of data for the selected CME
futures. The output must preserve the definitions and ordering information that
the backtest historical-data replayer needs.

**Task:** Define the symbols and dated contracts, schemas, definition cut,
storage format, ordering data, validation, and handoff to the historical-data
replayer.

#### Ready for Integration

##### Add CME Group venues

**Component:** CME Domain Model

**Proposed:** 1 point; Cheerful Capuchin

**Verdict:** Missing. The narrow enum change may fit one point, but it does not
by itself make the platform CME-capable.

Keep the supplied venue context unchanged. The task should say:

> Add Cme, Cbot, Nymex, and Comex to the Rust and TypeScript venue models.
> Append stable numeric values; do not insert or renumber existing values.
> Resolve GLBX.MDP3 instruments from the definition record's exchange MIC, not
> from GLBX, publisher_id, or the symbol alone.

When this issue is created, add the complete contents of
brainstorm/reports/demo/venue-blast-radius.md as a comment. That report shows
the required codec, schema, conversion, exhaustive-match, and runtime follow-up
work.

##### Add the ten selected highest-volume CME futures

**Component:** CME Domain Model

**Proposed:** 1 point; Cheerful Capuchin; blocked by the futures model

**Verdict:** Missing and blocked by a product-scope decision.

The current list contains two option products: options on Three-Month SOFR
futures and options on 10-Year T-Note futures. Select two replacement futures
or explicitly reduce the scope to eight futures before creating this issue.

### Structure Demo: Strategy Variables

#### Ready for Integration

**Component:** Strategy Variables

Existing issue reference:

- ENG-1685

Do not create a duplicate. The Application Server must accept and validate
variable bindings when creating both a backtest and a strategy deployment. The
review covers [structure-web PR #152](https://github.com/stxr-prop/structure-web/pull/152)
and the linked client and messaging changes as one contract change.

### Structure Demo: Backtest

#### Designed

##### Backtest feed

**Component:** Backtest Feed

Existing issue references:

- ENG-1291
- ENG-1544

Do not create another general feed-design issue. ENG-1544 owns the reconciled
demo contract. The feed contains triggering source events, target positions,
fills, sampled prices, logs, metrics, and position reconciliation messages.

The price sampler emits prices when a fill happens, when the latest emitted
price is older than X milliseconds, or when volatility reaches the configured
threshold. This resolves the previous conflict with the DEC-07Z4J behavior in
which a fill did not trigger a price batch.

Consumers compute positions from fills. Position reconciliation messages are
drop-copy snapshots used only to reconcile the consumer's computed state. The
backtest does not calculate cost basis; consumers derive cost basis, volume,
PnL, portfolio value, return, and other accounting results from the feed.

##### Design the Rust post-processor ingress producer

**Component:** Backtest Post-Processor

**Proposed:** Design; 1 point; Cheerful Capuchin; blocked by the feed
reconciliation

**Verdict:** Missing. ENG-1309 covered a Python post-processor and is canceled.

**Context:** Make the Rust backtest post-processor read the ordered backtest
feed from its JSONL artifact and report malformed, incomplete, or out-of-order
input explicitly.

##### Backtest DuckDB schema

**Component:** Backtest Post-Processor

Existing issue reference:

- ENG-1642

Do not create a duplicate. Reconcile ownership, estimate, and whether the
experimental UI work remains part of that issue.

##### Backtest Performance View

**Component:** Backtest Performance View

Existing issue reference:

- ENG-1310

Do not create another general UI-design issue. The remaining view must read
positions, trades, logs, prices, target positions, PnL, volume, and return from
DuckDB.

#### Ready for Integration

##### Backtest simulator feed output

**Component:** Backtest Simulator

Existing issue references:

- ENG-1382
- ENG-1327

Do not create a duplicate simulator-design issue.

ENG-1327 and ENG-1382 emit the feed facts and sampled prices. They do not
calculate positions, cost basis, or other consumer-side accounting results.

##### Backtest Performance View implementation and accounting

**Component:** Backtest Performance View

Existing issue references:

- ENG-1653
- ENG-1659

ENG-1653 covers the existing chart and position UI. ENG-1659 consumes the feed
to derive volume, slippage, cost basis, PnL, portfolio value, return, and later
accounting results.

### Structure Demo: Strategy Deployment

#### Designed

##### Strategy Deployment feed and performance scope

Existing issue reference:

- ENG-1618

Treat this as the existing umbrella. Create a separate design issue only if
ENG-1618 is intended to remain an umbrella rather than own the design.

##### Reconcile the events emitted by the strategy component

**Component:** Strategy Component

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Partly covered. ENG-1485 owns target-position emission, while
triggering source events and their provenance still need to be reconciled with
DEC-09S6G.

**Context:** The strategy component must emit target positions, triggering
source events, and logs with enough shared identity to explain why a deployment
traded.

##### Design the events emitted by Sim GW

**Component:** Sim GW

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Missing as a focused issue.

**Context:** Sim GW must emit fills, position updates without cost basis, and
deposits or withdrawals. The events must carry the identity and ordering needed
by Event GW to derive deployment performance.

##### Design the Event GW accounting module

**Component:** Event GW

**Proposed:** Design; 1 point; Cheerful Capuchin

**Verdict:** Missing as a deployment issue. ENG-1659 covers related backtest
accounting but not this live Event GW path.

**Context:** For every fill, store the source event and derive the position,
realized PnL, and trading volume in base and quote units. Store triggering
source events, target positions, fills, position updates, logs, volume, and
realized PnL so the deployment can be replayed and explained.

##### Strategy Deployment Performance View

**Component:** Strategy Deployment Performance View

**Proposed:** Design; 4 points; Cheerful Capuchin

**Verdict:** Covered at the milestone level by ENG-1618. Create a separate
design issue only if that issue is intended to remain an umbrella.

**Context:** Show deployment performance over selectable time windows. Use live
prices to maintain the current one-minute candle, load historical candles for
the visible period, poll recent ClickHouse data, and calculate unrealized PnL,
portfolio value, return, volume, and rolling metrics such as Sharpe. For the
demo, settlement assets are treated as 1:1 with USD.

The view shows the position and trade fields defined in the source document. It
depends on ENG-1586, the deployment-feed tasks above, ENG-1659, and ENG-1634.

#### Ready for Integration

Existing issue references:

- ENG-1485
- ENG-1600

#### Integrated

Existing issue reference:

- ENG-1586

This issue is required for deployment-specific allocation and performance.

### Structure Demo: Portfolio Value

#### Ready for Integration

**Component:** Portfolio Value Sidebar

Existing issue reference:

- ENG-1603

The static UI already exists. Do not create another general sidebar-design
issue.

#### Integrated

**Component:** Portfolio Value Sidebar

Existing issue references:

- ENG-1318
- ENG-1634

Show total portfolio value and capital allocated to each deployment. Replace the
static values with the bounded historical and live state described by DEC-099MV
and NOTE-097X4. Deployment allocation also depends on ENG-1586.

### Structure Demo: Client App

#### Ready for Integration

##### Implement demo-client authentication

**Component:** Demo Authentication

**Proposed:** 1 point; Malicious Marmoset

**Verdict:** Missing. It appears only as a comment on ENG-1620.

**Context:** For the internal demo only, bundle a dedicated demo Solana keypair
and automatically authenticate the same demo user at startup. Keep this path
isolated from production authentication and never use a production key.

Related existing issue reference:

- ENG-1620

### Structure Demo: Group Library

#### Designed

##### Design the node-group library

**Component:** Node Group Library

Existing issue reference:

- ENG-1486

##### Design the custom-function library

**Component:** Custom Function Library

Existing issue reference:

- ENG-170

##### Design the node-group library UI

**Component:** Node Group Library

**Proposed:** Design; Grumpy Gorilla

**Verdict:** Missing.

**Context:** Design the node-group portion of the Group Library UI.

##### Design the custom-function library UI

**Component:** Custom Function Library

**Proposed:** Design; Grumpy Gorilla

**Verdict:** Missing.

**Context:** Design the custom-function portion of the Group Library UI.
Account for the accepted demo limitation that custom functions can be defined
but cannot execute in strategies.

#### Ready for Integration

##### Implement the node-group library

**Component:** Node Group Library

Existing issue reference:

- ENG-1622

##### Implement the custom-function library

**Component:** Custom Function Library

Existing issue reference:

- ENG-1623

#### Integrated

##### Embed node groups into the Strategy Builder

**Component:** Node Group Library

**Verdict:** Missing as a separate integration issue.

##### Embed custom functions into the Strategy Builder

**Component:** Custom Function Library

**Verdict:** Missing as a separate integration issue.

#### Founder Approved

##### Test the node-group library

**Component:** Node Group Library

**Verdict:** Missing.

##### Test the custom-function library

**Component:** Custom Function Library

**Verdict:** Missing.

##### Verify the node-group library with the founders

**Component:** Node Group Library

**Verdict:** Missing.

##### Verify the custom-function library with the founders

**Component:** Custom Function Library

**Verdict:** Missing.

Existing related issue references:

- ENG-1622
- ENG-1486
- ENG-1623
- ENG-170

## Decisions required before changing Linear

1. Select the final ten CME futures or approve an eight-future scope.
2. Choose historical replay or a genuine live Databento claim for the demo.
3. Resolve the provider-native DBN versus normalized Structure consumer
   contract.
4. Confirm which umbrella issues remain umbrellas and which own the detailed
   design.

## Reconciliation notes

- Creating every task from the source document as a new issue would introduce
  duplicates. Existing demo-project work is referenced only by its ENG
  identifier in the project and milestone where it contributes.
- ENG-1309 is not carried forward because it covered a canceled Python
  post-processor rather than the proposed Rust ingress producer.
- The Databento server and download job are not sufficient until the paper
  deployment and backtest consumers can read the chosen message contract.
- Adding venue values and asset-class labels is not sufficient without futures
  contract identity, expiry, multiplier, tick size, and settlement semantics.
