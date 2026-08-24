in prototypes/accounting/bin/incoming_feed.rs I have the program that generates the economic events based on the quotes in the
prototypes/accounting/data/hyperliquid/quotes.parquet.

Let's update it to also emit the triggering source event, target positions, prices.
I think you should add event_id to be u32 sequential number. The shape should be close enough to the knowledge-base/docs/specs/SPEC-backtest-feed.md.
You can keep the orderands different, since, technically, those are different feeds.

I want to have another program (bin/backtest.rs) that reads all those events, transforms them as if it's a backtest feed, and populates the duck db database
according to the schema in the knowledge-base/docs/decisions/records/DEC-0AB71-demo-backtest-schema.md
We need that just to have the mock data to work on the client. It doesn't have to be correct, just close enough.
You can take some interpretation when it comes to the metric calculation. The key is that there is some data and it's close enough





---
I need to design the database schema for the knowledge-base/docs/specs/SPEC-backtest-feed.md and the derived metrics.
Create a decision document: 'demo backtest schema'.

There you should mention that the schema has some assumptions, and we cut some corners.
Metrics should be a table with a metric name, its definition, purpose (in a very simple language).
You should specify all the assumptions made and the reason I made them. If the reason is not clear - ask me.
You should copy the duck db schema verbatim.

metrics:
- return %/abs
- high watermark %/abs
- low watermark %/abs
- max drawdown %/abs
- sharpe ratio
- volatility
- trade count
- total fees
- target position changes
- calmar ratio
- sortino ratio
- turnover
- volume
- pnl
- portfolio value

We need to store the backtest data feed events:
- triggering source events
- target positions
- fills
- prices
- runtime events
- fees

We'll use the duck db database.

## Assumptions

### Use the type aliases in duck db

```
-- Signed
CREATE TYPE i8  AS TINYINT;      -- -128 .. 127
CREATE TYPE i16 AS SMALLINT;     -- -32768 .. 32767
CREATE TYPE i32 AS INTEGER;      -- -2^31 .. 2^31-1
CREATE TYPE i64 AS BIGINT;       -- -2^63 .. 2^63-1
CREATE TYPE i128 AS HUGEINT;     -- -2^127 .. 2^127-1

-- Unsigned
CREATE TYPE u8  AS UTINYINT;     -- 0 .. 255
CREATE TYPE u16 AS USMALLINT;    -- 0 .. 65535
CREATE TYPE u32 AS UINTEGER;     -- 0 .. 2^32-1
CREATE TYPE u64 AS UBIGINT;      -- 0 .. 2^64-1
CREATE TYPE u128 AS UHUGEINT;    -- 0 .. 2^128-1

-- Floating point
CREATE TYPE f32 AS FLOAT;    -- 32-bit (single precision)
CREATE TYPE f64 AS DOUBLE;   -- 64-bit (double precision)

CREATE TYPE nanosecond AS UBIGINT;
```
Reason: immediately clear what's the size, instead of guessing from a bunch of keywords

### Timestamps use the nanosecond type
Immediately clears the question of the resolution

### Plain enums are i8
Size matters, we don't want strings

### The foreign keys are explicitly disabled to increase the write throughput

### How to handle the provenance?
TBD after demo

### Some of the backtest feed events are missing: BacktestMetrics, BacktestJobCompleted
TBD after demo how to store them

### Definition market information is missing
For the demo purposes, the market info changes are missing

### Counts like "trade count", "target position change count" can be easily derived using aggregate SQL queries

### For the demo, deposit is only USD (valuation asset) and only in the beginning of the backtest


## Proposal

```
-- Signed
CREATE TYPE i8  AS TINYINT;      -- -128 .. 127
CREATE TYPE i16 AS SMALLINT;     -- -32768 .. 32767
CREATE TYPE i32 AS INTEGER;      -- -2^31 .. 2^31-1
CREATE TYPE i64 AS BIGINT;       -- -2^63 .. 2^63-1
CREATE TYPE i128 AS HUGEINT;     -- -2^127 .. 2^127-1

-- Unsigned
CREATE TYPE u8  AS UTINYINT;     -- 0 .. 255
CREATE TYPE u16 AS USMALLINT;    -- 0 .. 65535
CREATE TYPE u32 AS UINTEGER;     -- 0 .. 2^32-1
CREATE TYPE u64 AS UBIGINT;      -- 0 .. 2^64-1
CREATE TYPE u128 AS UHUGEINT;    -- 0 .. 2^128-1

-- Floating point
CREATE TYPE f32 AS FLOAT;    -- 32-bit (single precision)
CREATE TYPE f64 AS DOUBLE;   -- 64-bit (double precision)

CREATE TYPE nanosecond AS UBIGINT;

CREATE SCHEMA feed;    -- raw feed projection: write-once, replayable
CREATE SCHEMA derived; -- post-processor output: rebuildable from feed.*

-- --- Backtet Definition + encoding dictionaries ---

CREATE TABLE feed.definition (           -- exactly one row
    event_id              u32 PRIMARY KEY,
    trace_id              u64 NOT NULL,
    feed_orderand         u64 NOT NULL,
    backtest_id           string NOT NULL,
    strategy_id           string NOT NULL,
    strategy_revision_id  string NOT NULL,
    start_time            nanosecond NOT NULL,   -- simulated
    start_time_wall_clock nanosecond NOT NULL,
    metrics_interval_ns   u64 NOT NULL CHECK (metrics_interval_ns > 0),
    valuation_asset_ref   u16 NOT NULL
);

-- Dictionary refs are the zero-based indices from the definition event (SPEC-4.1.1).
CREATE TABLE feed.accounts (
    account_ref        u16 PRIMARY KEY,
    trading_account_id string NOT NULL
);

CREATE TABLE feed.contracts (
    contract_ref u16 PRIMARY KEY,
    contract_id  string NOT NULL
);

CREATE TABLE feed.assets (
    asset_ref u16 PRIMARY KEY,
    asset_id  string NOT NULL,
    symbol    string NOT NULL
);

CREATE TABLE feed.instruments (
    instrument_ref u16 PRIMARY KEY,
    instrument_id  string NOT NULL,
    symbol         string NOT NULL
);

CREATE TABLE feed.data_feeds (
    feed_ref      u16 PRIMARY KEY,
    feed_id       string not null, -- hex-encoded 32-byte identifier
    revision_id   string not null, -- hex-encoded 32-byte identifier
    encoding      i8  NOT NULL CHECK (encoding IN (0)),  -- 0 Protobuf
);

-- --- Event tables ---

CREATE TABLE feed.deposits (
    event_id            u32 PRIMARY KEY,
    trace_id            u64 NOT NULL,
    feed_orderand       u64 NOT NULL,
    event_time          nanosecond NOT NULL,
    trading_account_ref u16 NOT NULL, --  REFERENCES feed.accounts (account_ref),
    asset_ref           u16 NOT NULL, --  REFERENCES feed.assets (asset_ref),
    quantity            f64 NOT NULL CHECK (quantity > 0)
);

CREATE TABLE feed.source_events (
    event_id          u32 PRIMARY KEY,
    trace_id          u64 NOT NULL,
    feed_orderand     u64 NOT NULL,
    observe_time      nanosecond NOT NULL,
    data_feed_ref     u16 NOT NULL, -- REFERENCES feed.data_feeds (feed_ref),
    compression       i8  NOT NULL CHECK (compression IN (0, 1)),  -- 0 none, 1 lz4-frame
    uncompressed_size u32 NOT NULL,
    data              BLOB NOT NULL
);

CREATE TABLE feed.target_positions (
    event_id                   u32 PRIMARY KEY,
    trace_id                   u64 NOT NULL,
    feed_orderand              u64 NOT NULL,
    event_time                 nanosecond NOT NULL,
    provenance_source_event_id u32 NOT NULL, -- REFERENCES feed.source_events (event_id)
);

CREATE TABLE feed.target_position_items (
    event_id       u32 NOT NULL,       -- REFERENCES feed.target_positions (event_id),
    idx            u16 NOT NULL,       -- order within the event
    account_ref    u16 NOT NULL,       -- REFERENCES feed.accounts (account_ref),
    subject_kind   i8  NOT NULL CHECK (subject_kind IN (0, 1)),   -- 0 asset, 1 derivative contract
    asset_ref      u16,                -- REFERENCES feed.assets (asset_ref),
    contract_ref   u16,                -- REFERENCES feed.contracts (contract_ref),
    market_kind    i8  NOT NULL CHECK (market_kind IN (0, 1)),    -- 0 automatic, 1 specified
    instrument_ref u16,                -- REFERENCES feed.instruments (instrument_ref),
    quantity       f64 NOT NULL,       -- signed
    PRIMARY KEY (event_id, idx),
    CHECK ((subject_kind = 0) = (asset_ref IS NOT NULL)),
    CHECK ((subject_kind = 1) = (contract_ref IS NOT NULL)),
    CHECK ((market_kind = 1) = (instrument_ref IS NOT NULL))
);

CREATE TABLE feed.fills (
    event_id            u32 PRIMARY KEY,
    trace_id            u64 NOT NULL,
    feed_orderand       u64 NOT NULL,
    event_time          nanosecond NOT NULL,   -- venue side
    observe_time        nanosecond NOT NULL,   -- strategy side
    instrument_ref      u16 NOT NULL,          -- REFERENCES feed.instruments (instrument_ref),
    trading_account_ref u16 NOT NULL,          -- REFERENCES feed.accounts (account_ref),
    price               f64 NOT NULL,          -- market quote unit
    quantity            f64 NOT NULL CHECK (quantity > 0),  -- unsigned; direction is `side`
    side                i8  NOT NULL CHECK (side IN (0, 1, 2)),        -- 0 buy, 1 sell, 2 sell_short
    liquidity_role      i8  NOT NULL CHECK (liquidity_role IN (0, 1)), -- 0 maker, 1 taker
    -- FillProvenance::TargetPosition — demo shortcut, revisit with fill→order provenance
    provenance_target_positions_event_id u32 NOT NULL REFERENCES feed.target_positions (event_id)
);

CREATE TABLE feed.demo_only_fees (   -- demo-scoped shape, mirrors DemoOnlyFee naming
    event_id                 u32 PRIMARY KEY,
    trace_id                 u64 NOT NULL,
    feed_orderand            u64 NOT NULL,
    event_time               nanosecond NOT NULL,
    observe_time             nanosecond NOT NULL,
    trading_account_ref      u16 NOT NULL REFERENCES feed.accounts (account_ref),
    instrument_ref           u16 NOT NULL REFERENCES feed.instruments (instrument_ref),
    fee                      f32 NOT NULL,
    provenance_fill_event_id u32 NOT NULL REFERENCES feed.fills (event_id)
);

CREATE TABLE feed.prices_updates (
    event_id       u32 PRIMARY KEY,
    trace_id       u64 NOT NULL,
    feed_orderand  u64 NOT NULL,
    effective_time nanosecond NOT NULL   -- sampler validity time, not event_time
);

CREATE TABLE feed.price_points (
    event_id        u32 NOT NULL,                                 --  REFERENCES feed.prices_updates (event_id),
    idx             u16 NOT NULL,
    subject_kind    i8  NOT NULL CHECK (subject_kind IN (0, 1)),  -- 0 asset pair, 1 derivative contract
    asset_ref       u16 REFERENCES feed.assets (asset_ref),
    quote_asset_ref u16 REFERENCES feed.assets (asset_ref),
    contract_ref    u16 REFERENCES feed.contracts (contract_ref),
    price           f64 NOT NULL,
    PRIMARY KEY (event_id, idx),
    CHECK ((subject_kind = 0) = (asset_ref IS NOT NULL AND quote_asset_ref IS NOT NULL)),
    CHECK ((subject_kind = 1) = (contract_ref IS NOT NULL))
);

CREATE TABLE feed.position_updates (
    event_id         u32 PRIMARY KEY,
    trace_id         u64 NOT NULL,
    feed_orderand    u64 NOT NULL,
    event_time       nanosecond NOT NULL,
    observe_time     nanosecond NOT NULL,
    coverage         i8 NOT NULL CHECK (coverage IN (0, 1)),          -- 0 full, 1 partial
    amount_semantics i8 NOT NULL CHECK (amount_semantics IN (0, 1)),  -- 0 absolute, 1 increment
    -- PositionProvenance flattened:
    -- 0 fill/order_execution, 1 fill/liquidation, 2 fill/unattributed, 3 transfer
    provenance_kind     i8 NOT NULL CHECK (provenance_kind IN (0, 1, 2, 3)),
    provenance_event_id u32,
    CHECK ((provenance_kind IN (0, 3)) = (provenance_event_id IS NOT NULL))
);

CREATE TABLE feed.position_update_derivative_items (
    event_id     u32 NOT NULL REFERENCES feed.position_updates (event_id),
    idx          u16 NOT NULL,
    account_ref  u16 NOT NULL REFERENCES feed.accounts (account_ref),
    contract_ref u16 NOT NULL REFERENCES feed.contracts (contract_ref),
    quantity     f64 NOT NULL,   -- signed; sign is direction (C-06)
    PRIMARY KEY (event_id, idx)
);

CREATE TABLE feed.position_update_spot_items (
    event_id    u32 NOT NULL REFERENCES feed.position_updates (event_id),
    idx         u16 NOT NULL,
    account_ref u16 NOT NULL REFERENCES feed.accounts (account_ref),
    asset_ref   u16 NOT NULL REFERENCES feed.assets (asset_ref),
    quantity    f64 NOT NULL,
    PRIMARY KEY (event_id, idx)
);

CREATE TABLE feed.runtime_events (
    event_id      u32 PRIMARY KEY,
    trace_id      u64 NOT NULL,
    feed_orderand u64 NOT NULL,
    event_time    nanosecond NOT NULL,
    severity      i8 NOT NULL,        -- telemetry::Severity discriminant
    event         string NOT NULL,    -- stable event name
    description   string NOT NULL,
    properties    MAP(string, string) NOT NULL,
    tags          string[] NOT NULL,
    provenance_kind            i8 NOT NULL CHECK (provenance_kind IN (0, 1, 2)),  -- 0 source_event, 1 lifecycle, 2 internal
    provenance_source_event_id u32 REFERENCES feed.source_events (event_id),
    CHECK ((provenance_kind = 0) = (provenance_source_event_id IS NOT NULL))
);

-- --- Derived metrics ---

CREATE TABLE derived.instrument_metric_samples (
    sample_event_id u32 NOT NULL,
    instrument_ref  u16 NOT NULL,
    ts              nanosecond NOT NULL,

    volume          f32 NOT NULL, -- base units
    turnover        f32 NOT NULL, -- quote units

    PRIMARY KEY (sample_event_id, instrument_ref)
);

CREATE TABLE derived.position_samples (
    sample_event_id u32 NOT NULL,
    account_ref     u16 NOT NULL,
    subject_kind    i8  NOT NULL CHECK (subject_kind IN (0, 1)),   -- 0 asset, 1 derivative contract
    subject_ref     u16,                -- REFERENCES feed.assets or feed.contracts,

    ts              nanosecond NOT NULL,
    quantity        f32 NOT NULL,   -- signed

    -- USD
    market_value    f32 NOT NULL,
    unrealized_pnl  f32 NOT NULL,
    realized_pnl    f32 NOT NULL, -- cumulative, as are all below
    fees            f32 NOT NULL,
    --

    volume          f32 NOT NULL, -- base units
    turnover        f32 NOT NULL, -- quote units
    PRIMARY KEY (sample_event_id, account_ref, subject_ref),
);

-- Only what SQL cannot derive from the curves: return-cadence-dependent
-- ratio statistics. Written once by the fold at end of run.
CREATE TABLE derived.portfolio_stats (     -- exactly one row
    volatility f32,   -- NULL: not enough return observations
    sharpe     f32,
    sortino    f32,
    calmar     f32
);

CREATE TABLE derived.account_stats (
    account_ref u16 PRIMARY KEY,
    volatility  f32,
    sharpe      f32,
    sortino     f32,
    calmar      f32
);

-- Dense: one row per (sample × account). This invariant is
-- what makes the portfolio view below correct — sparse emission would break it.
CREATE TABLE derived.portfolio_value (
    sample_event_id u32 NOT NULL,
    account_ref     u16 NOT NULL,
    ts              nanosecond NOT NULL,
    portfolio_value f32 NOT NULL,   -- spot:= qty * price; deriv:= unrealized pnl; pv:= spot + deriv. in the valuation asset
    PRIMARY KEY (sample_event_id, account_ref)
);

--- Run-wide series: sum over accounts per sample. Correct only because
-- derived.portfolio_value is dense (every account, every sample).
CREATE VIEW derived.total_portfolio_value AS
    SELECT sample_event_id, ts, sum(portfolio_value) AS portfolio_value
    FROM derived.portfolio_value
    GROUP BY sample_event_id, ts;

CREATE VIEW derived.account_drawdown AS
    SELECT sample_event_id, account_ref, ts,
           hwm - portfolio_value         AS drawdown_abs,
           (hwm - portfolio_value) / hwm AS drawdown_pct
    FROM (
        SELECT *, max(portfolio_value) OVER (
                   PARTITION BY account_ref
                   ORDER BY ts, sample_event_id) AS hwm
        FROM derived.portfolio_value
    );

CREATE VIEW derived.total_drawdown AS
    SELECT sample_event_id, ts,
           hwm - portfolio_value         AS drawdown_abs,
           (hwm - portfolio_value) / hwm AS drawdown_pct
    FROM (
        SELECT *, max(portfolio_value) OVER (
                   ORDER BY ts, sample_event_id) AS hwm
        FROM derived.total_portfolio_value
    );
```
