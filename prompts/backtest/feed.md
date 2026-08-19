I need to update the backtest feed - knowledge-base/docs/specs/SPEC-backtest-feed.md and create a new decision document outlining
why I want to introduce the change. Do NOT change anything yet.

Context:
After working with the accounting module, I realized that I was mixing up the accounting concepts vs. the trading concepts.
Specifically, I mixed the cost basis, pnl and portfolio value calculation with the execution logic.
The backtest should not calculate those metrics, it's the job of the backtest post-processor.
The cost_basis of a position depends on many factors, like the accounting methodology, whether the fees are included, etc.
It becomes even more complex once we start dealing with multiple currencies.
For instance, the spot asset, like BTC, could be bought on many markets, using different quote assets.
The user may want to look at those trades, positions, pnl, etc., using different valuation assets like USD, EUR, GPB.
If we bring all of this into the backtest, it becomes very complex quickly.
Moreover, it doesn't even improve the job the backtest is intended for – simulating the strategy.

If we look at this problem fundamentally, a lot of the data are the derived values from the economic events.
It's very important to maintain the information about the fills, fees, orders, etc.
Everything else – positions, pnl, portfolio value, volume, etc. is derivable.
It suits the backtest even better, since it starts from 0. So, all the economic events that are emitted can be aggregated together
using different techniques and as long as we maintain the raw economic events, we can re-derive all the metrics.
Consequently, the position update event is a drop-copy feed to reconcile your positions against the ones on the venue

To conclude, we need to emit the correct raw information as the backtest feed and then the consumer of the feed can derive any metrics they need
from the backtest feed.

### Price Sampling
The backtest feed will include the prices in order for the consumers to calculate metrics without having to refetch the price feeds.
The price sampler will emit prices on:
- every fill
- inactivity time more than a specified threshold
- market volatility changes over the threshold
This is the last carried price


```rust
use std::time::Duration;

pub struct DictionaryRef(u16);

/// Type-safe references prevent target-position fields from accidentally using
/// an entry from the wrong dictionary.
pub struct AssetRef(DictionaryRef);
pub struct ContractRef(DictionaryRef);
pub struct InstrumentRef(DictionaryRef);
pub struct AccountRef(DictionaryRef);
pub struct FeedRef(DictionaryRef);

pub struct NanoTimestamp(pub u64);

/// Events are stored within the backtest result
/// `telemetry::EventId` is meant to be globally unique which is unneeded in the context of a backtest.
/// Since this ID will be stored in tables with possibly millions of rows, it's size must be controlled.
/// This ID should preferably be sequential to be compression friendly: https://duckdb.org/2022/10/28/lightweight-compression#bit-packing
pub struct BacktestRunEventId(u32);

/// Engine Sequence Number
pub struct BacktestRunTraceId(u64);

trait HasIdentity {
    type Id;

    // unique identifier of the event
    fn event_id(&self) -> Self::Id;
}

trait HasTracing {
    type Id;

    // trace that could be connected with a larger sequence of the events
    // for instance, additional observability information may be emitted
    fn trace_id(&self) -> Self::Id;
}

trait HasFeedOrderand {
    type Orderand;

    fn feed_orderand(&self) -> Self::Orderand;
}

/// What caused the Event
trait HasProvenance {
    type Item;

    fn provenance(&self) -> Self::Item;
}

pub enum DataCompression {
    None,
    LZ4, // LZ4-frame format
}

pub trait FeedData {
    fn data_feed_ref(&self) -> FeedRef;
    fn bytes(&self) -> &[u8];
    fn compression(&self) -> DataCompression; // source events may be large
    fn uncompressed_size(&self) -> u32; // If there are source events bigger than 4 GB, we have a problem
}



/// Coverage - what the position set contains, and therefore what absence means.
pub enum PositionSetCoverage {
    /// Every open position on the account. A position absent from the set is closed (flat).
    /// Self-contained: a consumer can initialize from zero state with this alone.
    Full,
    /// Only the positions that changed. A position absent from the set is left unchanged.
    Partial,
}

/// Amount semantics - how to interpret each position's numbers (quantity, cost basis).
pub enum PositionAmountSemantics {
    /// The position's new absolute value. Fold by upsert / last-writer-wins per key.
    Absolute,
    /// A signed increment to the prior value. Fold by add per key.
    Increment,
}

/// Monotonically incremented sequence number per feed.
pub struct BacktestFeedOrderand(u64);

pub enum PerpUnderlyingView<'a> {
    Asset(AssetRef),
    Ticker(&'a str),
}

/// Encoding-neutral semantic view over the common market-info fields.
pub trait MarketInfoView {
    fn instrument_ref(&self) -> InstrumentRef;
    fn min_px_inc(&self) -> numerics::Price;
    fn min_qty_inc(&self) -> numerics::Qty;
    fn min_qty(&self) -> numerics::Qty;
    fn base_decimals(&self) -> u8;
    fn quote_decimals(&self) -> u8;
    fn listing_status(&self) -> ListingStatus;
}

pub trait SpotMarketInfoView: MarketInfoView {
    fn base_asset_ref(&self) -> AssetRef;
    fn quote_asset_ref(&self) -> AssetRef;
}

pub trait PerpMarketInfoView: MarketInfoView {
    fn underlying(&self) -> PerpUnderlyingView<'_>;
    fn settlement_asset_ref(&self) -> AssetRef;
    fn quote_unit(&self) -> QuoteUnit;
    fn settlement_qty_per_quote_unit(&self) -> numerics::Decimal;
    fn funding_asset_ref(&self) -> AssetRef;
    fn contract_ref(&self) -> ContractRef;
}

pub enum MarketInfoKind<'a, S: SpotMarketInfoView, P: PerpMarketInfoView> {
    Spot(&'a S),
    Perp(&'a P),
}

pub trait MarketInfoTypeView {
    type Spot: SpotMarketInfoView;
    type Perp: PerpMarketInfoView;

    fn kind(&self) -> PositionKind<'_, Self::Spot, Self::Perp>;
}

impl <T: MarketInfoTypeView> MarketInfoVisitable for T {
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

/// Signals a start of the backtest results feed.
///
/// Needed so consumers can resolve compact account, instrument, contract, and
/// asset references without repeating full identifiers on every high-frequency
/// result event.
///
/// Cadence: `LifecycleDriven`; emitted once when the backtest job starts.
pub trait BacktestDefinition:
HasIdentity<Id  = BacktestRunEventId> +
HasTracing<Id = BacktestRunTraceId> +
HasFeedOrderand<Orderand=BacktestFeedOrderand>
{
    /// -- Dictionaries --
    /// Declare the IDs and entities used throughout the backtest. Later fields
    /// use compact references into these dictionaries.

    /// All the Trading Accounts configured
    fn account_ids(&self) -> Vec<TradingAccountId>;
    fn contract_ids(&self) -> Vec<ContractId>;
    /// All assets in trading-account balances and all assets needed to compute
    /// PnL or portfolio value.
    fn assets(&self) -> Vec<Asset>;
    fn instruments(&self) -> Vec<Instrument>;
    fn feeds(&self) -> Vec<entity_core::data_feed::DataFeedRef>;

    // -- Backtest Config --
    fn strategy_id(&self) -> StrategyId;
    fn strategy_revision_id(&self) -> StrategyRevisionId;
    fn backtest_id(&self) -> BacktestId;
    fn start_time(&self) -> NanoTimestamp;
    fn valuation_asset_ref(&self) -> AssetRef;


    //  -- Market Info Data --
    type MarketInfo: MarketInfoView + MarketInfoTypeView;

    /// Exactly one entry for every item in `instruments()`.
    fn market_info(&self) -> impl Iterator<Item=Self::MarketInfo> + '_;

    // -- Metrics --
    // when the backtest run has started using the wall-clock time
    fn start_time_wall_clock(&self) -> NanoTimestamp;
    // Fixed interval between the emitted metrics events
    fn metrics_interval(&self) -> Duration;
    // Maximum simulated-time interval between complete price-update batches.
    fn max_price_update_interval(&self) -> Duration;
}

pub enum BacktestJobStatus {
    Success,
    Failure,
}

/// Reason for the backtest finish status.
pub enum BacktestCompletionReason {
    Unknown,
    Completed,
    InitializationDeadlineExceeded,
}


#[thiserror::Error]
pub enum BacktestError {
    #[error(message = "Backtest initialization deadline exceeded: required conditions were not met on time")]
    InitializationDeadlineExceeded
}

/// Signals that the backtest job has finished producing result events.
///
/// Needed so consumers that only read the result stream can stop reading after
/// the terminal job status instead of relying on transport EOF.
///
/// Cadence: `LifecycleDriven`; emitted once when the backtest job completes.
pub trait BacktestJobCompleted:
HasIdentity<Id  = BacktestRunEventId> +
HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand=BacktestFeedOrderand>
{
    fn status(&self) -> BacktestJobStatus;
    fn input_events_processed(&self) -> u64;
    /// The job runtime duration in nanoseconds.
    fn elapsed_wall_clock(&self) -> Duration;
    fn end_time_sim(&self) -> NanoTimestamp;
    /// Human-readable status detail.
    fn message(&self) -> String;
    /// Machine-readable common completion reason.
    fn reason(&self) -> BacktestCompletionReason;
}

/// Publishes periodic backtest progress and heartbeat metrics.
/// Needed so consumers can detect progress during long-running backtests and
/// record incremental operational metrics without waiting for completion.
///
/// Cadence: `FixedInterval`; the interval is
///`BacktestDefinition::metrics_interval`.
pub trait BacktestMetrics:
HasIdentity<Id  = BacktestRunEventId> +
HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand=BacktestFeedOrderand>
{
    /// Counts input events processed from the beginning of the job.
    fn input_events_processed_total(&self) -> u64;
    /// Elapsed wall-clock runtime in nanoseconds.
    fn elapsed_wall_clock(&self) -> Duration;
    /// Current simulated timestamp in nanoseconds.
    fn timestamp(&self) -> NanoTimestamp;
}


pub enum TargetPositionContract {
    Derivative { contract_ref: ContractRef },
}

pub enum TargetPositionSubject {
    Asset { asset_ref: AssetRef },
    Contract(TargetPositionContract),
}

/// How the target position constrains the market used for execution.
pub enum TargetPositionMarket {
    /// The execution system chooses the instrument.
    Automatic,
    /// The target position supplies the instrument that must be used.
    Specified { instrument_ref: InstrumentRef },
}

pub trait TargetPosition {
    fn account_ref(&self) -> AccountRef;
    /// The economic position requested by the strategy.
    fn subject(&self) -> TargetPositionSubject;
    /// Whether execution may select a market or must use a specified market.
    fn target_market(&self) -> TargetPositionMarket;
    fn quantity(&self) -> numerics::Qty;
}

pub enum TargetPositionsProvenance {
    SourceEvent { event_id: BacktestRunEventId }
}

/// Records the Target Positions the strategy wants to be in
/// Cadence: `EventDriven`;
pub trait TargetPositions:
HasIdentity<Id  = BacktestRunEventId>
+ HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand=BacktestFeedOrderand>
+ HasProvenance<Item = TargetPositionsProvenance>
{
    /// Simulated timestamp when the event occurred
    fn event_time(&self) -> NanoTimestamp;

    fn positions(&self) -> impl Iterator<Item=TargetPosition>;
}

/// Records the Source Event that triggered one of the backtest feed events, e.g. Target Position Change, Runtime Event, etc
/// Cadence: `EventDriven`;
pub trait TriggeringSourceEvent:
HasIdentity<Id  = BacktestRunEventId> +
HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand = BacktestFeedOrderand>
{
    fn observe_time(&self) -> NanoTimestamp;

    // Opaque bytes with the payload
    fn source_data(&self) -> impl FeedData;
}

// todo: this is not correct, since the fill is triggered by an order
// However, with the time limitations for the demo and the fact that it's not modelled properly in the backtest right now
// we'll take this shortcut
enum FillProvenance {
    TargetPosition { event_id: BacktestRunEventId }
}


/// Records a simulated fill produced by the backtest execution model.
pub trait Fill:
HasIdentity<Id = BacktestRunEventId>
+ HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand=BacktestFeedOrderand>
+ HasProvenance<Item = FillProvenance>
{
    /// When the event happened on the venue
    fn event_time(&self) -> NanoTimestamp;
    /// When the strategy received the event
    fn observe_time(&self) -> NanoTimestamp;

    /// Points to the __market__ where the fill occurred
    fn instrument_ref(&self) -> InstrumentRef;
    /// Which trading account was used
    fn trading_account_ref(&self) -> AccountRef;

    // in market's quote unit
    fn price(&self) -> numerics::Price;
    // Unsigned
    fn quantity(&self) -> numerics::Qty;
    // [REF:trade] Trade
    fn side(&self) -> common::TradeSide;
    // Maker vs. Taker
    fn liquidity_role(&self) -> common::LiquidityRole;
}

enum FillReason {
    /// Our order lifecycle.
    OrderExecution { event_id: BacktestRunEventId },
    /// Venue risk engine forced the execution.
    Liquidation,
    /// Execution observed with no matching order — e.g. manual trade on the venue UI.
    Unattributed,
}


// We may update our computed position based on many triggers: our order fill, liquidation, user manual action, deposits/withdrawals
enum PositionProvenanceKind {
    Fill { reason: FillReason },
    Transfer { event_id: BacktestRunEventId },
}

pub struct PositionProvenance {
    kind: PositionProvenanceKind,
}


/// Records an update in the trading account positions
/// Cadence: `EventDriven`;
trait TradingAccountPositionsUpdate:
HasIdentity<Id  = BacktestRunEventId>
+ HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand=BacktestFeedOrderand>
+ HasProvenance<Item = PositionProvenance>
{
    /// When the event happened on the venue simulator
    fn event_time(&self) -> NanoTimestamp;
    /// When the strategy received the update
    fn observe_time(&self) -> NanoTimestamp;

    // what the position set contains, and therefore what absence means.
    fn coverage(&self) -> PositionSetCoverage;
    // how to interpret each position's numbers (quantity, cost basis).
    fn amount_semantics(&self) -> PositionAmountSemantics;

    fn derivative_positions(&self) -> impl Iterator<Item=DerivativePosition>;
    fn spot_positions(&self) -> impl Iterator<Item=SpotPosition>;
}

pub trait DerivativePosition {
    fn account_ref(&self) -> DictionaryRef;
    fn contract_ref(&self) -> DictionaryRef;
    fn quantity(&self) -> numerics::Qty;
}

pub trait SpotPosition {
    fn account_ref() -> DictionaryRef;
    fn asset_ref() -> DictionaryRef;
    fn quantity() -> numerics::Qty;
}

/// The pricing-domain contract kind: a derivative contract identified by a contract id
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Contract {
    Derivative { contract_ref: DictionaryRef },
}

/// What a price source prices: a spot asset or a market contract.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PriceSubject {
    Asset {
        asset_ref: DictionaryRef,
        quote_asset_ref: DictionaryRef,
    },
    /// The quote unit and the settlement asset must be on the market info
    Contract(Contract),
}


/// Records the price of a contract or an asset for portfolio-value calculation
/// in the configured valuation asset.
pub trait PricesUpdate:
HasFeedOrderand<Orderand=BacktestFeedOrderand> +
HasIdentity<Id  = BacktestRunEventId> +
HasTracing<Id = BacktestRunTraceId>
{
    /// time when these prices are relevant
    fn effective_time(&self) -> NanoTimestamp;
    fn prices(&self) -> impl PriceUpdate;
}

pub trait PriceUpdate {
    fn subject(&self) -> PriceSubject;
    fn price(&self) -> numerics::Price;
}

enum RuntimeEventProvenance {
    /// Emitted while handling a source event: DSL node telemetry (DEC-096S8),
    /// handler diagnostics, errors raised inside an activation.
    SourceEvent { event_id: BacktestRunEventId },
    /// Emitted by a component lifecycle transition (warmup end, Running entered, ...).
    Lifecycle,
    /// Emitted by backtest simulator internals outside any activation or transition.
    Internal,
}

pub trait RuntimeEvent:
HasIdentity<Id  = BacktestRunEventId> +
HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand=BacktestFeedOrderand>
+ HasProvenance<Item=BacktestFeedOrderand>
{
    /// Simulated timestamp.
    fn event_time(&self) -> NanoTimestamp;
    fn severity(&self) -> telemetry::Severity;
    fn event(&self) -> &str;
    fn properties(&self) -> &HashMap<String, String>;
    fn description(&self) -> &str;

    fn tags(&self) -> &[&str];
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

/// Explains why the deposit exists in the backtest feed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DepositProvenance {
    /// Capital declared by the backtest configuration and injected when the
    /// result feed starts.
    BacktestInitialization,
}

/// Records capital entering a simulated trading account.
///
/// A deposit is a raw economic event. It changes the account balance but does
/// not create PnL or trading volume.
pub trait Deposit:
HasIdentity<Id = BacktestRunEventId>
+ HasTracing<Id = BacktestRunTraceId>
+ HasFeedOrderand<Orderand = BacktestFeedOrderand>
+ HasProvenance<Item = DepositProvenance>
{
    /// Simulated time when the deposit becomes effective in the account.
    fn event_time(&self) -> NanoTimestamp;

    /// Account receiving the capital.
    fn trading_account_ref(&self) -> AccountRef;

    /// Asset entering the account.
    fn asset_ref(&self) -> AssetRef;

    /// Unsigned quantity entering the account. Must be greater than zero.
    fn quantity(&self) -> numerics::Qty;

    /// Declared accounting treatment of the deposited asset.
    fn declared_cost_basis(&self) -> DeclaredCostBasis;
}
```
