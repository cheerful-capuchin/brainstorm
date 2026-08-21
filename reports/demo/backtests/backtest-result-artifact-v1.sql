-- Backtest Result Artifact schema design v1.
-- Companion to the brainstorm backtest-result-artifact report; not an accepted
-- storage contract.
-- One DuckDB artifact contains exactly one backtest run.

-- Signed integers.
CREATE TYPE i8 AS TINYINT;
CREATE TYPE i16 AS SMALLINT;
CREATE TYPE i32 AS INTEGER;
CREATE TYPE i64 AS BIGINT;
CREATE TYPE i128 AS HUGEINT;

-- Unsigned integers.
CREATE TYPE u8 AS UTINYINT;
CREATE TYPE u16 AS USMALLINT;
CREATE TYPE u32 AS UINTEGER;
CREATE TYPE u64 AS UBIGINT;
CREATE TYPE u128 AS UHUGEINT;

-- Floating point.
CREATE TYPE f32 AS FLOAT;
CREATE TYPE f64 AS DOUBLE;

-- DuckDB already provides STRING as an alias for VARCHAR. Re-declaring it
-- fails, so this schema uses the built-in STRING type directly.
CREATE TYPE nanosecond AS UBIGINT;

-- -------------------------------------------------------------------------
-- Artifact manifest and enum manifest
-- -------------------------------------------------------------------------

CREATE TABLE enum_variants
(
    enum_type  STRING NOT NULL,
    enum_value i8     NOT NULL,
    variant    STRING NOT NULL,
    PRIMARY KEY (enum_type, enum_value),
    UNIQUE (enum_type, variant)
);

INSERT INTO enum_variants VALUES
    ('artifact_state', 0, 'writing'),
    ('artifact_state', 1, 'complete'),

    ('event_kind', 0, 'definition'),
    ('event_kind', 1, 'backtest_metrics'),
    ('event_kind', 2, 'fill'),
    ('event_kind', 3, 'trading_account_positions_update'),
    ('event_kind', 4, 'prices_update'),
    ('event_kind', 5, 'job_completed'),
    ('event_kind', 6, 'runtime_event'),
    ('event_kind', 7, 'target_positions'),
    ('event_kind', 8, 'triggering_source_event'),
    ('event_kind', 9, 'deposit'),
    ('event_kind', 10, 'demo_only_fee'),

    ('asset_kind', 0, 'crypto'),
    ('asset_kind', 1, 'fiat'),
    ('crypto_asset_kind', 0, 'native'),
    ('crypto_asset_kind', 1, 'token'),
    ('fiat', 0, 'us_fed'),
    ('fiat', 1, 'ecb'),
    ('fiat', 2, 'boj'),

    ('blockchain', 0, 'none'),
    ('blockchain', 1, 'bitcoin'),
    ('blockchain', 2, 'ethereum'),
    ('blockchain', 3, 'solana'),
    ('blockchain', 4, 'base'),
    ('blockchain', 5, 'polygon'),
    ('blockchain', 6, 'arbitrum'),
    ('blockchain', 7, 'avalanche'),
    ('blockchain', 8, 'optimism'),
    ('blockchain', 9, 'bsc'),
    ('blockchain', 10, 'tron'),
    ('blockchain', 11, 'sui'),
    ('blockchain', 12, 'near'),
    ('blockchain', 13, 'cronos'),
    ('blockchain', 14, 'gnosis'),
    ('blockchain', 15, 'aptos'),
    ('blockchain', 16, 'scroll'),
    ('blockchain', 17, 'kava'),
    ('blockchain', 18, 'ton'),
    ('blockchain', 19, 'cardano'),
    ('blockchain', 20, 'mantle'),
    ('blockchain', 21, 'blast'),
    ('blockchain', 22, 'algorand'),
    ('blockchain', 23, 'thorchain'),
    ('blockchain', 24, 'rsk'),
    ('blockchain', 25, 'osmosis'),
    ('blockchain', 26, 'mixin'),
    ('blockchain', 27, 'celo'),
    ('blockchain', 28, 'hedera'),
    ('blockchain', 29, 'fantom'),
    ('blockchain', 30, 'zk_sync_era'),
    ('blockchain', 31, 'klaytn'),
    ('blockchain', 32, 'fusion'),
    ('blockchain', 33, 'eos'),
    ('blockchain', 34, 'acala'),
    ('blockchain', 35, 'stacks'),
    ('blockchain', 36, 'tezos'),
    ('blockchain', 37, 'neo'),
    ('blockchain', 38, 'metis'),
    ('blockchain', 39, 'telos'),
    ('blockchain', 40, 'astar'),
    ('blockchain', 41, 'conflux'),
    ('blockchain', 42, 'moonbeam'),
    ('blockchain', 43, 'heco'),
    ('blockchain', 44, 'canto'),
    ('blockchain', 45, 'secret'),
    ('blockchain', 46, 'aurora'),
    ('blockchain', 47, 'ontology_evm'),
    ('blockchain', 48, 'hyperliquid'),

    ('instrument_kind', 0, 'spot'),
    ('instrument_kind', 1, 'perp'),
    ('venue', 0, 'drift'),
    ('venue', 1, 'hyperliquid'),
    ('venue', 2, 'okx'),
    ('venue', 3, 'binance'),
    ('venue', 4, 'bybit'),
    ('venue', 5, 'coinbase'),
    ('venue', 6, 'bitget'),
    ('venue', 7, 'gate'),

    ('encoding_kind', 0, 'protobuf'),
    ('encoding_kind', 1, 'msgpack'),
    ('encoding_kind', 2, 'sbe'),
    ('encoding_kind', 3, 'json'),
    ('encoding_kind', 4, 'rkyv'),
    ('encoding_kind', 5, 'other'),

    ('market_info_kind', 0, 'spot'),
    ('market_info_kind', 1, 'perp'),
    ('listing_status', 0, 'upcoming'),
    ('listing_status', 1, 'active'),
    ('listing_status', 2, 'delisted'),
    ('perp_underlying_kind', 0, 'asset'),
    ('quote_unit_kind', 0, 'asset'),

    ('data_compression', 0, 'none'),
    ('data_compression', 1, 'lz4'),
    ('backtest_job_status', 0, 'success'),
    ('backtest_job_status', 1, 'failure'),
    ('backtest_completion_reason', 0, 'unknown'),
    ('backtest_completion_reason', 1, 'completed'),
    ('backtest_completion_reason', 2, 'initialization_deadline_exceeded'),

    ('trade_side', 0, 'buy'),
    ('trade_side', 1, 'sell'),
    ('trade_side', 2, 'sell_short'),
    ('liquidity_role', 0, 'maker'),
    ('liquidity_role', 1, 'taker'),

    ('target_position_subject_kind', 0, 'asset'),
    ('target_position_subject_kind', 1, 'derivative_contract'),
    ('target_position_market_kind', 0, 'automatic'),
    ('target_position_market_kind', 1, 'specified'),
    ('target_positions_provenance', 0, 'source_event'),
    ('fill_provenance', 0, 'target_position'),

    ('position_set_coverage', 0, 'full'),
    ('position_set_coverage', 1, 'partial'),
    ('position_amount_semantics', 0, 'absolute'),
    ('position_amount_semantics', 1, 'increment'),
    ('position_provenance_kind', 0, 'fill'),
    ('position_provenance_kind', 1, 'transfer'),
    ('fill_reason', 0, 'order_execution'),
    ('fill_reason', 1, 'liquidation'),
    ('fill_reason', 2, 'unattributed'),

    ('price_subject_kind', 0, 'asset_pair'),
    ('price_subject_kind', 1, 'derivative_contract'),

    ('runtime_event_provenance', 0, 'source_event'),
    ('runtime_event_provenance', 1, 'lifecycle'),
    ('runtime_event_provenance', 2, 'internal'),
    ('runtime_severity', 0, 'default'),
    ('runtime_severity', 1, 'debug'),
    ('runtime_severity', 2, 'info'),
    ('runtime_severity', 3, 'notice'),
    ('runtime_severity', 4, 'warning'),
    ('runtime_severity', 5, 'error'),
    ('runtime_severity', 6, 'critical'),
    ('runtime_severity', 7, 'alert'),
    ('runtime_severity', 8, 'emergency'),

    ('declared_cost_basis', 0, 'not_applicable'),
    ('deposit_provenance', 0, 'backtest_initialization'),
    ('fee_provenance', 0, 'fill');

CREATE TABLE artifact_manifest
(
    manifest_id             u8         NOT NULL PRIMARY KEY CHECK (manifest_id = 0),
    schema_version          u16        NOT NULL CHECK (schema_version = 1),
    metric_semantics_version u16       NOT NULL,
    source_spec_slug        STRING     NOT NULL CHECK (source_spec_slug = 'backtest-feed'),
    writer_version          STRING     NOT NULL,
    artifact_state          i8         NOT NULL CHECK (artifact_state BETWEEN 0 AND 1),
    created_at_wall_clock   nanosecond NOT NULL,
    published_at_wall_clock nanosecond,
    last_feed_orderand      u64,
    CHECK (
        (artifact_state = 0 AND published_at_wall_clock IS NULL)
        OR
        (artifact_state = 1 AND published_at_wall_clock IS NOT NULL AND last_feed_orderand IS NOT NULL)
    )
);

-- -------------------------------------------------------------------------
-- Feed envelope and definition dictionaries
-- -------------------------------------------------------------------------

CREATE TABLE feed_events
(
    event_id      u32 NOT NULL PRIMARY KEY,
    feed_orderand u64 NOT NULL UNIQUE,
    trace_id      u64 NOT NULL,
    event_kind    i8  NOT NULL CHECK (event_kind BETWEEN 0 AND 10)
);

CREATE TABLE accounts
(
    account_ref u16 NOT NULL PRIMARY KEY,
    account_id  u64 NOT NULL UNIQUE
);

CREATE TABLE assets
(
    asset_ref         u16    NOT NULL PRIMARY KEY,
    asset_id          u64    NOT NULL UNIQUE,
    symbol            STRING NOT NULL,
    name              STRING NOT NULL,
    asset_kind        i8     NOT NULL CHECK (asset_kind BETWEEN 0 AND 1),

    -- Crypto-only fields.
    blockchain        i8 CHECK (blockchain BETWEEN 0 AND 48),
    crypto_asset_kind i8,
    contract_address  STRING,
    decimals          u8,

    -- Fiat-only field.
    fiat              i8,

    CHECK (
        (
            asset_kind = 0
            AND blockchain IS NOT NULL
            AND crypto_asset_kind BETWEEN 0 AND 1
            AND decimals IS NOT NULL
            AND fiat IS NULL
            AND (
                (crypto_asset_kind = 0 AND contract_address IS NULL)
                OR
                (crypto_asset_kind = 1 AND contract_address IS NOT NULL)
            )
        )
        OR
        (
            asset_kind = 1
            AND blockchain IS NULL
            AND crypto_asset_kind IS NULL
            AND contract_address IS NULL
            AND decimals IS NULL
            AND fiat BETWEEN 0 AND 2
        )
    )
);

CREATE TABLE contracts
(
    contract_ref u16 NOT NULL PRIMARY KEY,
    contract_id  u64 NOT NULL UNIQUE
);

CREATE TABLE instruments
(
    instrument_ref  u16    NOT NULL PRIMARY KEY,
    instrument_id   u64    NOT NULL UNIQUE,
    symbol          STRING NOT NULL,
    instrument_kind i8     NOT NULL CHECK (instrument_kind BETWEEN 0 AND 1),
    venue           i8     NOT NULL CHECK (venue BETWEEN 0 AND 7)
);

CREATE TABLE data_feeds
(
    feed_ref       u16    NOT NULL PRIMARY KEY,
    feed_id        BLOB   NOT NULL CHECK (octet_length(feed_id) = 32),
    revision_id    BLOB   NOT NULL CHECK (octet_length(revision_id) = 32),
    encoding_kind  i8     NOT NULL CHECK (encoding_kind BETWEEN 0 AND 5),
    other_encoding STRING,
    UNIQUE (feed_id, revision_id, encoding_kind, other_encoding),
    CHECK (
        (encoding_kind = 5 AND other_encoding IS NOT NULL)
        OR
        (encoding_kind <> 5 AND other_encoding IS NULL)
    )
);

CREATE TABLE market_info
(
    instrument_ref u16 NOT NULL PRIMARY KEY REFERENCES instruments(instrument_ref),
    market_kind    i8  NOT NULL CHECK (market_kind BETWEEN 0 AND 1),
    min_px_inc     f32 NOT NULL CHECK (isfinite(min_px_inc) AND min_px_inc > 0),
    min_qty_inc    f32 NOT NULL CHECK (isfinite(min_qty_inc) AND min_qty_inc > 0),
    min_qty        f32 NOT NULL CHECK (isfinite(min_qty) AND min_qty > 0),
    base_decimals  u8  NOT NULL,
    quote_decimals u8  NOT NULL,
    listing_status i8  NOT NULL CHECK (listing_status BETWEEN 0 AND 2)
);

CREATE TABLE spot_market_info
(
    instrument_ref u16 NOT NULL PRIMARY KEY REFERENCES market_info(instrument_ref),
    base_asset_ref u16 NOT NULL REFERENCES assets(asset_ref),
    quote_asset_ref u16 NOT NULL REFERENCES assets(asset_ref),
    CHECK (base_asset_ref <> quote_asset_ref)
);

CREATE TABLE perp_market_info
(
    instrument_ref                  u16 NOT NULL PRIMARY KEY REFERENCES market_info(instrument_ref),
    underlying_kind                 i8  NOT NULL CHECK (underlying_kind = 0),
    underlying_asset_ref            u16 NOT NULL REFERENCES assets(asset_ref),
    settlement_asset_ref            u16 NOT NULL REFERENCES assets(asset_ref),
    quote_unit_kind                  i8  NOT NULL CHECK (quote_unit_kind = 0),
    quote_asset_ref                  u16 NOT NULL REFERENCES assets(asset_ref),
    settlement_qty_per_quote_unit    f32 NOT NULL
                                           CHECK (
                                               isfinite(settlement_qty_per_quote_unit)
                                               AND settlement_qty_per_quote_unit > 0
                                           ),
    funding_asset_ref               u16 NOT NULL REFERENCES assets(asset_ref),
    contract_ref                    u16 NOT NULL UNIQUE REFERENCES contracts(contract_ref)
);

CREATE TABLE backtest_definition_events
(
    definition_slot       u8         NOT NULL PRIMARY KEY CHECK (definition_slot = 0),
    event_id              u32        NOT NULL UNIQUE REFERENCES feed_events(event_id),
    strategy_id           u64        NOT NULL,
    strategy_revision_id  u64        NOT NULL,
    backtest_id           u64        NOT NULL,
    start_time            nanosecond NOT NULL,
    valuation_asset_ref   u16        NOT NULL REFERENCES assets(asset_ref),
    start_time_wall_clock nanosecond NOT NULL,
    metrics_interval      nanosecond NOT NULL CHECK (metrics_interval > 0)
);

-- -------------------------------------------------------------------------
-- Feed event payload tables
-- -------------------------------------------------------------------------

CREATE TABLE backtest_metrics_events
(
    event_id                     u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    input_events_processed_total u64        NOT NULL,
    elapsed_wall_clock           nanosecond NOT NULL,
    simulated_time               nanosecond NOT NULL
);

CREATE TABLE backtest_job_completed_events
(
    completion_slot        u8         NOT NULL PRIMARY KEY CHECK (completion_slot = 0),
    event_id               u32        NOT NULL UNIQUE REFERENCES feed_events(event_id),
    status                 i8         NOT NULL CHECK (status BETWEEN 0 AND 1),
    input_events_processed u64        NOT NULL,
    elapsed_wall_clock     nanosecond NOT NULL,
    end_time               nanosecond NOT NULL,
    message                STRING     NOT NULL,
    reason                 i8         NOT NULL CHECK (reason BETWEEN 0 AND 2)
);

CREATE TABLE triggering_source_events
(
    event_id          u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    observe_time      nanosecond NOT NULL,
    feed_ref          u16        NOT NULL REFERENCES data_feeds(feed_ref),
    payload           BLOB       NOT NULL,
    compression       i8         NOT NULL CHECK (compression BETWEEN 0 AND 1),
    uncompressed_size u32        NOT NULL
);

CREATE TABLE target_positions_events
(
    event_id          u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    event_time        nanosecond NOT NULL,
    provenance_kind   i8         NOT NULL CHECK (provenance_kind = 0),
    source_event_id   u32        NOT NULL REFERENCES triggering_source_events(event_id)
);

CREATE TABLE target_position_items
(
    event_id           u32 NOT NULL REFERENCES target_positions_events(event_id),
    position_ordinal   u16 NOT NULL,
    account_ref        u16 NOT NULL REFERENCES accounts(account_ref),
    subject_kind       i8  NOT NULL CHECK (subject_kind BETWEEN 0 AND 1),
    asset_ref          u16 REFERENCES assets(asset_ref),
    contract_ref       u16 REFERENCES contracts(contract_ref),
    target_market_kind i8  NOT NULL CHECK (target_market_kind BETWEEN 0 AND 1),
    instrument_ref     u16 REFERENCES instruments(instrument_ref),
    quantity           f32 NOT NULL CHECK (isfinite(quantity)),
    PRIMARY KEY (event_id, position_ordinal),
    CHECK (
        (subject_kind = 0 AND asset_ref IS NOT NULL AND contract_ref IS NULL)
        OR
        (subject_kind = 1 AND asset_ref IS NULL AND contract_ref IS NOT NULL)
    ),
    CHECK (
        (target_market_kind = 0 AND instrument_ref IS NULL)
        OR
        (target_market_kind = 1 AND instrument_ref IS NOT NULL)
    )
);

CREATE TABLE fill_events
(
    event_id                 u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    event_time               nanosecond NOT NULL,
    observe_time             nanosecond NOT NULL,
    instrument_ref           u16        NOT NULL REFERENCES instruments(instrument_ref),
    account_ref              u16        NOT NULL REFERENCES accounts(account_ref),
    price                    f32        NOT NULL CHECK (isfinite(price) AND price > 0),
    quantity                 f32        NOT NULL CHECK (isfinite(quantity) AND quantity > 0),
    side                     i8         NOT NULL CHECK (side BETWEEN 0 AND 2),
    liquidity_role           i8         NOT NULL CHECK (liquidity_role BETWEEN 0 AND 1),
    provenance_kind          i8         NOT NULL CHECK (provenance_kind = 0),
    target_positions_event_id u32       NOT NULL REFERENCES target_positions_events(event_id)
);

CREATE TABLE trading_account_position_update_events
(
    event_id            u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    event_time          nanosecond NOT NULL,
    observe_time        nanosecond NOT NULL,
    coverage            i8         NOT NULL CHECK (coverage BETWEEN 0 AND 1),
    amount_semantics    i8         NOT NULL CHECK (amount_semantics BETWEEN 0 AND 1),
    provenance_kind     i8         NOT NULL CHECK (provenance_kind BETWEEN 0 AND 1),
    fill_reason         i8         CHECK (fill_reason BETWEEN 0 AND 2),
    provenance_event_id u32        REFERENCES feed_events(event_id),
    CHECK (
        (
            provenance_kind = 0
            AND fill_reason = 0
            AND provenance_event_id IS NOT NULL
        )
        OR
        (
            provenance_kind = 0
            AND fill_reason IN (1, 2)
            AND provenance_event_id IS NULL
        )
        OR
        (
            provenance_kind = 1
            AND fill_reason IS NULL
            AND provenance_event_id IS NOT NULL
        )
    )
);

CREATE TABLE derivative_position_items
(
    event_id         u32 NOT NULL REFERENCES trading_account_position_update_events(event_id),
    position_ordinal u16 NOT NULL,
    account_ref      u16 NOT NULL REFERENCES accounts(account_ref),
    contract_ref     u16 NOT NULL REFERENCES contracts(contract_ref),
    quantity         f32 NOT NULL CHECK (isfinite(quantity)),
    PRIMARY KEY (event_id, position_ordinal)
);

CREATE TABLE spot_position_items
(
    event_id         u32 NOT NULL REFERENCES trading_account_position_update_events(event_id),
    position_ordinal u16 NOT NULL,
    account_ref      u16 NOT NULL REFERENCES accounts(account_ref),
    asset_ref        u16 NOT NULL REFERENCES assets(asset_ref),
    quantity         f32 NOT NULL CHECK (isfinite(quantity)),
    PRIMARY KEY (event_id, position_ordinal)
);

CREATE TABLE prices_update_events
(
    event_id       u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    effective_time nanosecond NOT NULL
);

CREATE TABLE price_update_items
(
    event_id        u32 NOT NULL REFERENCES prices_update_events(event_id),
    price_ordinal   u16 NOT NULL,
    subject_kind    i8  NOT NULL CHECK (subject_kind BETWEEN 0 AND 1),
    asset_ref       u16 REFERENCES assets(asset_ref),
    quote_asset_ref u16 REFERENCES assets(asset_ref),
    contract_ref    u16 REFERENCES contracts(contract_ref),
    price           f32 NOT NULL CHECK (isfinite(price) AND price > 0),
    PRIMARY KEY (event_id, price_ordinal),
    CHECK (
        (
            subject_kind = 0
            AND asset_ref IS NOT NULL
            AND quote_asset_ref IS NOT NULL
            AND contract_ref IS NULL
            AND asset_ref <> quote_asset_ref
        )
        OR
        (
            subject_kind = 1
            AND asset_ref IS NULL
            AND quote_asset_ref IS NULL
            AND contract_ref IS NOT NULL
        )
    )
);

CREATE TABLE runtime_events
(
    event_id         u32                 NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    event_time       nanosecond          NOT NULL,
    provenance_kind  i8                  NOT NULL CHECK (provenance_kind BETWEEN 0 AND 2),
    source_event_id  u32                 REFERENCES triggering_source_events(event_id),
    severity         i8                  NOT NULL CHECK (severity BETWEEN 0 AND 8),
    event_name       STRING              NOT NULL,
    properties       MAP(STRING, STRING) NOT NULL,
    description      STRING              NOT NULL,
    tags             STRING[]            NOT NULL,
    CHECK (
        (provenance_kind = 0 AND source_event_id IS NOT NULL)
        OR
        (provenance_kind IN (1, 2) AND source_event_id IS NULL)
    )
);

CREATE TABLE deposit_events
(
    event_id            u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    event_time          nanosecond NOT NULL,
    account_ref         u16        NOT NULL REFERENCES accounts(account_ref),
    asset_ref           u16        NOT NULL REFERENCES assets(asset_ref),
    quantity            f32        NOT NULL CHECK (isfinite(quantity) AND quantity > 0),
    declared_cost_basis i8         NOT NULL CHECK (declared_cost_basis = 0),
    provenance_kind     i8         NOT NULL CHECK (provenance_kind = 0)
);

CREATE TABLE fee_events
(
    event_id       u32        NOT NULL PRIMARY KEY REFERENCES feed_events(event_id),
    event_time     nanosecond NOT NULL,
    observe_time   nanosecond NOT NULL,
    account_ref    u16        NOT NULL REFERENCES accounts(account_ref),
    instrument_ref u16        NOT NULL REFERENCES instruments(instrument_ref),
    fee            f32        NOT NULL CHECK (isfinite(fee) AND fee >= 0),
    provenance_kind i8        NOT NULL CHECK (provenance_kind = 0),
    fill_event_id  u32        NOT NULL REFERENCES fill_events(event_id)
);

-- -------------------------------------------------------------------------
-- Derived portfolio metric time series
-- -------------------------------------------------------------------------

CREATE TABLE metric_snapshots
(
    -- The last feed event included in this snapshot. This is the ordering key;
    -- sample_time alone is not unique because multiple events can share a time.
    as_of_orderand                u64        NOT NULL PRIMARY KEY
                                            REFERENCES feed_events(feed_orderand),
    sample_time                   nanosecond NOT NULL,

    -- Monetary values are expressed in BacktestDefinition.valuation_asset_ref.
    -- Ratios are fractions: 0.05 means 5%.
    return_abs                    f32 NOT NULL CHECK (isfinite(return_abs)),
    return_ratio                  f32 NOT NULL CHECK (isfinite(return_ratio)),
    high_watermark_abs            f32 NOT NULL CHECK (isfinite(high_watermark_abs)),
    high_watermark_ratio          f32 NOT NULL CHECK (isfinite(high_watermark_ratio)),
    low_watermark_abs             f32 NOT NULL CHECK (isfinite(low_watermark_abs)),
    low_watermark_ratio           f32 NOT NULL CHECK (isfinite(low_watermark_ratio)),
    max_drawdown_abs              f32 NOT NULL CHECK (isfinite(max_drawdown_abs)),
    max_drawdown_ratio            f32 NOT NULL CHECK (isfinite(max_drawdown_ratio)),
    sharpe_ratio                  f32 NOT NULL CHECK (isfinite(sharpe_ratio)),
    annualized_volatility         f32 NOT NULL CHECK (isfinite(annualized_volatility)),

    -- NULL means the metric is not defined for this prefix. The governing
    -- spec must define its degeneracy convention before making it NOT NULL.
    calmar_ratio                  f32 CHECK (calmar_ratio IS NULL OR isfinite(calmar_ratio)),
    sortino_ratio                 f32 CHECK (sortino_ratio IS NULL OR isfinite(sortino_ratio)),
    turnover_ratio                f32 CHECK (turnover_ratio IS NULL OR isfinite(turnover_ratio)),

    fill_count                    u64 NOT NULL,
    target_position_change_count  u64 NOT NULL,
    total_fees_abs                f32 NOT NULL CHECK (isfinite(total_fees_abs) AND total_fees_abs >= 0),
    volume_valuation_abs          f32 NOT NULL CHECK (isfinite(volume_valuation_abs) AND volume_valuation_abs >= 0),
    pnl_abs                       f32 NOT NULL CHECK (isfinite(pnl_abs)),
    portfolio_value               f32 NOT NULL CHECK (isfinite(portfolio_value)),
    blew_up_at                    nanosecond
);

-- -------------------------------------------------------------------------
-- Read views
-- -------------------------------------------------------------------------

CREATE VIEW final_metrics AS
SELECT *
FROM metric_snapshots
ORDER BY as_of_orderand DESC
LIMIT 1;

CREATE VIEW event_timeline AS
SELECT
    event.event_id,
    event.feed_orderand,
    event.trace_id,
    event.event_kind,
    COALESCE(
        definition.start_time,
        progress.simulated_time,
        fill.event_time,
        position_update.event_time,
        prices.effective_time,
        completed.end_time,
        runtime.event_time,
        target.event_time,
        source.observe_time,
        deposit.event_time,
        fee.event_time
    ) AS timeline_time
FROM feed_events AS event
LEFT JOIN backtest_definition_events AS definition
    ON definition.event_id = event.event_id
LEFT JOIN backtest_metrics_events AS progress
    ON progress.event_id = event.event_id
LEFT JOIN fill_events AS fill
    ON fill.event_id = event.event_id
LEFT JOIN trading_account_position_update_events AS position_update
    ON position_update.event_id = event.event_id
LEFT JOIN prices_update_events AS prices
    ON prices.event_id = event.event_id
LEFT JOIN backtest_job_completed_events AS completed
    ON completed.event_id = event.event_id
LEFT JOIN runtime_events AS runtime
    ON runtime.event_id = event.event_id
LEFT JOIN target_positions_events AS target
    ON target.event_id = event.event_id
LEFT JOIN triggering_source_events AS source
    ON source.event_id = event.event_id
LEFT JOIN deposit_events AS deposit
    ON deposit.event_id = event.event_id
LEFT JOIN fee_events AS fee
    ON fee.event_id = event.event_id;

CREATE VIEW backtest_summary AS
SELECT
    manifest.schema_version,
    manifest.metric_semantics_version,
    manifest.writer_version,
    manifest.artifact_state,
    definition.strategy_id,
    definition.strategy_revision_id,
    definition.backtest_id,
    definition.start_time,
    definition.start_time_wall_clock,
    definition.valuation_asset_ref,
    completed.end_time,
    completed.status,
    completed.reason,
    completed.message,
    manifest.last_feed_orderand
FROM artifact_manifest AS manifest
CROSS JOIN backtest_definition_events AS definition
LEFT JOIN backtest_job_completed_events AS completed
    ON completed.completion_slot = 0
WHERE manifest.manifest_id = 0
  AND definition.definition_slot = 0;
