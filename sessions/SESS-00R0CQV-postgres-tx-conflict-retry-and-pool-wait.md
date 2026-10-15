---
create_time: 2026-10-19T10:07:55Z
title: "Postgres transaction conflict retry and connection pool wait"
summary: "Open discussion, no decisions. Split from SESS-00R0BCD Q3+Q4. Every useTx is SERIALIZABLE with no retry; 44 StrategyDelete serialization failures became INTERNAL on 2026-10-16. Proposed: SQLSTATE classified in the egress consumer, per-tx conflict verdict, bounded retry owned by useTx, TxConflict -> UNAVAILABLE via a cause chain; callbacks must be side-effect free (start/stopIdempotent call workflows.start inside the tx). Pool pressure alert fires on every BEGIN while anyone waits; proposal: measure connection acquire wait, alert on sustained wait. Open Q1-Q10."
related_sessions:
  - SESS-00R0BCD
  - SESS-00PM9HX
agents:
  - claude-code:4d6a7ca5-dd04-4c68-820c-98dfd392011a
---

# SESS-00R0CQV: Postgres transaction conflict retry and connection pool wait

Split from SESS-00R0BCD (application-server weekend alerts), questions 3
and 4. That session holds the full incident; the evidence needed here is
copied below. The user asked for a separate discussion about the approach.

## The user's questions (2026-10-19)

- "How would you model it [the retry on serialization failures] in a way
  that is generic and reusable?"
- About the pool pressure proposal ("measure how long requests wait for a
  connection"): "which connection?"

## Incident evidence (2026-10-16, UTC)

- application-server-00017-m8g, structure-web d77e45b4e (= main).
- 15:15-15:39:50: ~20 execute calls/s through realtime-gateway (websocket
  clients, remote IP 0.0.0.0, no user agent; not the client app, which is
  HTTP only). 173 `stxr.trading.strategies.v1.created` events for parent
  02A7K4B980400 in the last minutes.
- 15:39:57-15:40:02: ~1,000 execute calls in 5 s (293 in the busiest
  second). 44 StrategyDelete answered INTERNAL (37
  `strategies_service.delete_strategy.delete_err` = query failed, 7
  `tx_err` = commit failed) plus 1 StrategyCreate `tx_err`, all with
  `could not serialize access due to read/write dependencies among
  transactions` (SQLSTATE 40001). Example trace 01m52nxdjajw00pbqx0qxvgfmb.
- 146 `pg_client_egress_consumer.begin.pool_pressure` ALERT lines in ~3 s,
  e.g. `open_txs=7 pool_total=45 pool_idle=0 pool_waiting=42`; early lines
  show `open_txs=1..5` with 45 connections busy (plain queries hold most of
  them). Also 44 lines on 2026-10-18 09:12-09:25 and 3 on 10-16 14:xx with
  `pool_total=10` (before the pool grew / a different revision config).
- Request latency during the burst: execute p99 406 ms, max 1.05 s.
  Instance CPU p99 29%, Cloud SQL CPU max 16%, Cloud Run max concurrency
  p99 94. Queueing for connections, not slow queries or a leak.
- The service-wide 1-2 s p99 seen in Cloud Run is a different thing:
  workflow ticks/activities waiting on sequential Convex calls (~220 ms
  each); see SESS-00R0BCD round 2. Not part of this session.

## Setup

- infra `infra/services/application-server/db.ts`: Cloud SQL Postgres 18,
  `db-f1-micro` (shared core), `MAX_CONNECTIONS = 50`,
  `POOL_MAX_CONNECTIONS = 45`. `application-server.ts`: max 1 instance
  (vertical scaling on purpose), `maxInstanceRequestConcurrency: 100`,
  config `postgres_max_connections`. `db-alerts.ts` already has Cloud SQL
  policies: down 5 min, `over 40 of 50 connections for 5 minutes`, CPU >
  90% for 15 min, memory, disk.
- structure-web `packages/api/src/run.ts` ~211: one node-pg `Pool`
  (`max: maxConnections`, default 10 in `rt-config.ts`), no
  `connectionTimeoutMillis` set (node-pg default 0 = wait forever).
  drizzle (`drizzleNodePg({ client: pool })`) and the egress consumer
  (`NodePgEgressConsumer.make({ pool, txs })`) share it.

## How database access works (structure-web packages/api/src/app-db/client)

- `client.ts` `PgClient`: services never touch the pool. They build drizzle
  queries and send IPC requests through the runtime (`rt.execute`):
  `BeginTx`, `Query`, `CommitTx`, `RollbackTx`. Transaction ids come from
  `client.nextTxID()`; `TransactionID_nil` = no transaction.
- `node-pg-egress-consumer.ts` executes them:
  - `begin()` (~135-170): `pool.connect()`, `BEGIN`, `SET TRANSACTION
    ISOLATION LEVEL ..`, stores the PoolClient in `data.txs`; then the
    pool_pressure ALERT whenever `pool.waitingCount > 0` (no duration, no
    rate limit).
  - query (~185-203): nil tx -> `pool.query(query)` (borrows and returns a
    connection internally, invisible to `open_txs`); otherwise
    `queryInTx` on the pinned client.
  - errors (~317-345): `queryError`/`commitError`/`rollbackError` build
    `ApiError(Internal, .., ErrorInfo(PG_CLIENT_QUERY_ERR | COMMIT_ERR |
    ROLLBACK_ERR, {tx_id, error: String(error)}))`. The node-pg
    `DatabaseError.code` (SQLSTATE) is dropped; only the message text
    survives.
  - `pglite-egress-consumer.ts` is the in-process twin used in tests and
    must keep the same semantics.
- `PgClient.useTx(client, rt, cb, userData, options)` (`client.ts`
  ~234-320): BeginTx (isolation `options.isolationLevel ??
  IsolationLevel_nil()` = SERIALIZABLE), run `cb(tx, userData, signal)`;
  if cb returns err -> RollbackTx, return `ok(cbResult)`; if cb throws ->
  RollbackTx, `err(PostgresError.Unknown)`; else CommitTx, commit failure
  -> `err(PostgresError.TxError{error: string})`. No retry anywhere.
- `PostgresError` (ErrorFamily, `client.ts` ~22): None, QueryError,
  InvalidRow, SerializeFiltersErr, TxError, Unknown; payloads are strings.
- 102 `useTx(` call sites in packages/api/src (strategies 9 files, auth 4,
  trading-accounts 3, strategy-deployments 3, users 2, backtests 2,
  transfer-intents 1, delegate-accounts 1). No call site overrides the
  isolation level: everything is SERIALIZABLE.

## Why a serialization failure becomes INTERNAL

1. The egress consumer loses the SQLSTATE (message string only).
2. Inside the callback the query error is wrapped by the service:
   `fmt.errorf("strategies_service.delete_strategy.delete_err err=%s;",
   deleted.error)` (`strategies/strategies-service.ts` ~1735). `fmt.errorf`
   (ts-core `packages/fmt/src/mod.ts` ~192) is `new Error(sprintf(..))`:
   no cause chain.
3. `useTx` sees `cbResult.isErr()`, rolls back and returns `ok(cbResult)`;
   it cannot tell a conflict from a business refusal.
4. `ConsumeFailure.toApiError` (`execute/consume-failure.ts`) gets a plain
   Error -> `argus.error("consume_failure.to_api_error.internal")` +
   `NewInternalError()`.
- ts-core `ErrorCode` (`packages/core/src/api/error.ts` ~250-290) has no
  ABORTED; `Unavailable` is documented "can be retried with a backoff"
  (HTTP 503). `TooManyRequests` exists.

## Side effects inside transactions (blocks blind re-runs)

- `StrategiesService.start` (`strategies-service.ts` ~1463) and
  `stopIdempotent` (~1968-1982) call
  `data.internalClient.api.workflows.start(..)` (HTTP to the backend, which
  writes to Convex) inside the `useTx` callback. A retry would start the
  workflow twice; it also holds a pooled connection across an HTTP call.
- Not audited: the other ~100 call sites for HTTP calls, NATS publishes,
  `argus.event` domain events, id generation with side effects, or reads of
  mutable process state inside the callback. Domain events seen so far are
  emitted after the transaction (e.g. deleteStrategy, unarchive).

## Proposal given to the user (not decided)

Put each decision where the knowledge is:
- Egress consumer classifies once: SQLSTATE -> closed set
  (`serialization_failure` 40001, `deadlock_detected` 40P01, `other`),
  carried on the wire as a typed field or ErrorInfo reason, not a string.
  It also records per transaction that a conflict aborted it (Postgres
  puts the tx into the aborted state; later statements fail with 25P02)
  and returns that verdict in the Rollback/Commit response.
- `useTx` owns a bounded retry based on that verdict, independent of how
  the callback wrapped its error (so no call-site changes):

  ```ts
  export type TransactionOptions = {
      isolationLevel?: IsolationLevel;
      signal?: AbortSignal;
      retry?: TxRetry; // default for SERIALIZABLE: { kind: "on_conflict", maxAttempts: 3 }
  };
  // for (attempt < maxAttempts) { begin; cb; commit/rollback -> verdict;
  //   if verdict != conflict break; wait jittered delay from the runtime clock }
  ```
- Exhausted -> new `PostgresError.TxConflict`; `ConsumeFailure` (and
  `jsonHandler`) follow a real cause chain (explicit `fmt.wrapf(cause,
  pattern, ..)` or `Error.cause`) and answer UNAVAILABLE instead of
  INTERNAL.
- Rule: callbacks must not act outside the transaction. Move
  `workflows.start` after commit in start/stopIdempotent (also stops
  holding a connection over HTTP), audit the rest before enabling retry by
  default.

## Pool wait (question 4)

- "The connection" = a Postgres connection from the application-server's
  node-pg pool (45). Every DB call borrows one: a transaction from BEGIN to
  COMMIT/ROLLBACK, a plain `pool.query` only while it runs. "Waiting" =
  `pool.connect()` (explicit in begin, implicit in pool.query) queued
  because all 45 are out.
- Proposal: measure acquire wait for both paths (explicit connect +
  release around plain queries so the wait is observable), emit it as a
  metric/histogram (or a NOTICE event above a floor), and alert only when
  the wait stays high (e.g. p99 > 1 s for 5 min, or any waiter for > 30 s),
  at most once per window. Replace the per-BEGIN ALERT.

## Open questions for the discussion

- Q1. Retry on by default for every SERIALIZABLE `useTx`, or opt-in per
  call site until the side-effect audit is done?
- Q2. How to make "no side effects in the callback" hold by construction
  rather than by convention (callback only receives a tx-scoped handle; an
  outbox for events/HTTP; lint rule)?
- Q3. Where the conflict verdict lives: egress-consumer tx state returned
  on rollback/commit, or a typed error kind the callback must propagate?
- Q4. Error code after retries: UNAVAILABLE (exists), or add ABORTED to
  ts-core (closed set change, load idiomatic-code.md and
  no-undefined-behavior.md first) with HTTP 409?
- Q5. Cause chains: change `fmt.errorf` to keep Error args as `cause`
  (implicit, every call site at once) or add an explicit `fmt.wrapf`
  (Go `%w` style, call sites opt in)? This also serves SESS-00R0BCD D1
  (ALERT carries the cause).
- Q6. Is SERIALIZABLE the right default? Which operations need it
  (balance/accounting, uniqueness checks) and which could run READ
  COMMITTED with explicit row locks (`LockStrength` exists in client.ts)?
  Why did concurrent deletes of different strategies conflict (predicate
  locks from a scan by user id, missing index)? Worth an EXPLAIN of
  `StrategyRepository.deleteStrategy`.
- Q7. Backoff: attempts, delay range, and whether the runtime's
  deterministic clock/timers must be used (replay, tests with pglite).
- Q8. Pool sizing: 45 connections on a db-f1-micro with one instance at
  concurrency 100. Add `connectionTimeoutMillis` and answer
  UNAVAILABLE/TOO_MANY_REQUESTS instead of queueing forever? Per-principal
  concurrency limit on execute (a single client sent ~1,000 calls in 5 s)?
- Q9. Pool wait metric transport: Cloud Monitoring custom metric, log-based
  metric from a NOTICE event, or the monitoring SDK (SESS-00QKRBE)?
- Q10. Rust services inside the application server (SESS-00PM9HX) send
  queries through the same egress; the retry and classification must live
  where both TS and Rust callers get them.
