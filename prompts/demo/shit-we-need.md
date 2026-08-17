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
in the presentation layer, we can use the grouping by an asset class, so the user can find the info easier.
Update the trait and add th issue that it may not be the best impl, it's just for the client for now
```rust
/// Display accessors for a market, kept separate from
/// [`MarketInfoTrait`] so the core market facts stay free of presentation
/// concerns.
pub trait MarketPresentationTrait {
    /// Returns a stable, human-readable name for the market.
    fn display_name(&self) -> &str;
}
```

#### 3.
Introduce a new venue: CME
Q: Venue for CME group or for every subsidiary?

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


## Update the application server to handle the strategy variables
1. Strategy Deployment
2. Backtest

Just take it as a separate object + validate on creation

## Platform API
Expose the demo platform capabilities used by the AI agent: workspace pane management, filesystem and network mediation, entity access, and Strategy Spec construction.

##
