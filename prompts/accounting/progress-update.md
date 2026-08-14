---
skill: Linear Progress Management
linear_project: strategy-performance-accounting-ed0369fde5bc
assignee: cheerful capuchin
cycle: 8faa4e08-0c35-4b56-8dfa-213d499da9fc (cycle 44)
---

I'm working with the prototypes to make the accounting work.

I want to create a couple of milestones/vertical slices in the linear project to have a full PoC.

I'll describe the milestones and the descriptions. When it comes to issues, I'll explicitly tell you when to create a new issue.
The issues must only include my description. You may need to reword it or provide more context, but that's it.
I don't want custom labels, estimates, deliverables, etc. Just simple, very concise text, so I or my colleague can understand it quickly.

Milestones:

## Fills
We need to simulate the hyperliquid data feed that includes the fills.
Then store that feed in some flat file
After, have a program that loads the feed into the EventHeap (min heap) ordered by timestamp
The program is a simplified version of an engine

```
loop {
    // Execute all the effects scheduled in the previous tick
    for egress in egress.drain() {
        await egress_manager.execute();
    }
    let ingress_msg = event_heap.pop()?;  // earliest ingress message (min-heap)
    time_provider.advance(ingress_msg.observed_time);
    ctx = EngineContext {
        tp: time_provider,
        egress_ch,
    }
    component_host.handle_ingress(&ctx, &ingress_msg)?;        // process and schedule the next effects
}
```

We explicitly use the tick approach as it's very simple to reason about and replay.
The egress consumers may send ingress messages themselves, e.g., timers, db writes, etc.
Therefore, we need to push those ingress messages to the Event Heap to sort them chronologically
The time provider's time is then based on the observation time of the message. I think that should be some kind of rust trait.

Inside the business logic, we'll just buffer the fills, issue a duck db database write msg and that's it.

For the visualization, I think the simplest table would work, we just load up the data from the database,
convert it to some kind of feed, send to the client engine, the client does whatever it needs:
- conversion
- fetch prices

We should be able to navigate the history and see all the trades that happened up until the chosen observation time and their nominal value
in the valuation assset that could be changed on the client.

### Tasks

#### Download the Quotes Mkt Data from Coin API
status: done, cycle: 44, estimate: 2 points

Download the quote data from the Coin API, so we can simulate the fills.
Create a command that takes a time period, interval (1min default) and out dir.
Download the data
Write to a flat file (parquet)

prototypes/accounting/bin/incoming_feed.rs

#### Simulate the fills
status: done, cycle: 44, estimate: 2 points

Create a deterministic strategy and target executor that always fills the order requests.

prototypes/accounting/bin/incoming_feed.rs

TODO(ai): you can explain the strategy chosen in the implementation. How we choose accounts, markets, position sizes, fees, quotes, orderand

#### Create the replay engine
status: in progress, cycle: 44, estimate: 2 points

```
loop {
    // Execute all the effects scheduled in the previous tick
    for egress in egress.drain() {
        await egress_manager.execute();
    }
    let ingress_msg = event_heap.pop()?;  // earliest ingress message (min-heap)
    time_provider.advance(ingress_msg.observed_time);
    ctx = EngineContext {
        tp: time_provider,
        egress_ch,
    }
    component_host.handle_ingress(&ctx, &ingress_msg)?;        // process and schedule the next effects
}
```
Create an event heap, load the data in there, do the tick-based execution.
We don't need our production engine, just the concept
For now, there are no egress consumers, so the egress manager just does nothing and ideally the program should run though events in a couple of milliseconds
the egress manager should be awaited

#### Create the database egress consumer
status: todo, cycle: 44, estimate: 2 point

Can implement the same egress consumer traits. Has to be able to write to the duck db
Hook up to the egress manager

#### Create the "logic" module that writes the fills
status: todo, cycle: 44, estimate: 2 point

take in the event, buffer it, when the threshold (size) is reached, flush to the egress.

#### Create the GUI
status: todo, cycle: 44, estimate: 2 point

First, just load the data from the db and show in the table.
Then, load up the prices and show the fills with the valuation asset prices
Ideally, have 2 valuation assets: USD and EUR

Avoid for all cost: designing the routing in the client engine. Maybe forget about the engine at all.
The goal is to focus on the accounting first


## Volume

Calculate the volume, every hour store volume and position checkpoints in the database.
There is no pnl calculation yet, no fees, no cost basis. We simply make checkpoints and then show them in the UI.

The volume should be shown in the base, quote, valuation assets.
We should show the __window total__ quantity, NOT since the inception.

## Unrealized Pnl

Now we have to store the position cost basis using different cost basis books for different quote units.
The user should be able to see the unrealized pnl of their position at any time

## Realized Sell

Now we have to do the ledgers, postings, economic accounts and book the activity.
The https://docs.tigerbeetle.com/coding/recipes/currency-exchange/ may help.

Something like this
```rust
pub struct LedgerId(u32);
pub struct EconomicAccountId(u128); // id = hash(trading_account_id, subject_kind, subject_id, ledger, code)
pub struct TradingAccountId(u64);

enum Subject {
    Asset,
    Contract
}

#[repr(u16)]
pub enum EconomicActivityCode {
    TradingFeeMaker = 300,
    TradingFeeTaker = 301,
    OpeningFee = 302,
    ClosingFee = 303,
}

#[repr(u16)]
pub enum EconomicAccountKind {
    Cash = 1, // ?
    TradingFeeMaker = 300,
    TradingFeeTaker = 301,
}

// based on the accounts and the ledger I know which valuation prices to load
pub struct EconomicAccount {
    pub id: EconomicAccountId,
    pub trading_account_id: TradingAccountId,
    pub subject_kind: Subject,
    pub subject_id: u64,
    pub ledger: LedgerId,
    // Kind of activity that the account stores
    pub code: EconomicAccountKind,
}

pub struct Ledger {
    pub id: LedgerId,
    pub asset_id: u64,
    pub scale: u8
}

pub struct Posting {
    // ULID
    pub id: u128,
    pub debit_account_id: EconomicAccountId,
    pub credit_account_id: EconomicAccountId,
    pub amount: u128,
    pub ledger: LedgerId,
    // reference to the event that caused this posting. Based on the combination of code and event_id, you can easily find the right one
    pub event_id: u128,
    // reason for (or category of) the transfer
    pub code: EconomicActivityCode,

    pub timestamp: u64,
}

// hourly checkpoint
pub struct EconomicAccountBalance {
    pub id: EconomicAccountId,

    pub debits: u128,
    pub credits: u128,
}
```

Now, in the UI, the positions table shows:
- qty
- price
- pnl breakdown into total, realized, unrealized (over the focused window)
- volume in base, quote, valuation asset (over the focused window)
- return percentage and absolute (over the focused window)


## Fees

The incoming data feed should now include the fees
The pnl calculation must adjust for the fees

## Tracing

We should include the whole tracing information starting from the source event finishing with a position.
The user should understand why a position was updated:
- source event
- target position
- order request
- order update
- fill + related economic events (fees)
- position update
- economic events (funding)


