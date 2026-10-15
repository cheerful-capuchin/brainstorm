---
create_time: 2026-10-19T09:44:45Z
title: "Application server weekend alerts: 404 polling, pool pressure, internal error without a trace"
summary: "D1: P2 accepted (one ALERT per server failure carrying the cause). Round 2 answers: p99 ~1-2 s is workflow ticks/activities waiting on Convex (~220 ms per call), not Postgres; client app reports nothing (no version, trace id, error id). Retry design proposed: SQLSTATE classified in the egress consumer, retry owned by useTx, cause chain to the API code. 677 app-server ALERT lines 2026-10-16..19: every 4xx on ERROR_CODE_TO_REPORT pages (NotFound/InvalidArgument/FailedPrecondition \"release period only\"); 404s on strt_02ZZZZZZZ0400 were 5 bursts of 3 requests, not polling; pool_pressure fires on every BEGIN while any caller waits (193 lines), triggered by ~1,000 execute calls in 5 s via realtime-gateway on 10-16 15:39:57Z (1 instance, concurrency 100, pool 45, db-f1-micro); evt_01M52NXEDJ1E1HJ5G6CETJE86T = StrategyDelete serialization failure (SERIALIZABLE default, no 40001 retry), cause logged under the same trace id; proposals P1-P5"
related_sessions:
  - SESS-00R0CQR
  - SESS-00R0CQV
  - SESS-00QKS30
  - SESS-00Q1C5S
  - SESS-00PYCE2
agents:
  - claude-code:4d6a7ca5-dd04-4c68-820c-98dfd392011a
---

# SESS-00R0BCD: Application server weekend alerts: 404 polling, pool pressure, internal error without a trace

## Trigger (2026-10-19)

Discord alerts from application-server-00017-m8g (structure-web d77e45b4e,
main HEAD, includes #183) over the weekend: `json_handler.response_error`
NOT_FOUND for `getStrategy strt_02ZZZZZZZ0400`; 
`pg_client_egress_consumer.begin.pool_pressure` with pool_total 45,
pool_waiting 42; `json_handler.response_error` INTERNAL for
`execute` (evt_01M52NXEDJ1E1HJ5G6CETJE86T). The user asked:
- 404: does not want to be paged; "polling" a missing strategy is wasteful,
  but unsure how to handle a client that polls a missing resource.
- Pool pressure: how can there be 45 concurrent DB requests? Analyse the
  Cloud Run metrics.
- Internal error: no trace id to follow it; what is up with app-server
  alerts and Discord?

Times in Discord are UTC+2. Trace ids are lowercase ULIDs; the first 10
characters decode to the request time (01m52nxdjajw.. = 2026-10-16
15:39:57.386Z).

## Findings

### Alert volume and severity

- 677 `[ALERT]` lines in application-server stdout 2026-10-16..19: 193
  pool_pressure, ~74 INTERNAL/non-ApiError, 16 auth
  (`signature_mismatch`, `refresh_token.replay_attack`), ~394 client errors
  (NOT_FOUND, INVALID_ARGUMENT, FAILED_PRECONDITION such as deleteStrategy
  "has backtests").
- `packages/api/src/lib/api.ts` `ERROR_CODE_TO_REPORT` includes
  InvalidArgument, FailedPrecondition, NotFound under
  `/* For the release period only */`. `publishHandlerAlert` always uses
  `argus.alert` (severity ALERT); AlertSink maps ALERT to tag `critical`.
  There is no code -> severity mapping.
- Pipeline: argus -> AlertSink (minSeverity ERROR, 1 s batches) ->
  AlertsFeedMessage on Topic.Feeds -> `notify-gw-alerts-feed-sub` ->
  notify-gw -> Discord. ERROR entries go to Discord too.
- App-server logs reach Cloud Logging as text lines, not JSON; multi-line
  stacks become one log entry per stack frame. (SESS-00QKS30 D7 said all
  services log JSON lines; the app-server does not yet.)

### 404 on strt_02ZZZZZZZ0400

- Not polling. 13 GET requests since 10-16, in bursts of three within
  ~1.5 s (execute StrategyGet, then GET twice) at 2026-10-18 09:06, 11:20,
  11:28, 11:33, 14:40 UTC; user agent `node`, via Cloudflare IPs. Each
  answered in 5-8 ms (one indexed read, no transaction). The id looks made
  up (`02ZZZZZZZ`); the same client then loads real strategy
  strt_02WH4STWG0400 spec GUIs.
- stxr-client-app: `refreshStrategy` stops on 404, `resolveStrategy` has no
  negative cache (agent code read, not verified at runtime).

### Pool pressure

- `node-pg-egress-consumer.ts` `begin()` alerts on every successful BEGIN
  while `pool.waitingCount > 0`; no duration or rate limit. 146 lines in
  ~3 s on 10-16.
- Infra: Cloud SQL `db-f1-micro`, `max_connections` 50, pool 45, Cloud Run
  max 1 instance, concurrency 100. One pool serves plain queries and
  transactions; a transaction pins a connection from BEGIN to COMMIT.
- 2026-10-16: ~20 execute/s from 15:15 to 15:39:50 UTC (23k requests,
  remote IP 0.0.0.0, no user agent = realtime-gateway websocket clients;
  164 `client.connected` 15:00-15:19); 173 `strategies.v1.created` events
  for parent 02A7K4B980400 in the last few minutes; then ~1,000 execute
  calls between 15:39:57 and 15:40:02 (293 in the busiest second). All 44
  failures were StrategyDelete. Request p99 1.0-1.5 s, instance CPU p99
  29%, Cloud SQL CPU 16%, Cloud Run max concurrency p99 94. Queueing for
  connections, not a leak or slow queries.
- 2026-10-18 09:00-10:00 UTC: 17k requests, 44 pool_pressure. 8.5k
  execute plus `node` client GETs: each of ~50 trading accounts fetched 54
  times between 09:02 and 09:27, in groups of five ~2.4 s apart every
  1-2 min; also many revision/backtest reads. Cloud SQL backends peaked
  at 47 (hourly max).
- Agent's code read flagged `StrategiesService.start`/`stopIdempotent`
  calling `internalClient.api.workflows.start` inside `useTx` (holds a
  connection across an HTTP call); not involved in these two bursts.

### evt_01M52NXEDJ1E1HJ5G6CETJE86T (INTERNAL on execute)

- error_id equals the trace id by construction (`NewInternalError`
  defaults to `ctx.traceID`). Logs under trace_id=01m52nxdjajw00pbqx0qxvgfmb:
  `[ERROR] consume_failure.to_api_error.internal service=Strategies;
  method=StrategyDelete;cause=strategies_service.delete_strategy.delete_err
  ... PG_CLIENT_QUERY_ERR ... could not serialize access due to read/write
  dependencies among transactions`.
- Query: `resource.labels.service_name="application-server" AND
  textPayload:"trace_id=<id>"`.
- Every `useTx` defaults to SERIALIZABLE (`IsolationLevel_nil`); there is
  no retry on SQLSTATE 40001, and the failure maps to INTERNAL. 37
  delete_err + 7 commit (tx_err) failures in the 10-16 burst, 1
  StrategyCreate.
- The ALERT carries only "Internal Error ... error id"; the cause is a
  separate ERROR message (also on Discord) with a message string and no
  stack. The ALERT's stack points at `NewInternalError`.

## Proposals (not decided)

- P1: 4xx codes off `ERROR_CODE_TO_REPORT` (NotFound, InvalidArgument,
  FailedPrecondition); log at INFO/NOTICE with handler and code. A client
  reading a missing resource gets a cheap 404; floods are a per-principal
  rate-limit concern, not a 404 concern.
- P2: one ALERT per server failure that carries the cause (service,
  method, cause, stack) instead of a context-free ALERT plus an ERROR.
- P3: bounded retry of a SERIALIZABLE transaction on 40001 (and 40P01)
  in `PgClient.useTx`; after the last attempt answer ABORTED/UNAVAILABLE,
  not INTERNAL.
- P4: pool pressure as a measurement: record connection wait time; alert
  only when waiting persists (e.g. waiters for > 30 s or acquire wait >
  N s), at most once per window.
- P5: find the `node` client behind the Sunday re-reads and the Friday
  websocket burst (create ~170 strategies then delete them at once);
  per-principal concurrency limit on execute.
- Also: application-server JSON log lines (SESS-00QKS30 D7).

## Round 2 (2026-10-19)

User answers to P1-P5: P2 agreed (D1). Questions:
1. Without 4xx alerts, how do we learn about bugs in our code during the
   beta? Alerts on the client?
3. How to model the serialization retry so it is generic and reusable?
4. Which connection (pool pressure)?
5. Why was p99 1 s; the database?

### Decisions

- D1 (user): P2, one ALERT per server failure that carries the cause.

### Findings

- p99: Cloud Run hourly p99 1.0-2.4 s comes from a few internal routes,
  not user traffic or Postgres. 10-16 13:00-16:00 UTC: execute n=28,141,
  p50 5 ms, p99 92 ms; `POST /workflows:tick` n=210, p50 1,324 ms (205 >
  1 s); activities:complete p50 649 ms; workflows:start p50 715 ms;
  backtest create ~2.3 s. 10-18 09:00-16:00: tick p50 1,306 ms, p99
  2,824 ms; execute p99 327 ms. One tick (trace 01m57qwfykdbxymh2x28xh75sa):
  +220 ms getWorkflow, +220 ms to processing_commands, +900 ms to done;
  each step is a sequential Convex call (`workflows-service.ts` tick:
  getWorkflow, verifyWorkflowState, incrementStepAttempt,
  addRunningActivity, scheduleActivityRun, markActivityDispatched).
  Convex deployment resolute-marlin-26 (.convex.site) is behind Cloudflare;
  region not confirmed, ~220 ms per call fits Tokyo -> US. During the
  10-16 burst execute p99 was 406 ms, max 1.05 s (connection queue).
- Client app (stxr-client-app): no telemetry or error reporting to the
  backend; no version, client-name or trace headers (User-Agent is Node's
  default `node`); `stxrApiErrorMessage` drops the code and ErrorInfo, so
  error ids never reach the user; HTTP only (no realtime-gateway), 15 s
  timeout, 8 requests in flight; no HTTP retry helper. Per-id
  `GET /trading-accounts/{id}` from `resolveDeployment -> getAccounts` and
  the deployment editor's per-account `getAccount`. So the 10-16 websocket
  burst was not the client app (SDK or a script through realtime-gateway).
- `fmt.errorf` returns `new Error(sprintf(..))`: no cause chain. Services
  wrap tx and query errors as strings, so a serialization failure reaches
  `ConsumeFailure.toApiError` as a plain Error -> INTERNAL. The egress
  consumer turns node-pg errors into ApiError with the message only; the
  SQLSTATE is lost. ts-core ErrorCode has no ABORTED; UNAVAILABLE is
  documented as "can be retried with a backoff". 102 `useTx` call sites;
  `StrategiesService.start`/`stopIdempotent` call workflows.start inside
  the transaction (not safe to re-run).

### Proposals round 2 (not decided)

- Q1: classify 4xx: contract violations (`rejected`/`adapter` stage
  INVALID_ARGUMENT, response decode failures in the client) mean our code
  is wrong; NOT_FOUND/FAILED_PRECONDITION are domain answers. Log every
  4xx as one NOTICE event with handler, code, ErrorInfo reason, principal;
  log-based metric by (handler, code, reason); alert on contract
  violations and on rate jumps; daily digest of the rest. Client: send
  `x-client-version` and an `x-trace-id` per user action, show the error
  id, and report only what the server cannot see (decode failures,
  unexpected exceptions, swallowed `allSettled` failures) through an
  app-server endpoint into the same argus pipeline, rate limited.
- Q3: SQLSTATE classified once in the egress consumer into a closed set
  (serialization_failure 40001, deadlock_detected 40P01, other); the
  consumer remembers per transaction that it was aborted by a conflict and
  returns that on rollback/commit; `useTx` owns a bounded retry
  (TransactionOptions.retry, default 3 attempts for SERIALIZABLE, jittered
  delay from the runtime clock) based on that verdict, independent of how
  the callback wrapped the error; exhausted -> PostgresError.TxConflict ->
  UNAVAILABLE via a cause chain (`fmt.wrapf`/Error.cause walked by
  ConsumeFailure). Callbacks must not have side effects outside the
  transaction; start/stopIdempotent move workflows.start after commit
  (also stops holding a connection across HTTP).
- Q4: the Postgres connection of the app-server node-pg pool (45). Plain
  `pool.query` calls take from the same pool and are not in `open_txs`.
  Measure acquire wait for both; alert on sustained wait.

## Split (2026-10-19)

The user asked for separate discussions:
- Q1 (how we learn our code is broken during the beta, client alerts):
  SESS-00R0CQR.
- Q3 + Q4 (generic transaction conflict retry, connection pool wait):
  SESS-00R0CQV.
