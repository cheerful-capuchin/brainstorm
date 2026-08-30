Parent Linear ticket: [ENG-1942: Implement the sim venue feed](https://linear.app/stxr/issue/ENG-1942).
Decision document: knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md
Simulation venue code: ./sim-gw/src
Messaging contracts: messaging/msg-schemas/proto/sim-venue

What is necessary in order to implement the desired feed for the simulation venue?
There are no protobuf messages and no traits created so far, and I don't yet know the exact place where that would be.
Therefore, keep it on the todo, but don't assume implementation.
I want an exhaustive list of what's needed in brainstorm/reports/sim-venue/feed-impl-requirements.md

I think the deposits and withdrawals were planned, but you have to check the knowledge base for that.
We do NOT calculate any cost basis in the venue.
When you make an assumption, you have to be explicit about it. Your assumptions must be a checklist, which I can toggle off
if I don't agree with them.



---
## data-feed-core
- FeedId, FeedRevisionId, shape IDs
- definition model primitives
- generic event/message/field types
- EncodingKind
- base consumer, producer, view, encoder, and decoder traits
- no concrete feeds or encoding libraries
- no_std, no I/O

## data-feed-definitions
- concrete event families and message definitions
- semantic traits such as TradePrintView
- canonical shape traits
- actual feed definitions
- generated static metadata
- depends only on data-feed-core
- no_std, no I/O
  This becomes the authoritative compiled feed-definition library.

## feed-info
- feed discovery use cases
- filtering, selection, pagination, and revision lookup
- FeedDefinitionRepository application port
- independent of gRPC, databases, and encoding implementations
- depends on data-feed-core
- may depend on data-feed-definitions for a bundled static catalog

## data-feed-codegen
- host-side generator
- reads and validates definitions
- canonicalizes shapes
- compatibility checks
- generates schemas, Rust types, traits, and codec implementations
- may use std and filesystem I/O
- never linked into target applications

## feed-info-server
- gRPC/HTTP/Zenoh transport
- server runtime
- authentication and telemetry
- configuration
- depends on feed-info
Maybe the codec will be sent as a dynamic rust module (WASM)?

## data-feed-codec-{encoding}-{content-schema-id}
- generated concrete message types
- generated encoders and decoders
- implementations of traits from data-feed-core
- implementations of semantic traits from data-feed-definitions
- no transport or filesystem I/O


## Repositories:

### data-feed-core
crates:
- "data-feed-core"
- "data-feed-codegen"

### data-feed-definitions
crates:
- data-feed-definitions
- data-feed-codec-*-*

### feed-info
crates:
- feed-info
- feed-info-server




----
In order to satisfy the strategy deployment feed (knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md)
we need to emit the data from the simulated venue. Simulated venue only handles a particular scope of the strategy topology.
In particular, its responsibilities are:
- Fills
- Fees
- Deposits
- Accounts' positions

The current limitations of the feed:
- there is no clear provenance
- sim venue orderand is assumed to be a (timestamp in a second resolution (since JAN 2026) << 31) | (sequence number & 2^32)
- the deposit cost basis is not fully defined
- fees are demo-only, there is no established pattern yet

Create the "simulation-venue-feed" decision record.
The overview and description should be in plain technical English.
You need to copy the entire Rust snippet.
Do not describe types using plain words - the snippet carries everything needed.


```rust
pub struct DictionaryRef(u16);

/// Type-safe references prevent target-position fields from accidentally using
/// an entry from the wrong dictionary.
pub struct AssetRef(DictionaryRef);
pub struct ContractRef(DictionaryRef);
pub struct AccountRef(DictionaryRef);

trait HasIdentity {
    type Id;

    /// Unique identifier of the event
    fn event_id(&self) -> Self::Id;
}

trait HasTracing {
    type Id;

    /// Trace that could be connected with a larger sequence of the events.
    /// For instance, additional observability information may be emitted.
    fn trace_id(&self) -> Self::Id;
}

trait HasFeedOrderand {
    type Orderand;

    fn feed_orderand(&self) -> Self::Orderand;
}

/// What caused the event.
trait HasProvenance {
    type Item;

    fn provenance(&self) -> Self::Item;
}

pub struct SimGwOrderand(u64);

pub trait Fill:
HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
+ HasFeedOrderand<Orderand = SimGwOrderand>
{
    /// When the event happened on the venue.
    fn event_time(&self) -> NanoTimestamp;
    /// When our infra received the event.
    fn send_time(&self) -> NanoTimestamp;

    /// Points to the __market__ where the fill occurred.
    fn instrument_id(&self) -> InstrumentId;
    /// Which trading account was used.
    fn trading_account_id(&self) -> TradingAccountId;

    /// In market's quote unit.
    fn price(&self) -> numerics::Price;
    /// Unsigned.
    fn quantity(&self) -> numerics::Qty;
    /// [REF:trade] Trade
    fn side(&self) -> TradeSide;
    /// Maker vs. Taker.
    fn liquidity_role(&self) -> LiquidityRole;
}

/// Records an update in the trading account positions.
/// This is the venue's drop-copy view; the consumer may use it for
/// reconciliation but derives positions from raw fills.
/// Cadence: `EventDriven`;
trait TradingAccountPositionsUpdate:
HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
+ HasFeedOrderand<Orderand=SimGwOrderand>
{
    /// When the event happened on the venue simulator.
    fn event_time(&self) -> NanoTimestamp;
    /// When our infra received the update.
    fn send_time(&self) -> NanoTimestamp;

    /// What the position set contains, and therefore what absence means.
    fn coverage(&self) -> PositionSetCoverage;
    /// How to interpret each position's numbers.
    fn amount_semantics(&self) -> PositionAmountSemantics;

    // -- Dictionaries --
    // Declare all the identifies beforehand, which reduces the payload
    // and improves the routing, since the consumer just need to check the top-level identifiers
    fn account_ids(&self) -> impl Iterator<Item=TradingAccountId>;
    fn contract_ids(&self) -> impl Iterator<Item=ContractId>;
    fn asset_ids(&self) -> impl Iterator<Item=AssetId>;

    fn derivative_positions(&self) -> impl Iterator<Item=DerivativePosition>;
    fn spot_positions(&self) -> impl Iterator<Item=SpotPosition>;
}

pub trait DerivativePosition {
    fn account_ref(&self) -> AccountRef;
    fn contract_ref(&self) -> ContractRef;
    fn quantity(&self) -> numerics::Qty;
}

pub trait SpotPosition {
    fn account_ref(&self) -> AccountRef;
    fn asset_ref(&self) -> AssetRef;
    fn quantity(&self) -> numerics::Qty;
}

/// Accounting information declared by the source of a deposit.
///
/// This is a closed set. `NotApplicable` is currently the only supported
/// variant because initialization deposits must use the valuation asset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeclaredCostBasis {
    NotApplicable,

    // --- Other Options -> Not for the demo ---

    /// Total acquisition cost of the deposited quantity.
    // Declared {
    //     amount: Decimal,
    //     asset_ref: AssetRef,
    // },

    /// Reset performance at the deposit's effective time.
    // OpeningMark {
    //     price: Decimal,
    //     quote_asset_ref: AssetRef,
    // },
}

/// Records capital entering a simulated trading account.
///
/// A deposit is a raw economic event. It changes the account balance but does
/// not create PnL or trading volume.
pub trait Deposit:
HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
+ HasFeedOrderand<Orderand = SimGwOrderand>
{
    /// Simulated time when the deposit becomes effective in the account.
    fn event_time(&self) -> NanoTimestamp;

    /// Account receiving the capital.
    fn trading_account_id(&self) -> TradingAccountId;

    /// Asset entering the account.
    fn asset_id(&self) -> AssetId;

    /// Unsigned quantity entering the account. Must be greater than zero.
    fn quantity(&self) -> numerics::Qty;

    /// Declared accounting treatment of the deposited asset.
    fn declared_cost_basis(&self) -> DeclaredCostBasis;
}

/// Records capital leaving a simulated trading account.
///
/// A withdrawal is a raw economic event. It changes the account balance but does
/// not create PnL or trading volume.
pub trait Withdrawal:
HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
+ HasFeedOrderand<Orderand = SimGwOrderand>
{
    /// Simulated time when the withdrawal becomes effective in the account.
    fn event_time(&self) -> NanoTimestamp;
    fn send_time(&self) -> NanoTimestamp;

    fn trading_account_id(&self) -> TradingAccountId;
    fn asset_id(&self) -> AssetId;

    /// Unsigned quantity leaving the account. Must be greater than zero.
    fn quantity(&self) -> numerics::Qty;
}


/// Records a fee charged against a simulated trading account.
///
/// This is intentionally named `DemoOnlyFee` to signal that this is a
/// demo-scoped shape, not the final data model. The fee is a raw economic
/// event. It changes the account balance and influences realized PnL, but
/// the fee event itself is just the raw fact. The consumer derives the actual
/// PnL impact from the fee along with fills and other events.
pub trait DemoOnlyFee:
HasIdentity<Id = telemetry::EventId>
+ HasTracing<Id = telemetry::TraceId>
+ HasFeedOrderand<Orderand = SimGwOrderand>
{
    /// Simulated time when the fee becomes effective in the account.
    fn event_time(&self) -> NanoTimestamp;
    /// When the infra received the event.
    fn send_time(&self) -> NanoTimestamp;

    /// Account receiving the capital.
    fn trading_account_id(&self) -> TradingAccountId;

    fn instrument_id(&self) -> InstrumentId;

    fn fee(&self) -> numerics::Qty;
}
```
