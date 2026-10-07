---
create_time: 2026-10-07T19:09:47Z
title: "Client Backtest Runtime Event Severity Mismatch"
summary: "Recorded the client backtest severity mismatch: its hard-coded 1–4 mapping rejects valid telemetry severity 5 (error) in the DuckDB artifact."
related_sessions: []
---

# SESS-00Q1QZV: Client Backtest Runtime Event Severity Mismatch

## Finding

Opening backtest `bt_1ETBFNFNBJ55R` fails with `Unknown runtime-event severity '5'.` The failure is in the client-side result reader, not the backtest list endpoint.

The client downloads the result DuckDB artifact through `ApiBacktestArtifactProvider` using `backtests.downloadResults` with the backtest, strategy, and revision IDs. Its `runtime_events` query selects `severity` from `feed.runtime_events`; `runtimeEventRow` passes that numeric column to the `severity` mapper.

The mapper accepts only `1 => debug`, `2 => info`, `3 => warning`, and `4 => error`, then throws for other values. This mapping was hard-coded to satisfy the UI `RuntimeEventRow` union (`debug | info | warning | error`); it did not come from the API contract.

The artifact schema documents that `feed.runtime_events.severity` stores `telemetry::Severity` discriminant divided by 100: `0 default`, `1 debug`, `2 info`, `3 notice`, `4 warning`, `5 error`, `6 critical`, `7 alert`, `8 emergency`. Therefore `5` is a valid error severity. The mapper's assumed numeric sequence is out of sync with the artifact contract, and omitting `notice` shifts the mappings from `3` onward.

## Relevant code

- `stxr-client-app/src/vs/platform/stxrBacktest/electron-main/stxrBacktestArtifactProvider.ts`: downloads/caches the DuckDB result artifact.
- `stxr-client-app/src/vs/platform/stxrBacktest/node/backtest-view-queries.ts`: selects `severity` from the `runtime_events` view.
- `stxr-client-app/src/vs/platform/stxrBacktest/node/duckdb-backtest-view-adapter.ts`: converts the numeric column and throws for values outside 1–4.
- `stxr-ui/packages/ui/src/analytics/strategy-performance/StrategyPerformance.types.ts`: UI's four-value `RuntimeEventRow.severity` union that the mapper targets.
- `backtest-post-processor/src/egress/duckdb_artifact/schema.sql`: artifact's authoritative severity encoding.
