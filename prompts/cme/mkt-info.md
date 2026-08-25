knowledge-base/docs/decisions/records/DEC-0AFBN-cme-futures-market-info.md
There is a problem with the approach we're taking when it comes to the `MarketInfoType`
market-info/src/market_info.rs:111
```rust
    pub trait MarketInfoType {
        type SpotType: SpotMarketTrait;
        type PerpType: PerpMarketTrait;

        fn as_spot(&self) -> Option<&Self::SpotType>;
        fn as_perp(&self) -> Option<&Self::PerpType>;

        /// Accepts closures and run the appropriate one based on the market type
        /// Reduces the branching logic the consumer has to write
        fn dispatch<FSpot, FPerp, R>(&self, fspot: FSpot, fperp: FPerp) -> R
        where
            FSpot: FnOnce(&Self::SpotType) -> R,
            FPerp: FnOnce(&Self::PerpType) -> R;
    }
```

The more markets we introduce, the more breaking changes we have to make.
Also, this structure doesn't account for the case when I know for a fact that my market info repo ONLY works with perpetual or ONLY with spot
or ONLY with futures, etc.
I've already had some ideas with the Visitor pattern knowledge-base/docs/decisions/records/DEC-0A5FN-backtest-feed-emits-raw-economic-events.md:345
```
pub enum MarketInfoKind<'a, S: SpotMarketInfoView, P: PerpMarketInfoView> {
    Spot(&'a S),
    Perp(&'a P),
}

pub trait MarketInfoTypeView {
    type Spot: SpotMarketInfoView;
    type Perp: PerpMarketInfoView;

    fn kind(&self) -> MarketInfoKind<'_, Self::Spot, Self::Perp>;
}

impl<T: MarketInfoTypeView> MarketInfoVisitable for T {
    fn dispatch<V: MarketInfoVisitor>(&self, v: V) -> V::Output {
        match self.kind() {
            MarketInfoKind::Spot(s) => v.spot(s),
            MarketInfoKind::Perp(p) => v.perp(p),
        }
    }
}

pub trait MarketInfoVisitor {
    type Output;

    fn spot<Mkt: SpotMarketInfoView>(self, mkt: &Mkt) -> Self::Output;
    fn perp<Mkt: PerpMarketInfoView>(self, mkt: &Mkt) -> Self::Output;
}
```
However, it's tomato tamato. Every time we introduce a new mkt type, we have to change this traits.
Ideally, I would like to stack 'em up, like with 'HasX' pattern and based on my usage I can specify what I expect the
market repo to contain.

For instance, say my business logic only works with the spot markets, I could enforce exclusivity
```rust
fn business_logic<Mkt>(mkt_repo: &Mkt)
where
    Mkt: MarketInfoRepo<SpotMarket>
{
    for mkt in mkt_repo.iter() {
        let x = mkt.spot().instrument_id();
    }
    // ...
}
```
I cannot call that function with the market info repo that stores spot and perp markets.

I could also have an option where I specify that my function cares only about the Spot markets and Futures, but the repo can store whatever.
```rust
fn business_logic<Mkt>(mkt_repo: &Mkt)
where
    Mkt: MarketInfoRepo<SpotMarket + FuturesMarket>
{
    mkt_repo.only(SpotMarket | FuturesMarket).visit(visitor);  // IDK, something that is generic, but can skip markets I don't care about
}
```
This is the knowledge-base/docs/guides/capability-based-design.md I like so much.

What are the ways to do that? For instance, I really don't want to do
```
for mkt in mkt_repo {
    if let Some() = mkt.is_spot() {
    }
}
```



---
I want you to create a decision document in the knowledge base "CME futures market info". Your writing should be based on the  brainstorm/reports/demo/cme/market-info.md

In the introduction you need to explain what CME group is and what venues are present and what are their responsibilties
- Cme — Chicago Mercantile Exchange
- Cbot — Chicago Board of Trade
- Nymex — New York Mercantile Exchange
- Comex — Commodity Exchange

Then I want you to give a brief explanation of what a future is and how it's beneficial to our platform

Next, I want you to explain what's needed in order to represent the Futures markets in our platform.
Specifically, what properties are we missing, what do they mean and why they are needed.

Next, I want you to put all the market info traits into the decision document with all the comments
and add the explanations from the brainstorm/reports/demo/cme/market-info.md as rustdoc on top of the types and trait members.

Code is the most token-efficient way to explain the information, so I prefer seeing more rust code with some comments than simple prose.

The "Deliberately excluded" section is a good one to have in the alternatives considered




---

I want to integrate the CME venue into our system.
The first thing we need to do is to create the necessary traits and types for the CME futures markets (no options for now).

We have the key traits in market-info/src/market_info.rs.
Currently, the only supported derivatives market is the `Perpetuals market`.
I assume that there is a `DerivativeMarketInfo` trait to be introduced and maybe some more traits and types.

I want to support the top-10 futures markets from CME group (sorted by volume)
Product,Symbol,Exchange,Asset class,Volume,Open interest
10-Year T-Note Futures,ZN,CBOT,Interest Rate,"8,265,306","6,222,696"
2-Year T-Note Futures,ZT,CBOT,Interest Rate,"7,834,472","4,667,952"
5-Year T-Note Futures,ZF,CBOT,Interest Rate,"7,458,934","7,039,336"
Ultra 10-Year T-Note Futures,TN,CBOT,Interest Rate,"4,346,880","2,981,608"
Three-Month SOFR Futures,SR3,CME,Interest Rate,"3,332,980","13,057,679"
Ultra T-Bond Futures,UB,CBOT,Interest Rate,"3,220,661","2,970,516"
U.S. Treasury Bond Futures,ZB,CBOT,Interest Rate,"2,482,116","2,084,145"
Micro E-mini Nasdaq-100,MNQ,CME,Equities,"2,166,497","204,619"
Corn Futures,ZC,CBOT,Agriculture,"784,265","1,707,609"
Crude Oil Futures,CL,NYMEX,Energy,"779,958","1,907,297"

How would you change the market info traits and types?
What are the new properties would you add?
How would you change the quote unit, settlement conditions, underlying?

For a second there, pretend that the `Venue` enum already has the necessary venues:
- Cme — Chicago Mercantile Exchange
- Cbot — Chicago Board of Trade
- Nymex — New York Mercantile Exchange
- Comex — Commodity Exchange


