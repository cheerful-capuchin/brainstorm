---
create_time: 2026-10-15T11:13:34Z
title: "Backtest run timeout chosen per backtest, 1 day by default"
summary: "PRs: ts-core#16, strategy-core#18, application-server-client#17 (needs regen), structure-web#185, infra#37. Backtest bt_02WAQZSE80400 failed (alert 0.odu7kumvg7f4); user asked for a per-backtest timeout, default 1 day (D1). D6 (supersedes D2-D4 storage/naming): timeout lives in a separate BacktestJobConfiguration (job environment, not the strategy binary): strategy-core Backtest.BacktestJobConfiguration { timeout } on Backtest.T, Avro structure.app_db.BacktestJobConfiguration, column backtests.job_configuration (migration fills old rows with 1 day), API job_configuration.timeout ISO 8601 (max 7 days), config backtest_default_job_timeout_s. Workflow carries cloudrun_job_timeout_s -> template timeout_s; watchdog jobTimeout assert removed (D5). Uncommitted in strategy-core, structure-web, infra (alerts-through-logs), application-server-client (hand-patched internal client). Front end not done."
related_sessions:
  - SESS-00Q1C5S
  - SESS-00PXT2F
  - SESS-00QKS30
agents:
  - claude-code:50b36073-7701-490d-807d-256f873e7cc7
---

# SESS-00QNZ2Y: Backtest run timeout chosen per backtest, 1 day by default

## Trigger (2026-10-15)

Alert `backtest-failed` (Cloud Monitoring incident `0.odu7kumvg7f4`, condition
"a backtest failed", application-server revision `application-server-00014-x56`,
asia-northeast1): backtest `bt_02WAQZSE80400` of strategy `strt_02VXXHM080400`,
user `02AJE7QH00400`. The user pointed at `BacktestService.create` in
`structure-web/packages/api/src/backtests/backtests-service.ts` and asked to let
the user choose the backtest run timeout, with 1 day as the default.

The cause was not confirmed: `gcloud logging read` for the job
`...-bt-02waqzse80400` returned nothing. The user's request implies the
backtest ran into the one hour job timeout.

## State before

- One server-wide `backtest_timeout_s: 3600` (api config + infra
  `infra/services/application-server/application-server.ts`) set the Cloud Run
  job task timeout for every backtest, in the job template built by
  `BacktestService.buildCloudRunJobTemplate` (internal endpoint the activity
  worker calls in `trigger_job`). The runner got `--run-timeout-ms` 60 s less
  (`RUNNER_TIMEOUT_MARGIN_S`).
- The stall watchdog (`failStalledRuns`, `STALLED_RUN_AFTER` 3 h, ISS-0BWVR)
  asserted that its limit exceeds the job timeout.

## Decisions

### D1: The user picks the run timeout per backtest; default 1 day

User's request. The default stays a server setting.

### D2: Public field `run_timeout`, ISO 8601 duration

- `CreateBacktestBody.run_timeout`, optional, ISO 8601 duration of days, hours,
  minutes and whole seconds (`P1D`, `PT6H`), following the API RFC duration
  rule. Parsed by the same parser as execution delays (renamed
  `parseDuration`/`formatDuration` in `backtest-http.ts`) plus a whole-seconds
  check.
- Bounds: longer than 60 s (runner margin) and at most 7 days (Cloud Run job
  task limit, 168 h), `BacktestService.resolveRunTimeout` /
  `MAX_RUN_TIMEOUT`. Violations are `InvalidArgument` on field `run_timeout`.
- `BacktestRepresentation.run_timeout` serves it back in seconds form
  (`PT86400S`).
- NATS create (`backtests-adapter.ts`) has no wire field; it gets the default.

### D3 (superseded by D6): Stored in `strategy_config`, not a column

`schema.ts` says a new run setting is a field of `StrategyConfig`, not a column
(DEC-0C6J2 Avro blobs). Added `run_timeout_s` (long, default 86400) to the
`StrategyConfig` Avro schema and `runTimeout: Second` to `StrategyConfig.T`.
Blobs written before the field read back with 1 day, so re-running an old
failed backtest (such as `bt_02WAQZSE80400`) gets the longer timeout. A test
encodes with the previous schema and checks the default.

### D4: Carried through the workflow; global setting becomes the default

`BacktestInput.cloudrun_job_timeout_s` (from the stored config) ->
`TriggerJobIn.cloudrun_job_timeout_s` -> `BuildCloudRunJobTemplateRequest.timeout_s`
-> job `timeout` and runner `--run-timeout-ms`. Config key renamed
`backtest_timeout_s` -> `backtest_default_run_timeout_s` (86400, bounds
(60, 604800]) in the api config and infra. No backwards compatibility: an
in-flight workflow whose input lacks the field fails at deploy and the
watchdog marks it failed.

### D5: Watchdog no longer tied to the job timeout

Each `poll_execution` commit updates the backtest's `update_time`, so a long
run is not stalled. Removed `FailStalledRunsArgs.jobTimeout` and its assertion;
comment explains the polling.

### D6: A separate `BacktestJobConfiguration`, own column, own Avro type

User reviewed D3 and rejected it: the timeout has no relation to the binary
being executed, only to the environment it runs in, so it does not belong in
`StrategyConfig`. They asked for a separate `BacktestJobConfiguration`, a new
column, a new Avro schema and new types in strategy-core.

- strategy-core: `Backtest.BacktestJobConfiguration` `{ timeout: Second }`
  (positive whole seconds) and `jobConfiguration` on `Backtest.T`. Bounds stay
  in structure-web: the 60 s runner margin and the 7 day Cloud Run limit belong
  to the service that runs the job.
- app-db: Avro `structure.app_db.BacktestJobConfiguration` `{ timeout_s: long }`
  (fingerprint d123d505ba409ff2), column `backtests.job_configuration`
  (schema.ts comment: strategy_config = settings of the binary,
  job_configuration = settings of the job). Migration
  `20261015112920_backtest_job_configuration` adds the column with a temporary
  default of the encoded `{ timeout_s: 86400 }` and drops it, so existing
  backtests rerun with 1 day; a test decodes the literal. Debug view shows its
  fingerprint.
- `StrategyConfig` and its Avro schema are back to before (no `run_timeout_s`).
- api: `CreateRequest.jobConfiguration` (`JobConfigurationRequest`, every value
  optional), `resolveJobConfiguration` (defaults + bounds, field
  `job_configuration.timeout`), `Config.defaultJobConfiguration`,
  `MAX_JOB_TIMEOUT`. HTTP `job_configuration: { timeout }` on create
  (`BacktestJobConfiguration`) and on the representation
  (`BacktestJobConfigurationRepresentation`, `PT86400S` form). Config key
  `backtest_default_job_timeout_s` (api yaml + infra).
- Workflow and template contract unchanged from D4:
  `cloudrun_job_timeout_s` from `backtest.jobConfiguration.timeout`.

### D7: One ISO 8601 duration parser, in ts-core

The user asked why `backtest-http.ts` had its own duration parser instead of
`parseDuration` in ts-core (`packages/core/src/lib/time.ts`). It was written in
structure-web fcc402776 (cheerful-capuchin, 2026-09-26) and changed in
82cb17b7b (grumpy-gorilla, 2026-09-28); I extended it instead of checking core.
The core parser was unanchored (`abcP1Dxyz` parsed), took `P1DT`, and allowed
a fraction on a non-smallest unit.

User's direction: fix the core parser with table and property tests; keep the
components as written (`years, months, weeks, days, hours, minutes, seconds`)
and add `nanos` as the fraction of a second (like `Timestamp.T`). Rejected
along the way: returning only seconds + nanos.

- `parseDuration` anchored; `T` needs a time component; fraction only on the
  smallest time unit, up to 9 digits; a fraction of an hour or minute is
  spread exactly into the smaller units (`PT1.5H` = 1 h 30 min); counts up to
  `Number.MAX_SAFE_INTEGER`.
- New: `Duration_nil`, `formatDuration` (canonical, round-trips),
  `durationToNanos` (error for years/months: no fixed length),
  `durationFromNanos` (seconds + nanos only). `durationToSeconds` kept (naive).
- Tests: table of valid and rejected texts, properties for format round trip,
  components summing to the span, surrounding text rejected, nanos round trip.
  Removing the anchors makes two of them fail. fast-check 4.7.0 added as a dev
  dependency of `@structure/core`.
- structure-web `backtest-http.ts` uses the core helpers for execution delays
  and the job timeout; its local parser and formatter are gone. Weeks and
  fractional hours/minutes are now accepted for delays too.
- Found: an uncommitted ts-core edit `Second = z.coerce.number().positive()`
  (not mine) makes `Timestamp.nil()` fail `Timestamp.T`; backtest repository
  tests go 8 pass / 11 fail with it.

### D8: backtest-http keeps no duration code of its own

User asked to remove the remaining wrappers (`parseFixedSpan`, `formatSpan`).
Call sites now chain the core `parseDuration`, `durationToNanos`,
`durationFromNanos`, `formatDuration`; core error messages became plain
sentences used as field descriptions. User fixed `Second` as
`z.coerce.number().int()` and set the timeout to `Second.positive()`. After the
user rebased data-feed-definitions `feed-catalog-v2` onto main, the HTTP and
adapter tests load: the old "weeks are not supported" delay case (a limit of the
old local parser) became "fraction on days" and "text after the duration";
19/19 pass. Remaining api tsc error: the rebased codecs need
`@structure/structure-api`, not installed yet (root `pnpm install`).

### D9: Committed and in PRs (2026-10-15)

Merge order: ts-core#16 (durations, integer Second) -> strategy-core#18
(BacktestJobConfiguration) -> application-server-client#17 (hand-written
timeout_s; regenerate against structure-web#185 before merging) ->
structure-web#185 (branch backtest-job-configuration from origin/main; the
user's e2e edits stay uncommitted in the working tree). infra#37
(`backtest_default_job_timeout_s: 86400`) as a PR, not a push to main, because
it must deploy with the api release; the line was moved off the
alerts-through-logs working tree. Open: watchdog does not cancel the Cloud Run
execution of a backtest it fails; front end has no input yet.

## Status (2026-10-15, uncommitted)

After D6: strategy-core `ts/src/entities/backtest/backtest.ts` changed on main
(needs a PR, then structure-web's strategy-core pin). structure-web: api,
app-db (+ migration), workflow, activity-worker. Typecheck clean (besides the
pre-existing codec errors). Passing: backtests-service (resolveJobConfiguration
table test), strategy-config, run-lifecycle/repository/archive (Postgres),
debug-schema, app-db avro (migration literal), activity-worker, strategy-core
backtest tests.

Before D6:

- structure-web (main): api, app-db, workflow, activity-worker changes and
  tests. Typecheck passes (besides pre-existing data-feed-definitions codec
  errors in `backtests-adapter.ts`/`strategies-adapter.ts`). Passing:
  strategy-config, backtests-service (new `resolveRunTimeout` table test),
  run-lifecycle/repository/archive (Postgres), activity-worker. Not loadable
  locally: `backtest-http.test.ts`, `backtests-adapter.test.ts` (local codec
  lacks `LoggingTrigger`).
- infra: config key renamed on branch `alerts-through-logs` (working tree).
- application-server-client: `timeout_s` hand-added to the internal
  `types.gen.ts`/`zod.gen.ts`; needs `just generate_client` against a running
  server (also brings `run_timeout` to public/front-end clients).
- Root workspace `pnpm-lock.yaml` was rewritten by an install triggered by
  `pnpm exec` (synced an already-declared codec dependency).

## Open

- Front end (`stxr-client-app`): no `run_timeout` input yet; waits for the
  client regeneration.
- Deploy order: api config + infra key rename must ship together, or the api
  refuses its config.
