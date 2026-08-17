brainstorm/prompts/demo/missing-functionality.md

I want to understand what's missing from the Linear project https://linear.app/stxr/project/structure-v00-demo-app-f783a56b24eb
Do NOT change anything there, let's reconcile locally first.

I'll go through the milestones and tasks in those milestones that we need to get done.
The context and the description must be in a very simple language.
The audience is the people with the tech background, they generally understand
what the product is, but they are not aware about much details.
Also, try keeping it succinct so it doesn't take ages to read.

Context can be found in the https://linear.app/stxr/project/structure-v00-demo-app-f783a56b24eb/activity#project-update-ac5949ff
and ./knowledge-base

You should not change my explanations except improving the wording for it to sound more natural
and adding slightly more context, so the reader can understand the milestone/task better.

## Market Info
We need to embed the market info on the client, since it removes the need to fetch it and design the contracts

### Create a client core rust wasm module and put the StaticMktInfoRepo there
cost: 2 points, assignee: nilgiri

- create a github repo
- create a rust crate
- design the API to get the market info to typescript with the Presentation Information
- build as WASM

>>>---

## CME Markets
Add CME venues and new market types to the domain model.
Markets:
- Interest Rates
- Commodities (metal, energy, agriculture)
- Equities

Tasks:
### Add CME Group Venues
cost: 1 point; assignee: capuchin

#### Context (do not modify)
CME Group is the world’s leading derivatives marketplace, made up of four exchanges, CME, CBOT, NYMEX and COMEX. Each exchange offers a wide range of global benchmarks across all major asset classes.
The CME Group venues available through Databento’s `GLBX.MDP3` dataset are:
- `Cme` — Chicago Mercantile Exchange
- `Cbot` — Chicago Board of Trade
- `Nymex` — New York Mercantile Exchange
- `Comex` — Commodity Exchange

`GLBX` is Databento’s aggregate venue/feed identifier, not a separate execution venue. Therefore, I’d add the four exchanges above to [venue.rs](market-info-core/rust/src/entities/venue.rs), not `Glbx`.

Confirmed by [Databento](https://databento.com/docs/venues-and-datasets/glbx-mdp3) and [CME Group](https://www.cmegroup.com/company/cme.html). No files were modified.

CME Group has two useful venue scopes:

- Listed-derivatives exchanges: exactly `CME`, `CBOT`, `NYMEX`, and `COMEX`.
- Other CME Group trading businesses: `BrokerTec` for cash fixed income and `EBS` for cash FX, NDFs, and metals. These have more specific platforms such as BrokerTec CLOB/Quote and EBS Market/Direct.

For the current `GLBX.MDP3` integration, only the four exchanges belong in scope. BrokerTec and EBS are not part of that Databento dataset. Also, Globex is the shared matching/feed infrastructure—not another legal exchange. [CME Group](https://www.cmegroup.com/company/cme.html) identifies its four exchanges, while its current corporate reporting describes BrokerTec and EBS as its cash-market businesses.

__Resolving `GLBX` to an exchange__

You cannot determine the exchange from `GLBX` or `publisher_id` alone. `GLBX` identifies the combined CME Globex publisher/feed.

Resolve it per instrument:

1. Read `instrument_id` from the market-data record.
2. Obtain the corresponding Databento `definition` record.
3. Read `InstrumentDefMsg.exchange`.
4. Map the exchange MIC:

| Definition `exchange` | Venue |
|---|---|
| `XCME` | CME |
| `XCBT` | CBOT |
| `XNYM` | NYMEX |
| `XCEC` | COMEX |

These are CME’s [official exchange abbreviations](https://www.cmegroup.com/datamine/datamine-list-api.html). Databento’s definitions are point-in-time reference data, so retain and update an `instrument_id → venue` mapping rather than deriving the venue from the symbol.

The existing prototype already extracts `exchange` from `InstrumentDefMsg` alongside `publisher_id` and `instrument_id`: [dbn_definition.rs](prototypes/databento-md/src/infrastructure/dbn_definition.rs:77).

#### Task
Update the `Venue` enums in both rust and typescript domain models.

TODO(ai): attach the content of the file (brainstorm/reports/demo/venue-blast-radius.md) as a comment



### Design the new market types
label: design, cost: 1 point, assignee: capuchin

https://www.cmegroup.com/markets/products#sortField=vol&sortDirection=desc
Introduce the following markets:
- Interest Rates
- Commodities (metal, energy, agriculture)
- Equities

### Design Data Bento Mkt Data Server
label: design, cost: 2 point, assignee: capuchin

We want to be able to run the paper deployment on the live CME data.
Consequently, we need to figure out what's needed to get it working.
There is already a prototype in the prototypes/databento-md (TODO(ai): put the github link. check github cli)

The shape of the message should be readable by the backtest historical data replayer

### Design the historical mkt data download job
label: design, cost: 2 points, assignee: capuchin

We need the historical mkt data for the 10 CME markets for the last 3 months.
The shape of the message should be readable by the backtest historical data replayer

### Add the top 10 highest-volume future markets from CME
cost: 1 point; assignee: capuchin; blocked by: Design the new market types
https://www.cmegroup.com/markets/products#sortField=vol&sortDirection=desc

>>>---

## Strategy Variables

### Review the Application Server API updates to facilitate the Strategy Variables
label: code review, cost: 1 point, assignee: capuchin
https://github.com/stxr-prop/structure-web/pull/152
https://linear.app/stxr/issue/ENG-1685

The application server must handle the strategy variables for both the strategy deployments and the backtest

>>>---

## Backtest

### Design the backtest feed for the demo app
label: design; assignee: capuchin; estimate: 2 points

We need fills, target positions, logs, triggering source events, prices.
The backtest post-processor can compute the positions, realized pnl, unrealized pnl, volume, return based on all of these.

There should be a sampler for the price updates, which based on some events, like
- fill
- timer
- volatility threshold
  will publish the price update to the feed

### Design the backtest post-processor ingress producer
label: design; assignee: capuchin; estimate: 1 point; blocked by: design the backtest feed

be able to parse the backtest feed from the JSON file

### Design the backtest post-processor duck db schema
label: design; assignee: capuchin; estimate: 2 points; blocked by: design the backtest feed

We already have some ideas in the knowledge base

### Design the backtest simulator to emit the backtest feed
label: design; assignee: capuchin; estimate: 2 points; blocked by: design the backtest feed;

>>>---

## Backtest Performance View
For positions, show the following:
- subject
- price
- target position
- current position
- cost basis
- pnl (realized + unrealized breakdown) since the inception
- volume (base, quote, valuation units) since the inception
- return (percentage and absolute) since the inception

For the trades:
- time
- type: (spot/perp/future)
- symbol
- side (buy/sell/sell short)
- qty
- price (market's quote unit)
- liquidity role (taker/maker)
- avg price

### Design the backtest performance view
label: design; assignee: capuchin; estimate: 1 point

There are already some ideas in the knowledge base.
Ideally, should be as simple as read everything from the duck db

>>>---

## Strategy Deployment Feed
We need data emitted by the component that are used in the strategy deployment, so we can show the performance

### Design the events emitted by the strategy component
label: design; assignee: capuchin; estimate: 1 point

- Target Positions
- Triggering Source Events
- Logs

Some of them are already in the prototypes/accounting/docs/feed.md

### Design the events emitted by the sim gw
label: design; assignee: capuchin; estimate: 1 point

- Fills
- Position Updates (no cost-basis)
- Deposits/Withdrawals

Some of them are already in the prototypes/accounting/docs/feed.md

### Design the event gw accounting module
label: design; assignee: capuchin; estimate: 1 point

Compute:
1. trading volume based on the fills in base, quote units
2. positions based on fills
3. realized pnl

Storage:
- triggering source events
- target positions
- fills
- position updates
- logs
- volume
- realized pnl

>>>---

## Strategy Deployment Performance View
For positions, show the following:
- subject
- price
- target position
- current position
- cost basis
- pnl (realized + unrealized breakdown) over the time window (last day, last 24 hrs, last 7 days, last 30 days, etc)
- volume (base, quote, valuation units) over the time window (last day, last 24 hrs, last 7 days, last 30 days, etc)
- return (percentage and absolute) over the time window (last day, last 24 hrs, last 7 days, last 30 days, etc)

For the trades:
- time
- type: (spot/perp/future)
- symbol
- side (buy/sell/sell short)
- qty
- price (market's quote unit)
- liquidity role (taker/maker)
- avg price


### Design the Strategy Deployment Performance View
label: design; assignee: capuchin; estimate: 4 points

- sub to the live price updates and build the 1-min candles
- query the historical candles with the specified interval for the displayed time period
- query the historical data from clickhouse
- query the "realtime" data from the clickhouse every X seconds
- compute the unrealized pnl, portfolio value, return, volume over the specified time windows using the prices
- compute the rolling metrics like the sharpe ratio
- when displaying volume -> quote_unit_qty * settlement_to_quote_unit. For now we assume all the settlement assets are 1:1 with USD

For positions, show the following:
- subject
- price
- target position
- current position
- cost basis
- pnl (realized + unrealized breakdown) over the time window (last day, last 24 hrs, last 7 days, last 30 days, etc)
- volume (base, quote, valuation units) over the time window (last day, last 24 hrs, last 7 days, last 30 days, etc)
- return (percentage and absolute) over the time window (last day, last 24 hrs, last 7 days, last 30 days, etc)

For the trades:
- time
- type: (spot/perp/future)
- symbol
- side (buy/sell/sell short)
- qty
- price (market's quote unit)
- liquidity role (taker/maker)
- avg price

>>>---

## Portfolio Value Sidebar
Show the portfolio value and the allocated capital per deployment

### Design the Portfolio Value Sidebar
label: design; assignee: capuchin; estimate: 2 points

knowledge-base/docs/decisions/records/DEC-099MV-client-historical-price-caching-for-portfolio-views.md
knowledge-base/docs/notes/records/NOTE-097X4-strategy-performance-view-prototype.md

>>>---

## Authentication

### Implement the auth for the demo client
assignee: marmoset; estimate: 1 point

just embed the solana keypair and always authenticate that user


>>>---

## Tick Navigator

### Design the UI
label: design; assignee: gorilla; estimate: 4 points

>>>---

## Group Library

### Design the UI
label: design; assignee: gorilla; estimate: 2 points






