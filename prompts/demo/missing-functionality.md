Venues: Hyperliquid, CME

## Market Info

### Client
Load as a rust wasm module based on the static mkt info on the client. No need to query the data from the API

### Types

#### 1.
Introduce the following markets:
- Interest Rates
- Commodities (metal, energy, agriculture)
- Equities

#### 2.
Introduce a new venue: CME
Q: Venue for CME group or for every subsidiary?
A: Every subsidiary

Add the "Structure" as the nil/default variant instead of Drift

### Data
Take only the 10 highest-volume future markets from CME:
- Three-Month SOFR Futures (SR3)
- Micro E-mini Nasdaq-100 Futures (MNQ)
- 10-Year T-Note Futures (ZN)
- Options on Three-Month SOFR Futures
- 5-Year T-Note Futures (ZF)
- E-mini S&P 500 Futures (ES)
- 2-Year T-Note Futures (ZT)
- Micro E-mini S&P 500 Futures (MES)
- Crude Oil Futures (CL)
- 10-Year T-Note Options (OZN)
Remove shitcoins from hyperliquid

Keep the market list small for the demo (only in the presentation layer)

## Market Data

### Data Bento Mkt Data Server
Q: do we convert to a particular shape of a message or can the consumer figure out the decoding by itself?

### Download the historical mkt data
Q: Do we need the data bento hist data?
A: Yes, for the last 3 months


## Update the application server to handle the strategy variables
1. Strategy Deployment
2. Backtest

Just take it as a separate object + validate on creation

## Platform API
Expose the demo platform capabilities used by the AI agent: workspace pane management, filesystem and network mediation, entity access, and Strategy Spec construction.

## Backtest Feed
We need fills, target positions, logs, triggering source events, prices.
The backtest post-processor can compute the positions, realized pnl, unrealized pnl, volume, return based on all of these.
Ideally, we should use the rust backtest post-processor to reduce the number of changes + have correct metrics.

There should be a sampler for the price updates, which based on some events, like
- fill
- timer
- volatility threshold
will publish the price update to the feed

## Historical Data Replayer
Q: Can we use timestamp instead of the sequence number for the events?

Q: How can we integrate databento into the feed?

## Backtest post-processor
1. Fix the ingress producer to read the backtest feed from the file
2. Design the duck db schema for the backtest visualization

Take in the fills, derive positions and realized pnl, based on positions and prices derive the unrealized pnl.
Derive the volume, return.

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

## Strategy Deployment Feed

### Strategy component
- Target Positions
- Triggering Source Events
- Logs

### Sim Gw Component
- Fills
- Position Updates

### Event Gw
on every fill, we write the fill, derive the position, realized pnl, volume

#### Compute
1. trading volume based on the fills in base, quote units
2. positions based on fills
3. realized pnl

#### Storage
- triggering source events
- target positions
- fills
- position updates
- logs
- volume
- realized pnl


## Deployment Strategy Performance View
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
- pnl (realized + unrealized breakdown) over the time window (last day, last 24 hrs, last 7 days, last 30 days)
- volume (base, quote, valuation units) over the time window (last day, last 24 hrs, last 7 days, last 30 days)
- return (percentage and absolute) over the time window (last day, last 24 hrs, last 7 days, last 30 days)

For the trades:
- time
- type: (spot/perp/future)
- symbol
- side (buy/sell/sell short)
- qty
- price (market's quote unit)
- liquidity role (taker/maker)
- avg price


## Portfolio Value Sidebar
knowledge-base/docs/decisions/records/DEC-099MV-client-historical-price-caching-for-portfolio-views.md
knowledge-base/docs/notes/records/NOTE-097X4-strategy-performance-view-prototype.md

## Group Library
Just use a filesystem with some kind of "structure" directory, which we could share.
Have per-user directory where we'll save the groups and the custom fns

## Auth
Embed the public and private keypair into the application. Maybe have one per demo user and automatically sign in using it

## Tick Navigator
Just enable all the logs for all the nodes.
It must be run on the actual data, we just need to find an interesting combination of the data and strategy to show the "bad trade" or something like that
