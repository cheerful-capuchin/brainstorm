I need to design the ClickHouse database schema for the strategy deployment feed.

Context:
- knowledge-base/docs/decisions/records/DEC-09S6G-strategy-performance-feed.md
- knowledge-base/docs/decisions/records/DEC-0A6WS-strategy-performance-feed-storage.md
- knowledge-base/docs/decisions/records/DEC-0AB71-demo-backtest-schema.md

In a backtest, everything a consumer needs in order to evaluate strategy
performance arrives on one feed: the backtest wrapper produces source events,
target positions, fills, fees, deposits, and position updates itself, so one
ordered stream is enough ([SPEC:backtest-feed]).

A live deployment has no single producer. The strategy emits triggering source
events, logs, and target positions; gateway components emit fills, fees,
deposits, and position updates; different venues may contribute through
different venue gateways. These are separate producers with separate content,
so by the data-feed identity model they are separate feeds.
We cannot simply normalize those feeds into one, since there is a potential
of losing data.
Therefore, the approach I came up with involves storing the raw feed events and also having the derived strategy deployment feed events.

## Assumptions

### everything is USD
we do not handle the multi-unit conversion for the demo

### no double-entry accounting
will be needed once we get to multi-unit conversions, where we specify the ledger
and you cannot create journal postings using different assets

### numeric scales should not be on the records
we either use a tiger beetle approach where we have the "ledger" and all the quantities in that ledger
use the same scale
or we have a timeseries of updates to the accounts, assets, markets and we join that timeseries with the
clickhouse data and then adjust the scale
In any case, we cannot store the floating point numbers

### account_position_aggregate
this table will be very different in production
The moment we introduce multiple units, the average price is going to be calculated differently
The fees are going to be separate accounts
We'll probably keep the qty, volume, turnover

### bounded reordering buffer
event gw will have a grace period for which it buffers the economic events before folding them.
it doesn't mean we buffer the durability. We store the event ASAP, but the fold can be done with a delay.


## Proposed database schema

```
create table if not exists deposits (
    -- Identity --
    event_id                       UInt128 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256 comment 'source feed the event arrived on',,
    revision_id                    UInt256,
    encoding                       Enum8('protobuf' = 0, 'msgpack' = 1, 'sbe' = 2, 'json' = 3, 'rkyv' = 4),
    -- todo: do I need to handle the compression myself or can clickhouse do it?
    data                           String CODEC(ZSTD(3)) comment 'raw representation of the event',

    -- Subject --
    trading_account_id             UInt64,

    -- Semantic Event --
    event_time                     DateTime64(9, 'UTC') comment 'when the event happened on the venue',
    observe_time                   DateTime64(9, 'UTC') comment 'when our system first observed this event',

    asset_id                       UInt64,
    quantity                       UInt128,
    -- todo: we need to have a timeseries of asset definitions per account kind
    -- specifically, we care about the scale of the account quantities.
    -- Tigerbeetle enforces that using the "ledger" mechanics: https://docs.tigerbeetle.com/coding/data-modeling/#ledgers
    -- for the demo purposes, we'll inline the scale in the database
    quantity_scale:                UInt8,


    -- Injestion --
    injestion_time                 DateTime64(9, 'UTC') comment 'when the event was written to the database',
    injestion_orderand             UInt128 comment 'how the injester ordred the ',
);

create table if not exists triggering_source_events (
    -- Identity
    event_id                        UInt128 comment 'globally unique identifier and the idempotency key',
    trace_id                        UInt128 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed
    feed_id                         UInt256,
    revision_id                     UInt256,
    encoding                        UInt8 comment 'Protobuf, JSON, SBE, RKYV, etc',

    -- Subject
    strategy_id             UInt64,
    revision_id             UInt64,
    deployment_id           UInt64,

    -- Time
    event_time UInt64 comment 'when the event happened on the venue',
    observe_time UInt64 comment 'when our system first observed this event',

    -- todo: do I need to handle the compression myself or can clickhouse do it?
    data blob comment 'raw representation of the event',

    injestion_orderand      UInt128,
);

create table if not exists target_positions (
    event_id UInt128 comment 'globally unique identifier and the idempotency key',
    trace_id UInt128 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',
    feed_id UInt256,
    revision_id UInt256,
    encoding UInt8 comment 'Protobuf, JSON, SBE, RKYV, etc',
    event_time UInt64 comment 'when the event happened in the strategy',

    -- todo: do I need to handle the compression myself or can clickhouse do it?
    data blob comment 'raw representation of the event'
);

-- todo: is clickhouse good at joining?
create table if not exists target_positions_items (
    event_id                UInt128 comment 'references target_positions',
    idx                     Uint16 comment 'order within the event',
    strategy_id             UInt64,
    revision_id             UInt64,
    deployment_id           UInt64,
    trading_account_id      Uint64,
    subject                 {record_type}?,
    target_market           {record}?,
    quantity                Int128,
    -- todo: we either derive that based on the account id and the asset
    -- or based on the contract
    quantity_scale:         UInt8,
    side                    UInt8,
)

create table if not exists fills (
    event_id                   UInt128 comment 'globally unique identifier and the idempotency key',
    trace_id                   UInt128 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',
    feed_id                    UInt256,
    revision_id                UInt256,
    encoding                   UInt8 comment 'Protobuf, JSON, SBE, RKYV, etc',
    event_time                 UInt64 comment 'when the event happened on the venue',
    observe_time               UInt64 comment 'when our system first observed this event',
    instrument_id              UInt64 comment 'market reference',
    trading_account_id         UInt64,
    -- todo: can the price be negative?
    price                      Int128, comment 'in market''s quote unit'
    -- todo: bind it to the market info
    price_scale                UInt8,
    quantity                   UInt128,
    -- todo: bind it to the market info
    quantity_scale             UInt8,
    side                       UInt8 comment 'buy/sell/sell short',
    liquidity_role             UInt8 comment 'maker/taker',

    -- todo: do I need to handle the compression myself or can clickhouse do it?
    data blob comment 'raw representation of the event'
);


create table if not exists demo_fees (
    event_id                   UInt128 comment 'globally unique identifier and the idempotency key',
    trace_id                   UInt128 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',
    feed_id                    UInt256,
    revision_id                UInt256,
    encoding                   UInt8 comment 'Protobuf, JSON, SBE, RKYV, etc',
    event_time                 UInt64 comment 'when the event happened on the venue',
    observe_time               UInt64 comment 'when our system first observed this event',
    instrument_id              UInt64 comment 'market reference',
    trading_account_id         UInt64,

    fee                        Int128,
    -- todo: bind it to market info?
    fee_scale                  UInt8,

    -- todo: do I need to handle the compression myself or can clickhouse do it?
    data blob comment 'raw representation of the event'
);

create table if not exists position_updates (
    event_id                   UInt128 comment 'globally unique identifier and the idempotency key',
    trace_id                   UInt128 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',
    feed_id                    UInt256,
    revision_id                UInt256,
    encoding                   UInt8 comment 'Protobuf, JSON, SBE, RKYV, etc',
    event_time                 UInt64 comment 'when the event happened on the venue',
    observe_time               UInt64 comment 'when our system first observed this event',

    coverage                   UInt8 comment 'full/partial',
    amount_semantics           UInt8 comment 'absolute/increment',

    -- todo: do I need to handle the compression myself or can clickhouse do it?
    data blob comment 'raw representation of the event'
);

create table if not exists derivative_position_updates (
    event_id                   UInt128 comment 'reference to position_updates',
    idx                        UInt16 comment 'order in the position update',
    trading_account_id         UInt64,
    contract_id                UInt64,

    quantity                   Int128,
    -- todo: bind it to market info?
    quantity_scale             UInt8,
);

create table if not exists spot_position_updates (
    event_id                   UInt128 comment 'reference to position_updates',
    idx                        UInt16 comment 'order in the position update',
    trading_account_id         UInt64,
    asset_id                   UInt64,

    quantity                   Int128,
    -- todo: bind it to market info?
    quantity_scale             UInt8,
);

create table if not exists account_trading_volume (
    frontier_event_id         UInt128 comment 'latest event included in the metrics',
    frontier_orderand         UInt64  comment  'latest orderand included in the metrics',

    effective_time            UInt64,

    trading_account_id        UInt64,
    instrument_id             UInt64,

    volume                    UInt128 comment 'market''s base unit',
    -- todo: bind it to market info
    volume_scale              UInt8,

    turnover                  UInt128 comment 'market''s quote unit',
    -- todo: bind it to market info
    turnover_scale            UInt8
);

-- todo: better name; scale; multiple quote/fee units (ideally, should be double-entry ledger system);
create table if not exists account_position_aggregate (
    frontier_event_id         UInt128 comment 'latest event included in the metrics',
    frontier_orderand         UInt64  comment  'latest orderand included in the metrics',

    effective_time            UInt64,

    trading_account_id        UInt64,

    -- todo: how do I put in the subject?

    average_price             Int128,
    average_price_scale       UInt8,

    quantity                  Int128,
    quantity_scale            UInt8,

    realized_pnl              Int128,
    pnl_scale                 UInt8,

    fees                      Int128,
    fee_scale                 UInt8,

    volume                    UInt128 comment 'market''s base unit',
    -- todo: bind it to market info
    volume_scale              UInt8,

    turnover                  UInt128 comment 'market''s quote unit',
    -- todo: bind it to market info
    turnover_scale            UInt8
);
```

## Q&A

### if I store the raw original bytes of the message, will clickhouse figure out the compression?
do I need to compress the data myself?

### is there a way to declare an enum type?

### is there a precedent when the price was negative?

### can I join the clickhouse tables?
The case regarding the target positions

### how do I represent the complex types like subject or target market?

