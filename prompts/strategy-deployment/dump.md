I designed the clickhouse database schema for the strategy deployment feed for the demo milestone.
Create the decision document in the knowledege base "strategy-deployment-feed-storage-demo".
You cannot change the database schema in any way and must copy it verbatim. You must include all the "assumptions" in the document.
You must include the Q&A in the document

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
The semantic events can be derived from the feed, which we need in order to do our computations.
Consequently, we'll store the raw events (the exact bytes we got from the wire) in a separate clickhouse table
And, we'll store the derived semantic events in their respective tables.
In order to link the semantic event with the raw event, we use the event_id.

It's important to understand the difference between the feed and the storage schema.
They may not map 1:1.

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

### Feed orderand
The original feed orderand is going to be stored in the raw_event
When it comes to the ingestion orderand, I think I can combine current time + some bump, so I don't have to store the sequence number
between the restarts. If we decide to partition compute, we'll partition by trading account id and maybe by strategy.
When it comes to aggregates, you'd have to order by effective_time and then by the frontier_orderand.
Even though we have the bounded reordering buffer, there may still be events that arrive late

### Event provenance
skipped for the demo

### Sources of events
The fill, position updates, deposits all come from the venue gateways, they have no idea about the strategies or deployments.
The triggering source event, target position are emitted by the strategy deployment

### Stored raw_event
We store the whole message as it comes from the wire.
In application level, we prefer using the zero-copy deserialization, so our properties would just be slices within the bytes that we received.
However, we cannot do that in clickhouse, therefore, there is some duplication of data. However, for our purposes it's appropriate.
Don't confuse it with the messages that include some raw bytes internally.

### How to represent the Subject enum
in rust domain model, we have a subject, which is an enum with 2 variants { contract, asset }.
However, when storing that in the database, it's tricky, because we either have to flat it out and have nullable columns or store as some kind
of data structure. We should decide after the demo

### When calculating the turnover in the valuation asset for the lookback window

|                             | t1          | t2               | t3               | t4                |
|-----------------------------|-------------|------------------|------------------|-------------------|
| quote unit                  | 10          | 20               | 30               | 40                |
| exch. rate                  | 1:2         | 1:3              | 1:4              | 1:5               |
| delta                       | +10         | +10              | +10              | +10               |
| (ephemeral) valuation asset | 10 * 2 = 20 | 20 + 10 * 3 = 50 | 50 + 10 * 4 = 90 | 90 + 10 * 5 = 140 |

If we want to know the volume delta from t2 till t4.
quote unit: t4 - t2 = 20
valuation asset: (t3 - t2) * 4 + (t4 - t3) * 5 = 90
check valuation asset: 140 (t4) - 50 (t2) = 90

So, by just going through deltas, we can see the change in the valuation asset without having to store it in the database.
With the condition that the user may choose a bunch of valuation assets on a client at any moment in time, it works well.
However, this only works with the accumulative commutative terms

## Proposed database schema

```
create table if not exists feed_events (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',

    -- Feed --
    feed_id                        UInt256                 comment 'source feed the event arrived on',
    feed_revision_id               UInt256,
    feed_encoding                  Enum8('protobuf' = 0, 'msgpack' = 1, 'sbe' = 2, 'json' = 3, 'rkyv' = 4),
    raw_event                      String CODEC(ZSTD(3))   comment 'raw representation of the event',

    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC') comment 'when the event was written to the database',
    ingestion_orderand             UInt128              comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Partition: The chances of fetching the raw data of the event decrease dramatically with time
-- Order by: we'll only join and only whenever the user asks for raw data of the event
ENGINE = ReplacingMergeTree
PARTITION BY (toYYYYMM(ingestion_time))
TTL toDateTime(ingestion_time) + INTERVAL 3 MONTH TO VOLUME 'cold'   -- S3-backed disk
ORDER BY (event_id);


create table if not exists deposits (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128                 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256                 comment 'source feed the event arrived on',

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
    quantity_scale                 UInt8,

    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC') comment 'when the event was written to the database',
    ingestion_orderand             UInt128              comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: when quering, we only care about the deposits for particular accounts withing a particular time period. Event ID is to have the dedup logic working properly
ENGINE = ReplacingMergeTree
ORDER BY (trading_account_id, event_time, event_id);

create table if not exists triggering_source_events (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128                 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256,

    -- Subject --
    strategy_id                    UInt64,
    strategy_revision_id           UInt64,
    strategy_deployment_id         UInt64,

    -- Semantic Event --
    event_time                     DateTime64(9, 'UTC')    comment 'when the event actually happened',
    observe_time                   DateTime64(9, 'UTC')    comment 'when our system first observed this event',

    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC')    comment 'when the event was written to the database',
    ingestion_orderand             UInt128                 comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: we're only interested in the source events for a particular deployment.
-- It makes no sense in showing the source events for all your deployments
ENGINE = ReplacingMergeTree
ORDER BY (strategy_id, strategy_revision_id, strategy_deployment_id, event_time, event_id);


create table if not exists target_positions (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128                 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256,

    -- Subject --
    strategy_id                    UInt64,
    strategy_revision_id           UInt64,
    strategy_deployment_id         UInt64,

    -- Semantic Event --
    event_time                     DateTime64(9, 'UTC')    comment 'when the event happened in the strategy',

    positions Nested(
        trading_account_id UInt64,
        subject_kind       Enum8('asset' = 0, 'derivative_contract' = 1),
        asset_id           Nullable(UInt64),
        contract_id        Nullable(UInt64),
        market_kind        Enum8('automatic' = 0, 'specified' = 1),
        instrument_id      Nullable(UInt64),
        quantity           Int128 comment 'signed; direction is the sign [REF:position]',
        quantity_scale     UInt8
    ),

    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC')    comment 'when the event was written to the database',
    ingestion_orderand             UInt128                 comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: we're only interested in the target positions for a particular deployment.
ENGINE = ReplacingMergeTree
ORDER BY (strategy_id, strategy_revision_id, strategy_deployment_id, event_time, event_id);

create table if not exists fills (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128                 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256,

    -- Subject --
    trading_account_id             UInt64,

    -- Semantic Event --
    event_time                     DateTime64(9, 'UTC')    comment 'when the event happened on the venue',
    observe_time                   DateTime64(9, 'UTC')    comment 'when our system first observed this event',
    instrument_id                  UInt64                  comment 'market reference',
    price                          Int128                  comment 'in market''s quote unit. Price can be negative, there was a precident in WTI crude May-2020 futures',
    -- todo: bind it to the market info
    price_scale                    UInt8,
    quantity                       UInt128,
    -- todo: bind it to the market info
    quantity_scale                 UInt8,
    side                           Enum8('buy' = 0, 'sell' = 1),
    liquidity_role                 Enum8('maker' = 0, 'taker' = 1),
    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC')    comment 'when the event was written to the database',
    ingestion_orderand             UInt128                 comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: we're only interested in the fills for a particular trading account
ENGINE = ReplacingMergeTree
ORDER BY (trading_account_id, event_time, event_id);

create table if not exists demo_fees (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128                 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256,

    -- Subject --
    trading_account_id             UInt64,

    -- Semantic Event --
    event_time                     DateTime64(9, 'UTC')    comment 'when the event happened on the venue',
    observe_time                   DateTime64(9, 'UTC')    comment 'when our system first observed this event',
    instrument_id                  UInt64                  comment 'market reference',

    fee                            Int128,
    -- todo: bind it to market info?
    fee_scale                      UInt8,

    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC')    comment 'when the event was written to the database',
    ingestion_orderand             UInt128                 comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: we're only interested in the fills for a particular trading account
ENGINE = ReplacingMergeTree
ORDER BY (trading_account_id, event_time, event_id);


create table if not exists position_updates (
    -- Identity --
    event_id                       UInt128                 comment 'globally unique identifier and the idempotency key',
    trace_id                       UInt128                 comment 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    -- Feed --
    feed_id                        UInt256,

    -- Semantic Event --
    event_time                     DateTime64(9, 'UTC')    comment 'when the event happened on the venue',
    observe_time                   DateTime64(9, 'UTC')    comment 'when our system first observed this event',

    coverage                       Enum8('full' = 0, 'partial' = 1),
    amount_semantics               Enum8('absolute' = 0, 'increment' = 1),

    trading_account_id             UInt64,

    spot_positions Nested(
        asset_id           UInt64,
        quantity           Int128,
        quantity_scale     UInt8
    ),

    derivative_positions Nested(
        contract_id        UInt64,
        quantity           Int128 comment 'signed; sign is direction',
        quantity_scale     UInt8
    ),

    -- Ingestion --
    ingestion_time                 DateTime64(9, 'UTC')    comment 'when the event was written to the database',
    ingestion_orderand             UInt128                 comment 'order in which the database writer received the event',
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: we're only interested in the position updates for a particular trading account
ENGINE = ReplacingMergeTree
ORDER BY (trading_account_id, event_time, event_id);

create table if not exists account_trading_volume (
    frontier_event_id         UInt128  comment 'latest event included in the metrics',
    frontier_orderand         UInt128  comment  'latest orderand included in the metrics',

    effective_time            DateTime64(9, 'UTC'),

    trading_account_id        UInt64,
    instrument_id             UInt64,

    volume                    UInt128 comment 'market''s base unit',
    -- todo: bind it to market info
    volume_scale              UInt8,

    turnover                  Int128 comment 'market''s quote unit; signed since the price could be negative',
    -- todo: bind it to market info
    turnover_scale            UInt8
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Partition by: when displaying volume, we only care about the change in the lookback period.
-- When it comes to base and quote units we can simply subtract the latest value from the earliest value in that time window.
-- When it comes to the valuation, though, we need to multiply all the deltas between the data points by the price at that time.
-- Order by: we're only interested in the trading volume for a particular trading account, optionally with the instrument specification
ENGINE = ReplacingMergeTree(frontier_orderand)
PARTITION BY (toYYYYMM(effective_time))
ORDER BY (trading_account_id, instrument_id, effective_time);


-- todo: better name; scale; multiple quote/fee units (ideally, should be double-entry ledger system);
create table if not exists account_position_aggregate (
    frontier_event_id         UInt128 comment 'latest event included in the metrics',
    frontier_orderand         UInt128  comment  'latest orderand included in the metrics',

    effective_time            DateTime64(9, 'UTC'),

    trading_account_id        UInt64,

    -- the subject: sort keys cannot be Nullable, so the id shares one column
    -- and subject_kind names its namespace (asset id vs contract id) —
    subject_kind              Enum8('asset' = 0, 'derivative_contract' = 1),
    subject_id                UInt64,

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
)
-- Clarifications:
-- Engine: ReplacingMergeTree - dedup the events by the ordering key.
-- Order by: we're only interested in the trading volume for a particular trading account
ENGINE = ReplacingMergeTree(frontier_orderand)
ORDER BY (trading_account_id, subject_kind, subject_id, effective_time);


CREATE TABLE IF NOT EXISTS event_logs
(
    -- Identity
    event_id            UInt128
        COMMENT 'Optional unique identifier of this event.\nWhen set, it can be used for deduplication on the consumer side.',

    trace_id            UInt128
        COMMENT 'Trace identifier for correlating related events across services.\nNot unique — many events can share the same trace.',

    span_id             UInt64
        COMMENT 'Optional. A span is a single, bounded unit of work within a distributed trace.\nA trace represents the full lifecycle of a request as it propagates across systems (e.g., an HTTP request flowing through multiple microservices).\nA span represents one operation or step within that trace.',


    timestamp_nanos     UInt64
        COMMENT 'When the event occurred, in nanoseconds since Unix epoch.\nNanosecond precision is used intentionally to support high-frequency trading scenarios.\nA single timestamp column simplifies indexing and querying;\nClients can truncate to the precision they need (micros, millis, seconds).',

    severity            UInt16
        COMMENT 'The importance of the event. In the application layer it''s an enum. In the persistence layer it''s a number.\nThe persistence is kept loose intentionally to avoid migrating data.',

    event               LowCardinality(String)
        COMMENT 'A static, dot-delimited name describing what happened (e.g. "order.filled", "worker.restarted").\nMust be stable so we can search/aggregate on it.\nThe persistence is kept loose intentionally to avoid migrating data.',

    properties          Map(String, String)
        COMMENT 'key-value metadata attached to the event.',

    description         String DEFAULT ''
        COMMENT 'Free-form, human-readable message explaining the event.',

    -- Subject (an object of interest associated with the produced event) --

    subject_parent_type UInt8
        COMMENT 'Subject - an object of interest associated with the produced event.\nParent - Identifies the ownership scope. ParentType - enum.\nThe persistence is kept loose intentionally to avoid migrating data.',

    subject_parent_id   UInt64
        COMMENT 'Subject - an object of interest associated with the produced event.\nParent - Identifies the ownership scope',

    subject_children    Array(Tuple(String, String))
        COMMENT 'Subject - an object of interest associated with the produced event.\nChildren - the hierarchical entities involved in the event (e.g. a user owns a strategy, which owns a revision)',

    -- Source (Identifies the origin of an event or message within the multi-tenant infrastructure) --

    source_parent_type  UInt8
        COMMENT 'Source - Identifies the origin of an event within the multi-tenant infrastructure.\nParent - Identifies the ownership scope. ParentType - enum.\nThe persistence is kept loose intentionally to avoid migrating data.',

    source_parent_id    UInt64
        COMMENT 'Source - Identifies the origin of an event within the multi-tenant infrastructure.\nParent - Identifies the ownership scope',

    source_type         UInt16
        COMMENT 'Source - Identifies the origin of an event within the multi-tenant infrastructure.\nSource Type - component kind that emitted the event, e.g. GATEWAY, STRATEGY, WORKER.\nThe persistence is kept loose intentionally to avoid migrating data.',

    source_id           UInt64
        COMMENT 'Source - Identifies the origin of an event within the multi-tenant infrastructure.\nSource instance ID.',

    source_metadata     Map(String, String)
        COMMENT 'Source - Identifies the origin of an event within the multi-tenant infrastructure.\nArbitrary key-value metadata attached to the source.',

    source_version      UInt64
        COMMENT 'Source - Identifies the origin of an event within the multi-tenant infrastructure.\nSource version.',

    tags                Array(String)
        COMMENT 'Freeform tags for filtering and categorization.'
)
    ENGINE = MergeTree
        PARTITION BY toDate(fromUnixTimestamp64Nano(timestamp_nanos))
        ORDER BY (subject_parent_type, subject_parent_id, source_type, severity, subject_children, timestamp_nanos)
        COMMENT 'Event Logs Table\nStores the structured event logs emitted by different components of the system for the observability, telemetry, domain information purposes';
-- primary query filters
-- where:
-- - subject_parent_type = ? (ownership must always be enforced)
-- - subject_parent_id = ? (ownership must always be enforced)
-- - source_type in (?, ?, ?) (filter out the components that the user doesn't have to know about, e.g. target_executor, gateways)
-- - severity > ? (show info logs by default)
-- - timestamp_nanos between X and Y -> 90%
-- - subject_children includes (?, ?) -> 60-70%
-- - event = ?
```

## Q&A

### if I store the raw original bytes of the message, will clickhouse figure out the compression?
do I need to compress the data myself?
A: Every column is compressed per granule automatically (default LZ4, set globally or per column via `CODEC(...)`). For the `data` payload use `String CODEC(ZSTD(3))`.
Important: we store the whole raw object that we received from the wire.

### is there a way to declare an enum type?
A: Yes. `Enum8('protobuf' = 0, 'json' = 1)` / `Enum16`. Stored as the integer, rendered as the name, and an insert with an undeclared discriminant is rejected at write time.
Adding a variant later is a metadata-only `ALTER TABLE ... MODIFY COLUMN`.

### is there a precedent when the price was negative?
A: WTI crude May-2020 futures settled at −$37.63/bbl on 2020-04-20; CME had to switch its options pricing to a model that permits negative strikes.
European and Australian power markets print negative prices routinely, and US natgas at Waha hub has traded negative.
Keep price Int128 signed.

### how do I represent the complex types like subject or target market?
A: TBD after demo. For now just flatten them, so we can optimize and index

