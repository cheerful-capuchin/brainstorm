---
create_time: 2026-09-28T16:59:31Z
summary: "Protobuf over realtime-gateway with google.protobuf.Timestamp; add order param; cursor-only in protobuf; breaking rename timestamp->event_time (LogEntry, filter, JSON); Temporal.Instant for nanosecond ISO; no JetStream; log tail polls ClickHouse by orderand cursor (TigerBeetle CDC approach); log queries move to event-gw, application server proxies; new ingestion-sequencer service is the single source of ingestion orderand and watermark; event-gw shards work, not ordering; accounting becomes its own service; client-driven polls over NATS request/reply; list (event_time) and tail (orderand) are separate operations, list returns W as tail_cursor; internal transport NATS; sequencer lease + closed flag in GCS for Cloud Run rollouts; long polling with ingest.committed wake-up signals for every event-gw feed; accounting split deferred, fold stays in event-gw; event-gw serves every client ClickHouse query (L1, L2, D1, D2, D4-D6), D3 moves to Postgres; application server drops ClickHouse (logs and internal positions endpoints); ranges settle only when every table's rows are inserted; D5/D6 paged; internal services call event-gw over NATS, permissions only at the entry point; fold ignores redelivered events (applied, tests pass); event-gw RPC contract drafted in protobuf (u128 correlation_id, Parent, fingerprinted cursors, string log filter parsed in event-gw, ApiError errors, subjects named after data, position_updates rows); code edits paused except the fold fix; list requests take page_size and page_token; one poll operation per entity instead of a bundled Poll; fills, fees, deposits and withdrawals each have their own list and poll; one proto package and service per entity (structure.<entity>.v1, shared structure.query.v1); PollLogs takes buffer_window_ms (GCP TailLogEntries); log requests carry a list of parents (hierarchy and sort key, not access control), no NATS auth; NetContributions kept"
related_sessions: []
---

# SESS-00P9RZK: Client log queries move off the client, into event-gw

Background report: `brainstorm/reports/application-server/2026-09-28-client-side-queries.md`.
It lists the ClickHouse queries the desktop client (`stxr-client-app`) sends
directly today. Log queries: L1 page and L2 tail, in
`stxr-client-app/src/vs/platform/stxrLogs/node/stxrLogsAdapter.ts`. Deployment
queries: D1–D6, in `clickhouseStxrDeploymentDataProvider.ts`. The report also
lists the security problems that make this a blocker for distributing the
client.

## Decisions

### 1. The client uses the existing logs service

The client's log explorer moves onto the existing application server logs
service, `structure-web/packages/api/src/logs/logs-service.ts`
(`LogsService.listUserLogs`). No new logs service is written. The ClickHouse
logs adapter in the client is replaced.

**Superseded by decision 11 (2026-09-29):** log queries move to event-gw; the
application server only proxies them.

### 2. Responses are protobuf over the realtime gateway

Log responses to the client are sent as protobuf through the realtime gateway.

- Timestamps in these responses use `google.protobuf.Timestamp` (seconds +
  nanos).
- This supplies the nanosecond precision the client needs. The current JSON
  response only carries a millisecond ISO string, from `Timestamp.toISO` in
  `ts-core/packages/core/src/lib/time.ts:134`. The deployment Logs table sorts
  and keys rows by nanoseconds.
- The JSON HTTP mapping of the same timestamp was still an open question when
  this was recorded (see Open questions).

### 3. The logs contract gains an `order` parameter

The logs service contract is updated with an ordering parameter (ascending or
descending).

- Today the server only returns newest first: `ORDER BY event_time DESC,
  event_id ASC` in `logs-repository.ts`.
- Two client callers need ascending order:
  - Log Explorer "load more" (`stxrLogsEditor.tsx:92`);
  - the agent platform `platform.logs.list` option `order: 'asc'`.

### 4. Paging links are JSON-only; protobuf carries the cursor

`next_page_uri` / `previous_page_uri` belong only to the JSON HTTP API. The
protobuf response carries only the cursor.

### 5. `timestamp` is renamed to event time across the logs contract (breaking)

The user chose to break the contract rather than keep a compatibility alias.
The new name matches the ClickHouse column `event_time` on `event_logs`.
Applied 2026-09-28 (uncommitted):

| Where | Old | New |
|---|---|---|
| `domain/ts/domain/src/entities/log-entry/log-entry.ts`, entity field | `LogEntry.T.timestamp` | `eventTime` (camelCase like `eventId`) |
| same file, enum variant | `LogFilter.FilterableProperty.Timestamp` | `EventTime` |
| same file, filter property string (user-facing) | `timestamp` | `event_time` |
| `structure-web/packages/api/src/logs/logs-http.ts`, JSON field | `timestamp` | `event_time` |
| `logs-repository.ts`, row alias and cursor key | `timestamp_nanos`, `timestampNanos` | `event_time_nanos`, `eventTimeNanos` |
| `logs-repository.ts`, cursor byte layout | | unchanged |

Also updated: `log-entry.test.ts` and `logs-repository.test.ts`.

Not yet done: the OpenAPI specs in `application-server-client`
(`openapi.json`) and the generated TS client still say `timestamp`.
Regenerate them from a running server with `just` in `application-server-client`.

### 6. Deployments get a strategy deployment entity

A strategy deployment entity will be added. It will carry the deployment's
identity and start times. This replaces two things in the client:

- the id the client makes up (`dep_` + an FNV hash of strategy id and
  revision id, `stxrDeploymentIdProvider.ts`);
- query D3 (`readStartTimes`), which scans `event_logs` properties across all
  users.

### 7. ISO date strings with nanosecond precision use `Temporal.Instant`

User decision (2026-09-28): ISO date strings that need nanosecond precision
are handled with `Temporal.Instant`, not `Date` (`Date` keeps only
milliseconds). This resolves the earlier open question about the JSON mapping.

Runtime support checked 2026-09-28:

| Runtime | `Temporal` global |
|---|---|
| Bun 1.4.2 (structure-web API) | yes |
| Deno 2.8.3 | yes |
| Electron 42.7.1 main process (V8 14.8, the client) | yes |
| Node 24.13 | no |

TypeScript 5.9.2, used by every TS package here, has no Temporal types.
TypeScript 6.0 ships `lib.esnext.temporal`.

Applied 2026-09-28 (uncommitted), in `structure-web/packages/api` only.
ts-core is not changed, because other packages type-check it with
TypeScript 5.9.

| File | Change |
|---|---|
| `src/temporal.d.ts` | Declares the subset of `Temporal.Instant` that is used. Delete it on the move to TypeScript 6. |
| `src/lib/iso-instant.ts` | `IsoInstant.fromTimestamp`: UTC with 9 fractional digits, the protobuf JSON form of `google.protobuf.Timestamp`. The fixed 9 digits were the agent's choice. `IsoInstant.parseNanos`: RFC 3339 with an offset, keeping nanoseconds. |
| `logs-http.ts` | `event_time` is written with `IsoInstant.fromTimestamp`. |
| `logs-repository.ts` | The `event_time` filter literal is parsed with `IsoInstant.parseNanos`. |

Behaviour change in the filter: a date-only literal, or a date-time without
an offset, is now rejected. `Date` used to accept these and read them in the
server's local time zone.

Tests: table tests in `logs-repository.test.ts`, plus
`src/lib/iso-instant.test.ts` (table test for the 9-digit output and a
fast-check round-trip property).

### 8. The client cannot detect missed log rows from `ingestion_orderand`

User constraint (2026-09-28): a client subscription receives only the rows
that match its filter, not every row. Gaps in `ingestion_orderand` between the
rows a client receives are therefore normal. The client cannot use them to
tell whether it missed an event. Any log-feed design must not rely on the
client detecting gaps.

Met by decision 10 (2026-09-29): the client holds a cursor and asks for rows
after it, so it never has to detect gaps in the rows it receives.

### 8a. `ingestion_orderand` is not a gap-detection or resume position

User constraint (2026-09-28): there may be several event-gw instances, and
they will not share the orderand. Values can differ per feed and per
instance, so the orderand cannot detect gaps. It also cannot serve as a
resume position ("everything after P") on any hop. This applies to the
event-gw to application server hop too, which the agent had proposed.

Confirmed in code: `event-gw/crates/event-gw/src/orderand.rs:1-9`. The
orderand is "the order in which this gateway received events", built from
seconds since 2026-01-01 plus a counter, and "assumes one source per gateway".

**Superseded by decisions 12 and 13 (2026-09-29):** every orderand will come
from one service, the `ingestion-sequencer`, whatever the number of event-gw
instances. Read up to the watermark W, the orderand is then a valid resume
position.

### 8b. No JetStream for the log feed

User decision (2026-09-29): JetStream is rejected. It adds more logic to
handling a massive number of events. This rejects the agent's 2026-09-28
suggestion to put JetStream behind the gateway.

### 8c. The goal: stream without gaps, or detect a gap and reconcile

User decision (2026-09-29): the log feed must stream data without gaps. If a
gap does happen, it must be detected and reconciled. The user considers this a
solved problem and wants to use an established pattern rather than invent one.

### 8d. Two boundaries; the transports are not decided

**Settled by decision 17 (2026-09-29):** websocket to the client, NATS inside
the infrastructure.

User decision (2026-09-29):

| Boundary | Transport |
|---|---|
| client ↔ realtime-gateway | websockets first, QUIC later |
| realtime-gateway ↔ application server | websocket, NATS, Zenoh or QUIC; not decided |

### 8e. Gap detection is at the application level, independent of transport

User decision (2026-09-29): the transports provide their own delivery
guarantees. Gap detection must still be built into the application protocol
and must work the same whichever transport is chosen for each boundary.

Decisions 8c and 8e are met by decision 10 (2026-09-29). The reader asks for
"rows after my cursor" and the server answers from committed data, so no row
can be lost between two polls. This works over any transport.

### 9. No further code edits until the log-feed design is decided

User instruction (2026-09-28): "don't edit anything yet, just update the
decisions." Record decisions only. Do not change code for the log feed until
the open questions below are settled.

Code already changed in this session and left in place (uncommitted):
- the `event_time` rename (decision 5);
- the `Temporal.Instant` helper (decision 7).

The user has not said whether the `Temporal.Instant` code change should stay.

### 10. The log tail polls ClickHouse (the TigerBeetle CDC approach)

User decision (2026-09-29). This settles the open question "Log tail as a
feed" in favour of candidate 1, with the orderand as the cursor.

- **The client drives each poll** (user decision, 2026-09-29, replacing the
  earlier "loop on the server"). The client sends `Poll { filter, cursor }`
  over the websocket. The gateway forwards it to event-gw as a NATS
  request/reply. event-gw runs
  `owner AND <filter> AND ingestion_orderand > cursor AND ingestion_orderand <= W ORDER BY ingestion_orderand LIMIT n`
  and replies `{ rows, cursor, more, next_poll_ms }`. W is the watermark from
  decision 12.
- **Changed by decision 18:** event-gw holds the poll open until rows arrive
  or a timeout passes (long polling), instead of answering at once.
  `next_poll_ms` is replaced by `wait_ms` in the request and a per-feed linger
  on the server.
- The reply's cursor is W when all rows up to W were returned. When the limit
  was hit, it is the last row's orderand and `more = true`, which tells the
  client to poll again at once.
- A lost reply is harmless: the client asks again with the same cursor.
- event-gw keeps no state beyond an open request. When the client stops
  polling, the work stops, so there is no lease and no "still watching"
  message.
- Rows go back in batches, bounded by rows and bytes (NATS's default maximum
  message size is 1 MB).
- Nothing is pushed unasked, so nothing can be lost in transit. No
  gap-detection or retransmit protocol is needed.
- ClickHouse applies the filter, so no in-memory copy of the filter language is
  needed.
- Correct only if no row with an orderand ≤ W becomes visible after W is
  published. Decision 12 guarantees this.
- Model: TigerBeetle's CDC job, `~/work/gh/tigerbeetle/src/cdc/runner.zig`. It
  loops: `get_change_events(timestamp_min = last)`, publish, store the last
  timestamp, and wait when the result is empty.
- Cost: see decision 18.

### 11. Log queries move to event-gw

User decision (2026-09-29). Supersedes decision 1 for log queries.

- event-gw runs the log page queries and the tail loop (decision 10). The
  application server proxies client requests to event-gw.
- The application server stays the authorization boundary. It resolves the
  owner and passes it to event-gw, which trusts it.
- The filter language and its SQL compiler move to Rust:
  `structure-web/packages/api/src/logs/logs-repository.ts`, and `LogFilter` in
  `domain/ts/domain/src/entities/log-entry/log-entry.ts`.
- Queries run apart from ingestion, on their own threads or runtime, so a slow
  query cannot stall ingestion.
- Reason: event-gw owns the `event_logs` schema, so schema changes stay in one
  service.
- The client-facing contract decisions (2–5, 7) are not revisited here.

### 12. A separate `ingestion-sequencer` service is the single source of order

User decision (2026-09-29): a separate service. The name was chosen by the
agent. The service assigns the ingestion orderand (the `ingestion_orderand`
columns) and tracks how far the assigned orderands are committed. "Coordinator"
and "orchestrator" were not used because they suggest scheduling or placing
work, which this service does not do.

Model: the FoundationDB sequencer (the "master" role),
`~/work/gh/foundationdb/fdbserver/sequencer/masterserver.cpp`.

Jobs:

- **Hand out orderand ranges.** event-gw asks for `n` numbers per insert batch.
  The reply is the range start, plus `prev`: the end of the range handed out
  just before, to any event-gw instance. `prev` chains all ranges into one
  sequence. There is one request per batch, not per event.
- **Track the watermark W.** event-gw reports each range as inserted or failed.
  W moves only along the chain: it is the end of the longest run of settled
  ranges from the start. Readers only read `ingestion_orderand <= W`.
  Compare FoundationDB `waitForPrev`, `masterserver.cpp:65-71`.
- **Answer a repeated request with the same range.** event-gw numbers its
  requests. A retry gets the earlier reply, not a second range that nobody
  would report. Compare `masterserver.cpp:90-97`.
- **Give every range a deadline.** A range with no report by its deadline is
  marked abandoned, and W moves past it. The deadline is longer than the
  longest possible ClickHouse insert (event-gw's request timeout plus a margin).

Orderand format:

- `u128`: the type already used, `IngestionOrderand(pub u128)`
  (`event-gw/crates/event-gw/src/orderand.rs:21`), stored in `UInt128` columns.
- `(generation << 64) | counter`. The counter lives only in memory and restarts
  at 0 in each generation. The wall clock is not used.
- Consumers still must not decode the layout.

Generations and failover:

- Only the generation is persisted, as a GCS object. At startup the sequencer
  increments it with a conditional write (`ifGenerationMatch`). A
  `412 Precondition Failed` means another sequencer started first. This is one
  durable write per start.
- The first range of a new generation has `prev` set to the end of the previous
  generation (FoundationDB `lastEpochEnd`, `masterserver.cpp:107-109`).
- The new sequencer cannot see the old one's open ranges. It therefore holds W
  until the old sequencer has certainly stopped and the longest deadline has
  passed.
- An old sequencer that is still running, e.g. during a rolling deploy, must
  stop handing out numbers. How: the lease in decision 17.

Not included, although FoundationDB has them: conflict resolvers (events do
not conflict) and a recovery coordinator (the platform restarts the process,
and the generation write does the fencing).

### 13. event-gw takes orderands from the `ingestion-sequencer`

User decision (2026-09-29).

- Replaces the local `IngestionOrderandSource` (`orderand.rs`), which assumes
  one source per gateway.
- Per insert batch: request a range, number the rows, insert, then report the
  range as inserted or failed.
- "Inserted" must mean the rows are visible to queries. event-gw inserts
  synchronously today; asynchronous inserts that don't wait
  (`wait_for_async_insert=0`) would break this.
- event-gw never retries an insert after its range's deadline. It drops the
  batch and does not ack the Pub/Sub messages. Pub/Sub redelivers them, and
  they get new orderands.
- An insert under an abandoned range can still land. Its events then exist
  twice, under different orderands. Readers remove duplicates by `event_id`.

### 14. event-gw shards the work, not the ordering

User decision (2026-09-29).

- The work is spread across event-gw instances: decoding, batching,
  inserting and log queries. The order comes only from the
  `ingestion-sequencer` (decision 12), so any instance can ingest any event.
- Owner partitioning is skipped for now (user decision, 2026-09-29). Instances
  share each NATS feed through a queue group. If partitioning is added later,
  it is only a load decision: moving an owner between instances does not change
  the order, and W covers inserts that land late.
- This is possible only because what event-gw persists, domain events and
  logs, is independent. Storing event N does not read or depend on event N−1.
  Only the number needs an order.
- Contrast with TigerBeetle, which does not shard. A transfer depends on the
  balances left by earlier transfers, so executing transfers in order *is* the
  work. With Pareto-distributed hot accounts, the shards holding those accounts
  become the bottleneck (`~/work/gh/tigerbeetle/docs/ARCHITECTURE.md:16-21`,
  `docs/concepts/performance.md:59-62`). FoundationDB splits the same way we
  do: one sequencer, sharded storage.

### 15. Accounting becomes its own service

User decision (2026-09-29).

- The accounting fold in event-gw (DEC-0ADYZ) is temporary. It moves to a
  separate accounting service, possibly backed by TigerBeetle.
- event-gw keeps only domain events and logs.
- Accounting cannot follow decision 14: a fill's effect on a position depends
  on the fills before it.

**Deferred by decision 19 (2026-09-29):** the fold stays in event-gw for now.

### 16. List and tail are two operations; W hands over from one to the other

User decision (2026-09-29).

| | List | Tail (poll) |
|---|---|---|
| Question | "Show me the logs in this range" (browsing) | "What has arrived since my cursor?" |
| Sort | `event_time`, ascending or descending (decision 3) | `ingestion_orderand` |
| Cursor | the existing page cursor (`event_time` + `event_id`) | an orderand |
| Reply | `{ rows, next_page_cursor, tail_cursor }` | `{ rows, tail_cursor, more }` (long poll, decision 18) |

**Changed by decision 27:** the page cursor is now `page_token` in the request
and `next_page_token` in the reply.

- W and the tail cursor are both orderands, with different meanings:
  - W is shared by all readers and moves on its own: "reading up to here is
    safe".
  - The cursor belongs to one reader and moves only when that reader gets a
    reply: "I have everything up to here, for my filter".
- A poll returns the rows in `(cursor, W]`. The new cursor is W when the reply
  held every matching row up to W, and the last row's orderand when the limit
  cut it short (`more = true`).
- List runs with `ingestion_orderand <= W` and returns W as `tail_cursor`. The
  tail starts from it, so no row falls between the first page and the first
  poll.
- A late row (old `event_time`, new orderand) appears deep in the history for
  list, and as new for tail.
- Both cursors are opaque to the client. A tail cursor is complete only for its
  filter: when the filter changes, the client lists again and tails from the
  new `tail_cursor`.

### 17. Internal transport is NATS; sequencer rollout on Cloud Run worker pools

User decision (2026-09-29) on transports: client ↔ realtime-gateway is
websocket. Everything inside the infrastructure uses NATS. This settles the
open row in decision 8d. Log polls reach event-gw as NATS request/reply
(decision 10). event-gw reaches the `ingestion-sequencer` by NATS request/reply
on a fixed subject.

Rollout procedure, user decision (2026-09-29):

- Today's worker pools (`infra/infra/services/event-gw.ts:77-85`,
  `sim-gw.ts:97-104`) use `manualInstanceCount: 1`. A config change creates a
  new revision (`app/config-hash`), and a TCP probe on port 8080
  (`lib/worker-pool-health.ts`) is the only startup check. An instance count
  of 1 does not guarantee that only one sequencer runs, so the GCS object, not
  Cloud Run, keeps it unique.
- The GCS object holds `{ generation, lease_ms, closed }`. A running sequencer
  renews its lease by rewriting the object with `ifGenerationMatch`. It hands
  out ranges only while its last successful renewal is less than `lease_ms`
  old. Each sequencer times the lease on its own clock, so no two clocks need
  to agree.
- Every range reply carries the generation. event-gw ignores ranges from a
  generation lower than the highest one it has seen.
- **Planned shutdown (SIGTERM):**
  1. The old sequencer stops handing out ranges.
  2. It waits until its open ranges are reported or past their deadlines.
  3. It writes `closed = true` for generation g, and exits.
  4. The new sequencer reads `closed = true`, writes generation g+1, and serves
     W at once, starting from the end of generation g.

  The range deadline must be shorter than the SIGTERM grace period, so that
  step 2 always finishes.
- **Overlap or crash (`closed = false`):**
  1. The new sequencer writes generation g+1 and hands out new ranges at once.
     It publishes no W yet, so waiting polls keep waiting and time out
     empty (decision 18).
  2. The old sequencer's next renewal fails with a 412. It stops handing out
     ranges and leaves the NATS subject.
  3. The new sequencer waits one lease period plus the longest range deadline.
  4. W becomes the end of generation g, i.e. `((g + 1) << 64) − 1`, then
     follows the new generation's chain.

  The tail pauses for about the lease plus the deadline. Ingestion does not
  stop.

### 18. Long polling with a wake-up signal, for every event-gw feed

User decision (2026-09-29). Applies to every table event-gw writes with an
`ingestion_orderand`, not only logs: `event_logs`,
`triggering_source_events`, `target_positions`, `fills`, `deposits`,
`withdrawals`, `position_updates`. One W serves them all. Account positions
are accounting output (decision 15). The accounting service can offer the
same poll contract, and with TigerBeetle, whose timestamps are committed in
order, the timestamp can serve as the cursor.

Reasons: an idle poll that returns nothing still costs a full ClickHouse
query, and plain polling costs viewers × polls per second. Push would need
sequence numbers, per-subscription state and an in-memory copy of every
filter. Long polling keeps the pull contract (cursor, ask again, filtering in
ClickHouse, natural batching) with near-push latency and idle cost. Kafka,
SQS long polling and Kubernetes watches use the same pattern.

The request: `Poll { items: [{ feed, filter, cursor }], wait_ms }`. One
request carries every feed a view shows (e.g. logs, target positions and fills
for one deployment), so a client keeps one poll open, not one per panel.

**Changed by decision 28 (2026-09-29):** there is one poll operation per
entity, each with one feed. A view keeps one poll open per panel. The handling
below applies to each poll on its own.

**Changed by decision 31 (2026-09-29):** for `PollLogs`, the linger of step
4.2 is the client's `buffer_window_ms`.

The three parts:

1. **The writer path** (event-gw, after an insert is confirmed) publishes one
   signal per distinct key in the batch, on `ingest.committed.<key>`:
   `{ key, tables, max_orderand }`. It carries no rows. The key is what a poll
   filters on first: the owner (`parent_type`, `parent_id`) for the strategy
   tables and logs, the trading account for the account tables.
2. **The `ingestion-sequencer`** publishes W on `ingest.watermark` whenever it
   moves forward, at most every few milliseconds. Poll handlers keep the
   latest value instead of asking per poll. A lost W message only leaves a
   handler with a lower W for a moment, which is safe.
3. **The poll handler** (event-gw's query side) keeps the latest W, the
   waiting requests grouped by key, and one NATS subscription per key that has
   waiting requests. Only these handlers receive the signals. Clients and the
   gateway never see them.

Handling one poll:

1. Subscribe to the key's signal subject, if not already subscribed. This
   comes before the query, so a signal published in between is not missed.
2. Query `(cursor, W]` for every item. If any item has rows, reply at once.
3. Otherwise, keep the request with `cursor = W` and a deadline of
   now + `wait_ms`.
4. When a signal for the key arrives with `max_orderand = o` above the stored
   cursor:
   1. Wait until W ≥ o.
   2. Wait the feed's linger (e.g. 50–200 ms), to gather a bigger batch.
   3. Query `(cursor, W]`. If there are rows, reply.
   4. If not (the new rows didn't match the filter), keep waiting with
      `cursor = W`.
5. At the deadline, reply `{ rows: [], cursor }` without querying. The client
   polls again at once, and that poll's step 2 does the check.
6. When the last waiting request for a key is gone, unsubscribe.

Rules:

- Rows come only from the query with the cursor. The signal may only make that
  query happen earlier, and it never moves a cursor. A lost signal delays rows
  by at most one `wait_ms` and never loses them.
- Nothing outlives a request. An abandoned request is answered at its deadline
  and dropped, so no lease or cleanup is needed.
- `wait_ms` stays below the NATS request timeout and the gateway's timeouts.
  The client asks for a `wait_ms` in the request, and event-gw clamps it to
  its configured maximum, because only the server knows those timeouts.
- There is no poll interval. The client polls again as soon as a reply
  arrives, with or without rows, so the pace is set by when event-gw answers
  (`wait_ms` and the per-feed linger, both under event-gw's control). The
  only exception is a failed request, after which the client backs off before
  retrying.
- The client decides only whether it wants the feed. It may stop polling, e.g.
  while the view is hidden, and resume from its cursor without losing rows.

Cost: an idle viewer costs one query per `wait_ms` (e.g. every 25 s). A busy
feed costs one query per linger window. The writer publishes one signal per
key per flush, and the sequencer one W message per advance.

### 19. The accounting split is deferred; event-gw serves the accounting tables for now

User decision (2026-09-29): the separate accounting service (decision 15) is
not built now. The fold stays in event-gw
(`event-gw/crates/event-gw/src/accounting/`), together with
`account_position_aggregate` and `account_trading_volume`. This round covers
only the requests, responses and long-poll subscriptions for the data the
client needs. The split is done later, when the user decides.

- Until then, `frontier_orderand` on `account_position_aggregate` is the
  ingestion orderand of the event that produced the row. The aggregate tables
  can therefore use the same W and the same poll contract as the other
  event-gw tables (decisions 16 and 18).
- The agent's notes for the later split are under Open questions ("Accounting
  service, deferred").

### 20. event-gw serves every ClickHouse query the client needs

User decision (2026-09-29), extending decision 11 from logs to every table.
The query catalog is from the background report, section 3. The contract
names follow its section 6.

| Id | Client use today | Tables | event-gw operation | List sort / tail cursor |
|---|---|---|---|---|
| L1 | Log Explorer page, deployment Logs tab, agent `platform.logs.list` | `event_logs` | `Logs.list` | `event_time` + `event_id` keyset, asc or desc; returns `tail_cursor` |
| L2 | Deployment Logs tab live edge | `event_logs` | poll feed `logs` | `ingestion_orderand` |
| D1 | Latest positions, every 2 s per watched account set | `account_position_aggregate` | `Positions.latest`, then poll feed `positions` | latest row per `(trading_account_id, subject_kind, subject_id)` up to W; tail on `frontier_orderand` |
| D2 | Activity table paging, plus a 2 s "newest 100" poll | `fills`, `demo_fees`, `deposits`, `withdrawals` | `ListFills`, `ListFees`, `ListDeposits`, `ListWithdrawals`, then their polls (replaces the 2 s poll) | `event_time` + `event_id` keyset; tail on `ingestion_orderand` |
| D4 | Net valuation-asset contributions at `from` | `deposits`, `withdrawals` | `Contributions.read` | one aggregate, up to W |
| D5 | Transfers in a window | `deposits`, `withdrawals` | part of `Contributions.read` | needs a row limit and a cursor; unbounded today |
| D6 | Position window for charts: state at `from` plus transitions in `(from, to]` | `account_position_aggregate` | `Positions.window` | needs a row limit and a cursor on `(effective_time, frontier_orderand)`; unbounded today |

**Operation names replaced by decisions 26 and 33.** D2's names above are
the current ones. D5 is `ListDeposits` and `ListWithdrawals`.

Not served by event-gw:

- **D3, deployment start times** (`event_logs` status events, no owner
  predicate). It is replaced by the strategy deployment entity in Postgres
  (decision 6), which the application server serves.

The client does not query `target_positions`, `triggering_source_events`,
`position_updates` or `account_trading_volume` today. Decision 18 already lets
a view add them as poll feeds.

Scope and authorization (decision 11, extended):

- The application server resolves the caller's scope to what event-gw
  filters on. For logs, that is the owner. For the account tables, it is the
  owned trading account ids. It uses Postgres for this:
  `users_trading_accounts_connections` and
  `strategies_trading_accounts_connections`.
- The account tables have no owner column, so event-gw cannot check
  ownership. It trusts the account ids it receives.
- Until the deployment id is settled (decision 6), a deployment scope is
  `(strategy_id, revision_id)`. The application server resolves it to the
  attached accounts, as the client does today in
  `stxrDeploymentService.ts:773-795`.
- The ownership checks the client does today move to the server, including
  the ids from the renderer (report, section 4.2).

### 21. The application server drops its ClickHouse integration

User decision (2026-09-29). This is the consequence of decision 20: the
application server keeps Postgres and proxies ClickHouse-backed queries to
event-gw.

The application server has two ClickHouse readers today:

| Endpoint | Code | Table | Callers | After |
|---|---|---|---|---|
| `GET /api/v0/logs` | `structure-web/packages/api/src/logs/logs-repository.ts` | `event_logs` | the web app; the client's generated SDK has `Logs.listLogs` | proxied to event-gw `Logs.list` |
| `GET /api/v0/positions` (internal, API key) | `structure-web/packages/api/src/positions/positions-repository.ts` | `position_updates` (latest snapshot per account, cursor on `ingestion_orderand`) | strategies at startup: `strats_v2/src/positions_and_balances.rs`, `structure-strat-template-core/src/accounts.rs` | strategies ask event-gw over NATS directly (decision 24) |

Code removed from `structure-web/packages/api` once both readers are moved:

- `ClickhouseEgressConsumer` and `ClickhouseClient`, under `src/timeseries-db/client/`;
- their wiring in `run.ts`;
- `src/clickhouse/clickhouse.ts`;
- the ClickHouse settings in `rt-config.ts`;
- `logs-repository.ts` and `positions-repository.ts`;
- the ClickHouse test container.

The filter language and its SQL compiler move to Rust (decision 11).

### 22. A range is settled only when every table's rows from it are inserted

User decision (2026-09-29). The fold writes `account_position_aggregate` and
`account_trading_volume` rows in inserts separate from the event batch
whose orderands they carry. event-gw reports a range as inserted to the
`ingestion-sequencer` only when the rows of every table numbered from that
range are inserted. Otherwise a positions poll could move its cursor past a
row that is not visible yet.

### 23. D5 and D6 get a row limit and a cursor

User decision (2026-09-29). Transfers (D5) and the position window (D6) are
paged like the other lists: a row limit and an opaque cursor. They are
unbounded today.

### 24. Internal services call event-gw directly over NATS

User decision (2026-09-29).

- Strategies send requests to event-gw over NATS with a reply subject
  (request/reply). They do not go through the application server. This
  covers what `GET /api/v0/positions` serves today.
- Everything inside the infrastructure is trusted. Permissions are checked
  only at the entry point: the application server, for client requests
  (decision 11).

### 25. The fold ignores redelivered events

User asked (2026-09-29) to fix the double counting found under decision 21.
Applied 2026-09-29 (uncommitted), in `event-gw/crates/event-gw/src`:

| File | Change |
|---|---|
| `accounting/book.rs` | `AccountingBook` keeps the ids of the folded events. `apply` returns `FoldOutcome::Applied` or `FoldOutcome::AlreadyFolded`. An event whose id was folded before changes nothing and moves no frontier. A failed fold does not record the id, so a redelivery is tried again. `mark_folded` records an event whose effect is already in the seeded aggregates. |
| `logic/accounting_seed.rs` | Rows inside an account's frontier are marked as folded, and the book's check replaces the seed's own set of seen ids. After a restart, a live redelivery of any persisted row is ignored. |
| `logic/accounting.rs`, `handler.rs` | `AccountingAppendOutcome` became a closed enum (`Appended` or `AlreadyFolded`). An already-folded event appends no aggregate rows and requests no flush. |

- Raw and typed rows (`feed_events`, `fills`, and the others) are still
  appended for a redelivery. `ReplacingMergeTree` removes the duplicates on
  merge, and a redelivery can restore a raw row whose first insert was
  dropped.
- The set of ids grows with the history, as the full-history read at startup
  already does. Checkpoints (see "Accounting service, deferred") would bound
  both.
- Tests:
  - `accounting/tests.rs`: an example where a redelivered fill changes
    nothing, and a proptest that any sequence with redeliveries leaves the
    same book as the sequence delivered once.
  - `logic/accounting_seed/tests.rs`: after the seed, redeliveries of a row
    inside the frontier and of a replayed row are both ignored.
- Verified 2026-09-29, after the root cargo workspace was fixed: all 92
  event-gw unit tests and its integration test binaries pass. `cargo fmt
  --check` reports only `src/main.rs`, which this change did not touch.

### 26. The event-gw RPC contract

User decisions (2026-09-29):

- Protobuf for every caller, both services and the client. rkyv is not used
  for now.
- Every request and response carries `correlation_id`, a `u128`, not
  `request_id`.
- The scope of log queries is called `Parent`, matching `common.ParentType`
  and `common.ParentId`.
- Every cursor carries a fingerprint of the query it was issued for, so
  event-gw can tell when a cursor is reused with a different query.
- The position snapshot operation returns the rows event-gw stores in
  `position_updates`. It does not copy the shape of `GET /api/v0/positions`.
- Subjects name the data, not the service: `stxr.logs.{action}`,
  `stxr.positions.{action}`, and so on. No subject contains `event-gw`.
- Errors follow the Google API error model (`google.rpc.Status` and
  `error_details.proto`). The application server already handles it, and
  `messaging` defines it as `structure.error.ApiError`
  (`msg-schemas/proto/structure/error.proto`).
- The log filter is a string. event-gw parses it.

The contract is recorded here only, not in `messaging` or any crate. The
agent's draft follows. The user has not reviewed all its details. Updated by
decisions 27 to 34.

**Transport.**
- NATS request/reply, one subject per operation (decisions 17 and 24).
- The event-gw instances share each subject through a queue group
  (decision 14).
- The NATS reply subject routes the reply. `correlation_id` is set by the
  caller and echoed back, for logs and traces.
- Agent's note: because subjects name the data, a subject can later move to
  another service without changing its callers, e.g. `stxr.positions.*` to
  the accounting service (decision 19).

| Subject | Operation | Replaces |
|---|---|---|
| `stxr.logs.list` | `ListLogs` | L1, `GET /api/v0/logs` |
| `stxr.logs.poll` | `PollLogs` | L2 |
| `stxr.fills.list` | `ListFills` | D2, with the three lists below |
| `stxr.fills.poll` | `PollFills` | the 2 s poll of D2, with the three polls below |
| `stxr.fees.list` | `ListFees` | D2 |
| `stxr.fees.poll` | `PollFees` | |
| `stxr.deposits.list` | `ListDeposits` | D2; D5 with `ListWithdrawals` |
| `stxr.deposits.poll` | `PollDeposits` | |
| `stxr.withdrawals.list` | `ListWithdrawals` | D2; D5 with `ListDeposits` |
| `stxr.withdrawals.poll` | `PollWithdrawals` | |
| `stxr.positions.latest` | `LatestPositions` | D1 |
| `stxr.positions.window` | `PositionWindow` | D6 |
| `stxr.positions.poll` | `PollPositions` | the 2 s poll of D1 |
| `stxr.contributions.net` | `NetContributions` | D4 |
| `stxr.position_updates.latest` | `LatestPositionUpdates` | `GET /api/v0/positions` (strategies) |
| `stxr.position_updates.poll` | `PollPositionUpdates` | |

**Log filter.**
- A string in the log filter language of `GET /api/v0/logs`. Its parser and
  SQL compiler move from `structure-web/packages/api/src/logs/logs-repository.ts`
  to Rust, in event-gw (decision 11).
- A filter that does not parse, names an unknown field, uses an operator
  the field does not allow, or has a value the field cannot parse is
  rejected with `FILTER_INVALID`.
- The fingerprint is taken over the parsed filter, not the string, so
  whitespace and clause order do not change it.

**Cursors.** Page tokens and tail cursors are opaque `bytes`. Only event-gw
reads them.

- **Layout:**
  - a version byte;
  - a 16-byte query fingerprint;
  - the position. For a page token this is the key of the last row
    returned: `(event_time, event_id)`, or
    `(effective_time, frontier_orderand, position key)` for the position
    window. For a tail cursor it is an ingestion orderand at or below W.
- **Fingerprint:** BLAKE3, truncated to 128 bits, over a canonical form of
  the inputs that define the query. It is computed from the decoded request,
  not from the protobuf bytes, because protobuf encoding is not canonical.
  In the canonical form, account ids and parents are sorted and
  deduplicated, and the parsed filter's clauses and source types are sorted.
  - A page token covers the operation, the scope, the filter, the time range
    and the order. It does not cover `page_size`.
  - A tail cursor covers the entity (logs, fills, fees, deposits,
    withdrawals, positions or position updates), the scope and the filter.
    It does not cover the time range or the order. So the tail cursor a list
    returns is valid for the poll of the same entity with the same scope and
    filter, e.g. `PollLogs` after `ListLogs`, or `PollFills` after
    `ListFills` (decisions 16 and 33).
- **Mismatch.** A cursor used with a different query is rejected with
  `CURSOR_QUERY_MISMATCH`, and the caller lists again. event-gw now enforces
  decision 16's rule that a tail cursor is complete only for its filter.
  - The same applies when the account set changes, e.g. a strategy gains an
    account. The new list then includes that account's history.
- **Not a security measure.** Cursors stay unsigned. Every query applies its
  scope on its own, so a forged cursor only moves within data the caller may
  already read.
- **Versioning.** The fingerprint must be the same on every event-gw instance
  and release. Changing the canonical form or the layout bumps the version,
  and older cursors are rejected with `CURSOR_MALFORMED`.

**Errors.** Every response is either its result or a
`structure.error.ApiError`: a code, a developer-facing message, and details.
Every error carries an `ErrorInfo` whose `reason` is one of the closed set
below.

| `ErrorInfo.reason` | Code | Other details | When |
|---|---|---|---|
| `REQUEST_INVALID` | `INVALID_ARGUMENT` | `BadRequest` with one violation per field | a required field is missing, an enum is unspecified, `from > to`, an empty scope, or a payload that does not decode |
| `FILTER_INVALID` | `INVALID_ARGUMENT` | `BadRequest` on `filter`; metadata `position` (byte offset) | the log filter string is rejected (see Log filter) |
| `CURSOR_MALFORMED` | `INVALID_ARGUMENT` | `BadRequest` on `page_token` or `tail_cursor` | not issued by event-gw, damaged, or of an older version |
| `CURSOR_QUERY_MISMATCH` | `INVALID_ARGUMENT` | `BadRequest` on `page_token` or `tail_cursor` | issued for a different query |
| `TOO_MANY_ACCOUNTS` | `INVALID_ARGUMENT` | metadata `max`, `requested` | more accounts than event-gw's maximum |
| `TOO_MANY_PARENTS` | `INVALID_ARGUMENT` | metadata `max`, `requested` | more log parents than event-gw's maximum |
| `STORAGE_UNAVAILABLE` | `UNAVAILABLE` | `RetryInfo` | ClickHouse refused or dropped the query |
| `STORAGE_TIMEOUT` | `TIMEOUT` | `RetryInfo` | ClickHouse did not answer in time |
| `INTERNAL` | `INTERNAL` | | a stored row that does not convert, or any other defect in event-gw |

A payload that does not decode still gets its operation's response type,
with a zero `correlation_id`.

**Other rules.**
- Time ranges are absolute. A caller resolves a relative range ("last hour")
  once, before the first page, and reuses it for later pages. Otherwise the
  fingerprint would change on every page.
- `page_size = 0` means event-gw's default page size. event-gw clamps
  `page_size` and `wait_ms` to its configured maximums (decisions 18, 23
  and 27).
- Timestamps use `google.protobuf.Timestamp` (decision 2).
- Decimals use `Decimal128`. `common.Decimal` has an `int64` mantissa, which
  cannot carry the `Int128` mantissas event-gw stores.
- `CorrelationId` and `Decimal128` split 128-bit values into two big-endian
  `fixed64` words, as `common.EventId` does.

The draft is split into one file per entity (decisions 30 and 33). Every
file imports `structure/query/v1/query.proto` and refers to its messages by
full name.

```proto
// structure/query/v1/query.proto
syntax = "proto3";

package structure.query.v1;

import "google/protobuf/timestamp.proto";
import "common.proto";

// Messages shared by the read APIs below.
//
// Long polls (decisions 18 and 28). A poll waits up to wait_ms (clamped to
// the server's maximum) for rows after tail_cursor, then replies with the
// rows in (tail_cursor, W]. The reply's tail_cursor is W, or the last row's
// orderand when more = true. more = true means the row limit cut the reply
// short; poll again at once.

// A u128 set by the caller and echoed in the response. Big endian:
// w0 holds the high 64 bits, w1 the low 64 bits.
message CorrelationId {
  fixed64 w0 = 1;
  fixed64 w1 = 2;
}

// value = mantissa × 10^-scale. The mantissa is a 128-bit two's complement
// integer, big endian: w0 holds the high 64 bits, w1 the low 64 bits.
message Decimal128 {
  fixed64 w0 = 1;
  fixed64 w1 = 2;
  uint32 scale = 3;
}

// Trading accounts a query reads, resolved and authorized by the entry
// point. Order and duplicates are ignored.
message Accounts {
  repeated common.AccountId ids = 1;
}

// Absolute and inclusive at both ends.
message TimeRange {
  google.protobuf.Timestamp from = 1;
  google.protobuf.Timestamp to = 2;
}

enum Order {
  ORDER_UNSPECIFIED = 0; // rejected
  ORDER_ASCENDING = 1;
  ORDER_DESCENDING = 2;
}

// Columns every stored event row carries.
message EventHeader {
  common.EventId event_id = 1;
  common.TraceId trace_id = 2;
  common.AccountId trading_account_id = 3;
  // When the event happened on the venue.
  google.protobuf.Timestamp event_time = 4;
  // When our system first observed it.
  google.protobuf.Timestamp observe_time = 5;
  // When event-gw wrote it.
  google.protobuf.Timestamp ingestion_time = 6;
}
```

```proto
// structure/logs/v1/logs.proto
syntax = "proto3";

package structure.logs.v1;

import "common.proto";
import "structure/error.proto";
import "structure/event_log.proto";
import "structure/query/v1/query.proto";

// A node of the ownership hierarchy (event_logs.subject_parent_*). A log
// query reads only rows under its parents, so it cannot read the wrong
// owner's rows by mistake. These columns also lead the event_logs sort key
// (decision 32).
message Parent {
  common.ParentType parent_type = 1;
  common.ParentId parent_id = 2;
}

message LogScope {
  // Rows under any of these parents. Empty is rejected. Order and
  // duplicates are ignored. The entry point sets them.
  repeated Parent parents = 1;
  // Source types the caller may see; empty is rejected. The entry point
  // sets it, e.g. webserver and strategy for a user.
  repeated common.SourceType source_types = 2;
}

message ListLogsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  LogScope scope = 2;
  // The log filter language; parsed by the server. Empty matches every row.
  string filter = 3;
  structure.query.v1.TimeRange range = 4;
  structure.query.v1.Order order = 5; // by (event_time, event_id)
  uint32 page_size = 6; // 0 = the server's default
  bytes page_token = 7; // empty for the first page
}

message LogPage {
  // EventLog.ts is event_time.
  repeated structure.EventLog entries = 1;
  bytes next_page_token = 2; // empty on the last page
  // Tail cursor at W, for PollLogs with the same scope and filter
  // (decision 16).
  bytes tail_cursor = 3;
}

message ListLogsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    LogPage page = 2;
    structure.error.ApiError error = 3;
  }
}

message PollLogsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  LogScope scope = 2;
  string filter = 3;     // as in ListLogsRequest.filter
  bytes tail_cursor = 4; // from LogPage or the previous LogTail
  uint32 wait_ms = 5;
  // How long the server holds a reply after its first rows are visible, so
  // that rows arriving just after them join the same reply (decision 31).
  // Unset = the server's default. Clamped to the server's maximum and to
  // the poll's deadline.
  optional uint32 buffer_window_ms = 6;
}

message LogTail {
  // Sorted by (event_time, event_id) within this reply. Order across
  // replies is not guaranteed.
  repeated structure.EventLog entries = 1;
  // W, or the highest orderand in this reply when more = true.
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollLogsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    LogTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service LogService {
  rpc ListLogs(ListLogsRequest) returns (ListLogsResponse);  // stxr.logs.list
  rpc PollLogs(PollLogsRequest) returns (PollLogsResponse);  // stxr.logs.poll
}
```

```proto
// structure/fills/v1/fills.proto
syntax = "proto3";

package structure.fills.v1;

import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

enum Side {
  SIDE_UNSPECIFIED = 0;
  SIDE_BUY = 1;
  SIDE_SELL = 2;
}

enum LiquidityRole {
  LIQUIDITY_ROLE_UNSPECIFIED = 0;
  LIQUIDITY_ROLE_MAKER = 1;
  LIQUIDITY_ROLE_TAKER = 2;
}

// One fills row.
message Fill {
  structure.query.v1.EventHeader header = 1;
  market_info.InstrumentId instrument_id = 2;
  Side side = 3;
  structure.query.v1.Decimal128 quantity = 4; // unsigned; side carries the direction
  structure.query.v1.Decimal128 price = 5;    // in the market's quote unit
  LiquidityRole liquidity_role = 6;
}

message ListFillsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  structure.query.v1.TimeRange range = 3;
  structure.query.v1.Order order = 4; // by (event_time, event_id)
  uint32 page_size = 5; // 0 = the server's default
  bytes page_token = 6; // empty for the first page
}

message FillPage {
  repeated Fill fills = 1;
  bytes next_page_token = 2; // empty on the last page
  // Tail cursor at W, for PollFills with the same accounts (decision 16).
  bytes tail_cursor = 3;
}

message ListFillsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    FillPage page = 2;
    structure.error.ApiError error = 3;
  }
}

message PollFillsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  bytes tail_cursor = 3; // from FillPage or the previous FillTail
  uint32 wait_ms = 4;
}

message FillTail {
  repeated Fill fills = 1;
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollFillsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    FillTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service FillService {
  rpc ListFills(ListFillsRequest) returns (ListFillsResponse); // stxr.fills.list
  rpc PollFills(PollFillsRequest) returns (PollFillsResponse); // stxr.fills.poll
}
```

```proto
// structure/fees/v1/fees.proto
syntax = "proto3";

package structure.fees.v1;

import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

// One demo_fees row.
message Fee {
  structure.query.v1.EventHeader header = 1;
  market_info.InstrumentId instrument_id = 2;
  structure.query.v1.Decimal128 fee = 3; // in the market's quote unit
}

message ListFeesRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  structure.query.v1.TimeRange range = 3;
  structure.query.v1.Order order = 4; // by (event_time, event_id)
  uint32 page_size = 5; // 0 = the server's default
  bytes page_token = 6; // empty for the first page
}

message FeePage {
  repeated Fee fees = 1;
  bytes next_page_token = 2; // empty on the last page
  // Tail cursor at W, for PollFees with the same accounts (decision 16).
  bytes tail_cursor = 3;
}

message ListFeesResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    FeePage page = 2;
    structure.error.ApiError error = 3;
  }
}

message PollFeesRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  bytes tail_cursor = 3; // from FeePage or the previous FeeTail
  uint32 wait_ms = 4;
}

message FeeTail {
  repeated Fee fees = 1;
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollFeesResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    FeeTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service FeeService {
  rpc ListFees(ListFeesRequest) returns (ListFeesResponse); // stxr.fees.list
  rpc PollFees(PollFeesRequest) returns (PollFeesResponse); // stxr.fees.poll
}
```

```proto
// structure/deposits/v1/deposits.proto
syntax = "proto3";

package structure.deposits.v1;

import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

// One deposits row.
message Deposit {
  structure.query.v1.EventHeader header = 1;
  market_info.AssetId asset_id = 2;
  structure.query.v1.Decimal128 quantity = 3; // unsigned
}

message ListDepositsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  structure.query.v1.TimeRange range = 3;
  structure.query.v1.Order order = 4; // by (event_time, event_id)
  uint32 page_size = 5; // 0 = the server's default
  bytes page_token = 6; // empty for the first page
}

message DepositPage {
  repeated Deposit deposits = 1;
  bytes next_page_token = 2; // empty on the last page
  // Tail cursor at W, for PollDeposits with the same accounts (decision 16).
  bytes tail_cursor = 3;
}

message ListDepositsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    DepositPage page = 2;
    structure.error.ApiError error = 3;
  }
}

message PollDepositsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  bytes tail_cursor = 3; // from DepositPage or the previous DepositTail
  uint32 wait_ms = 4;
}

message DepositTail {
  repeated Deposit deposits = 1;
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollDepositsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    DepositTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service DepositService {
  rpc ListDeposits(ListDepositsRequest) returns (ListDepositsResponse); // stxr.deposits.list
  rpc PollDeposits(PollDepositsRequest) returns (PollDepositsResponse); // stxr.deposits.poll
}
```

```proto
// structure/withdrawals/v1/withdrawals.proto
syntax = "proto3";

package structure.withdrawals.v1;

import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

// One withdrawals row.
message Withdrawal {
  structure.query.v1.EventHeader header = 1;
  market_info.AssetId asset_id = 2;
  structure.query.v1.Decimal128 quantity = 3; // unsigned
}

message ListWithdrawalsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  structure.query.v1.TimeRange range = 3;
  structure.query.v1.Order order = 4; // by (event_time, event_id)
  uint32 page_size = 5; // 0 = the server's default
  bytes page_token = 6; // empty for the first page
}

message WithdrawalPage {
  repeated Withdrawal withdrawals = 1;
  bytes next_page_token = 2; // empty on the last page
  // Tail cursor at W, for PollWithdrawals with the same accounts (decision 16).
  bytes tail_cursor = 3;
}

message ListWithdrawalsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    WithdrawalPage page = 2;
    structure.error.ApiError error = 3;
  }
}

message PollWithdrawalsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  bytes tail_cursor = 3; // from WithdrawalPage or the previous WithdrawalTail
  uint32 wait_ms = 4;
}

message WithdrawalTail {
  repeated Withdrawal withdrawals = 1;
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollWithdrawalsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    WithdrawalTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service WithdrawalService {
  rpc ListWithdrawals(ListWithdrawalsRequest) returns (ListWithdrawalsResponse); // stxr.withdrawals.list
  rpc PollWithdrawals(PollWithdrawalsRequest) returns (PollWithdrawalsResponse); // stxr.withdrawals.poll
}
```

```proto
// structure/positions/v1/positions.proto
syntax = "proto3";

package structure.positions.v1;

import "google/protobuf/timestamp.proto";
import "common.proto";
import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

// One account_position_aggregate row: the state of one position after the
// event frontier_event_id was folded.
message PositionAggregate {
  common.AccountId trading_account_id = 1;
  oneof subject {
    market_info.AssetId asset_id = 2;       // spot, held in the asset
    market_info.ContractId contract_id = 3; // perp or future
  }
  common.EventId frontier_event_id = 4;
  google.protobuf.Timestamp effective_time = 5;
  structure.query.v1.Decimal128 quantity = 6; // signed; the sign is the direction
  structure.query.v1.Decimal128 average_price = 7;
  structure.query.v1.Decimal128 realized_pnl = 8;
  structure.query.v1.Decimal128 fees = 9;
  structure.query.v1.Decimal128 volume = 10;
  structure.query.v1.Decimal128 turnover = 11;
}

message LatestPositionsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
}

message LatestPositions {
  // The latest row of every position of the accounts, up to W.
  repeated PositionAggregate positions = 1;
  // Tail cursor at W, for PollPositions with the same accounts.
  bytes tail_cursor = 2;
}

message LatestPositionsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    LatestPositions latest = 2;
    structure.error.ApiError error = 3;
  }
}

message PositionWindowRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  structure.query.v1.TimeRange range = 3;
  uint32 page_size = 4; // transitions per page; 0 = the server's default
  bytes page_token = 5; // empty for the first page
}

message PositionWindowPage {
  // First page only: the state of every position at range.from.
  repeated PositionAggregate seed = 1;
  // Rows in (range.from, range.to], ascending by
  // (effective_time, frontier orderand).
  repeated PositionAggregate transitions = 2;
  bytes next_page_token = 3; // empty on the last page
}

message PositionWindowResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    PositionWindowPage page = 2;
    structure.error.ApiError error = 3;
  }
}

message PollPositionsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  bytes tail_cursor = 3; // from LatestPositions or the previous PositionTail
  uint32 wait_ms = 4;
}

message PositionTail {
  // account_position_aggregate rows, by frontier orderand.
  repeated PositionAggregate positions = 1;
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollPositionsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    PositionTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service PositionService {
  rpc LatestPositions(LatestPositionsRequest) returns (LatestPositionsResponse); // stxr.positions.latest
  rpc PositionWindow(PositionWindowRequest) returns (PositionWindowResponse);    // stxr.positions.window
  rpc PollPositions(PollPositionsRequest) returns (PollPositionsResponse);       // stxr.positions.poll
}
```

```proto
// structure/contributions/v1/contributions.proto
syntax = "proto3";

package structure.contributions.v1;

import "google/protobuf/timestamp.proto";
import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

message NetContributionsRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  market_info.AssetId asset_id = 3;
  google.protobuf.Timestamp at = 4;
}

message NetContributions {
  // Deposits minus withdrawals of asset_id with event_time <= at, summed
  // exactly across scales.
  structure.query.v1.Decimal128 net = 1;
}

message NetContributionsResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    NetContributions contributions = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service ContributionService {
  rpc NetContributions(NetContributionsRequest) returns (NetContributionsResponse); // stxr.contributions.net
}
```

```proto
// structure/position_updates/v1/position_updates.proto
// Venue position updates (drop copy).
syntax = "proto3";

package structure.position_updates.v1;

import "market-info/market_info.proto";
import "structure/error.proto";
import "structure/query/v1/query.proto";

enum Coverage {
  COVERAGE_UNSPECIFIED = 0;
  COVERAGE_FULL = 1;    // every position of the account
  COVERAGE_PARTIAL = 2; // only the listed positions
}

enum AmountSemantics {
  AMOUNT_SEMANTICS_UNSPECIFIED = 0;
  AMOUNT_SEMANTICS_ABSOLUTE = 1;  // replace
  AMOUNT_SEMANTICS_INCREMENT = 2; // add
}

message SpotPosition {
  market_info.AssetId asset_id = 1;
  structure.query.v1.Decimal128 quantity = 2;
}

message DerivativePosition {
  market_info.ContractId contract_id = 1;
  structure.query.v1.Decimal128 quantity = 2; // signed; the sign is the direction
}

// One position_updates row, as the venue sent it.
message PositionUpdate {
  structure.query.v1.EventHeader header = 1;
  Coverage coverage = 2;
  AmountSemantics amount_semantics = 3;
  repeated SpotPosition spot_positions = 4;
  repeated DerivativePosition derivative_positions = 5;
}

message LatestPositionUpdatesRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
}

message LatestPositionUpdates {
  // Per account: the latest FULL update and every update after it, in
  // ingestion order, up to W. Folding them in order gives the account's
  // current venue positions.
  repeated PositionUpdate updates = 1;
  // Tail cursor at W, for PollPositionUpdates with the same accounts.
  bytes tail_cursor = 2;
}

message LatestPositionUpdatesResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    LatestPositionUpdates latest = 2;
    structure.error.ApiError error = 3;
  }
}

message PollPositionUpdatesRequest {
  structure.query.v1.CorrelationId correlation_id = 1;
  structure.query.v1.Accounts accounts = 2;
  bytes tail_cursor = 3; // from LatestPositionUpdates or the previous PositionUpdateTail
  uint32 wait_ms = 4;
}

message PositionUpdateTail {
  // position_updates rows, in ingestion order.
  repeated PositionUpdate updates = 1;
  bytes tail_cursor = 2;
  bool more = 3;
}

message PollPositionUpdatesResponse {
  structure.query.v1.CorrelationId correlation_id = 1;
  oneof result {
    PositionUpdateTail tail = 2;
    structure.error.ApiError error = 3;
  }
}

// Documentation only: each rpc is NATS request/reply on its subject.
service PositionUpdateService {
  rpc LatestPositionUpdates(LatestPositionUpdatesRequest) returns (LatestPositionUpdatesResponse); // stxr.position_updates.latest
  rpc PollPositionUpdates(PollPositionUpdatesRequest) returns (PollPositionUpdatesResponse);       // stxr.position_updates.poll
}
```

### 27. List requests take `page_size` and `page_token`

User decision (2026-09-29). Every paged request (`ListLogs`,
`ListFills`, `ListFees`, `ListDeposits`, `ListWithdrawals`, `PositionWindow`)
takes `page_size` and `page_token`
instead of `limit` and `cursor`. Every page returns `next_page_token`, empty on
the last page. These are the names of Google's AIP-158.

- `page_size = 0` means event-gw's default page size, as in AIP-158. This rule
  was added by the agent.
- AIP-158 also requires a page token to be rejected when the other request
  fields change. Decision 26's `CURSOR_QUERY_MISMATCH` already does this.
- Tail cursors keep the name `tail_cursor`. They are not page tokens: they
  mark a position in the ingestion order, not a place in a sorted list.

### 28. One poll operation per entity

User decision (2026-09-29). Replaces the single `Poll` of decisions 18 and 26.

- Each entity has its own poll: `PollLogs`, `PollPositions`,
  `PollPositionUpdates`, on `stxr.<entity>.poll`. Fills, fees, deposits and
  withdrawals each have their own list and poll (decision 33).
- Reason (user): one `Poll` bundles entities that different services will
  own. When accounting moves to its own service (decision 15), `PollPositions`
  moves with `stxr.positions.*`, and no caller's contract changes. A bundled
  `Poll` would have to be split, which breaks it.
- Decision 18 bundled the feeds so that a view keeps one poll open instead of
  one per panel. Over one websocket and NATS, an open request costs event-gw
  one waiting entry, so that reason is weak.
- Also gained: each poll has a typed request and reply with no `oneof` over
  feeds, and one error per reply instead of one per item.

### 29. Fills, fees, deposits and withdrawals are polled per table

User decision (2026-09-29): each of these tables has its own poll
(`stxr.fills.poll`, `stxr.fees.poll`, `stxr.deposits.poll`,
`stxr.withdrawals.poll`).

**Extended by decision 33:** each also has its own list. The merged list that
the agent kept here, and its per-table tail cursors, are gone.

- The event header moved into each row message, so a poll returns fully
  typed rows.
- A view that shows all four tables keeps four polls open. The wake-up signal
  (decision 18) already lists the tables of each insert, so a poll for one
  table is woken only by inserts into that table.

### 30. One package and one service per entity, not named after event-gw

User agreed (2026-09-29) with the agent's proposal: the draft's
`package event_gw.v1` and `service EventGw` would be wrong for positions once
they move to the accounting service (decision 28's reason).

The names are the agent's choice. They follow `structure.trading_account.v1`
and `structure.session.v1` in `msg-schemas`.

| File | Package | Service | Subjects |
|---|---|---|---|
| `structure/query/v1/query.proto` | `structure.query.v1` | none: shared messages | |
| `structure/logs/v1/logs.proto` | `structure.logs.v1` | `LogService` | `stxr.logs.*` |
| `structure/fills/v1/fills.proto` | `structure.fills.v1` | `FillService` | `stxr.fills.*` |
| `structure/fees/v1/fees.proto` | `structure.fees.v1` | `FeeService` | `stxr.fees.*` |
| `structure/deposits/v1/deposits.proto` | `structure.deposits.v1` | `DepositService` | `stxr.deposits.*` |
| `structure/withdrawals/v1/withdrawals.proto` | `structure.withdrawals.v1` | `WithdrawalService` | `stxr.withdrawals.*` |
| `structure/positions/v1/positions.proto` | `structure.positions.v1` | `PositionService` | `stxr.positions.*` |
| `structure/contributions/v1/contributions.proto` | `structure.contributions.v1` | `ContributionService` | `stxr.contributions.net` |
| `structure/position_updates/v1/position_updates.proto` | `structure.position_updates.v1` | `PositionUpdateService` | `stxr.position_updates.*` |

- `structure.query.v1` holds `CorrelationId`, `Decimal128`, `Accounts`,
  `TimeRange`, `Order` and `EventHeader`. `Parent` moved into the logs file,
  its only user.
- The proto comments say "the server", not "event-gw".
- Checked 2026-09-29, after decision 33: the nine files compile with
  `protoc` against `messaging/msg-schemas/proto`.

### 31. `PollLogs` takes a buffer window

User decision (2026-09-29), after Google Cloud Logging's
`TailLogEntriesRequest.buffer_window`
(`googleapis/google/logging/v2/logging.proto`).

- `PollLogsRequest.buffer_window_ms`: once a reply's first rows are visible,
  the server waits this long before replying, so rows that arrive just after
  them join the same reply.
- Rows in a reply are sorted by `(event_time, event_id)`. Order across
  replies is not guaranteed. GCP gives the same guarantee: each
  `TailLogEntriesResponse` is ordered by timestamp, and "Ordering is not
  guaranteed between separate responses".
- It replaces decision 18's per-feed linger for `PollLogs`, and the client
  chooses it. Unset means the server's default. The server clamps it to its
  maximum and to the poll's deadline. GCP allows 0 to 60 s, default 2 s. The
  other polls keep the server's linger.
- A reply cut by the row limit (`more = true`) is sent without waiting, so
  catching up is not slowed down. Because the rows are sorted by event time,
  its tail cursor is the highest orderand in the reply, not the last row's.
- A row can arrive later than any window (Pub/Sub redelivery, event-gw
  batching), so the client still places rows by `event_time`. The window
  makes that rarer and the batches bigger.

Why GCP's tail has no cursor (agent, from `logging.proto`):

- `TailLogEntries` is a stream. The server pushes entries as they are
  ingested, and the position lives in the open stream.
- Dropped entries are only reported: `SuppressionInfo` gives a reason
  (`RATE_LIMIT`, or `NOT_CONSUMED` when the client reads too slowly) and a
  lower bound on the count, not the entries.
- A broken stream cannot be resumed. A new tail starts from now.
- GCP accepts gaps and reports them. Decision 8c does not accept gaps, and
  the tail cursor is what lets a reader resume without one.

### 32. Log requests carry a list of parents

User decision (2026-09-29).

- The parent is about correctness, not trust. It enforces the ownership
  hierarchy, so that a query cannot read the wrong owner's rows by mistake.
  Access control stays at the entry point (decision 24).
- The parent columns lead the `event_logs` sort key
  (`subject_parent_type`, `subject_parent_id`, ...), so filtering on them
  also lets ClickHouse use the index.
- `LogScope.parents` is a list, like `resource_names` in GCP's
  `ListLogEntriesRequest` and `TailLogEntriesRequest`.
- The empty list is the default. A list with an item was filled in on
  purpose, so a listed parent is read as given, the System parent (type 0,
  id 0) included. No `oneof` is needed. This replaces the agent's `oneof`
  proposal.
- An empty list is rejected with `REQUEST_INVALID`, like an empty account
  list (user confirmed, 2026-09-29).
- Agent's additions: the fingerprint sorts and deduplicates the parents, and
  a request with more parents than the server's maximum is rejected with
  `TOO_MANY_PARENTS`.
- NATS auth is not wanted (user decision). This replaces the agent's proposal
  of NATS users with subject permissions.

### 33. Fills, fees, deposits and withdrawals each have their own list and poll

User decision (2026-09-29). The four tables share no grouping name anywhere
in the contract. Each event has its own list, poll, requests and replies.

| Package | Service | Operations | Rows |
|---|---|---|---|
| `structure.fills.v1` | `FillService` | `ListFills`, `PollFills` | `Fill` (`fills`) |
| `structure.fees.v1` | `FeeService` | `ListFees`, `PollFees` | `Fee` (`demo_fees`) |
| `structure.deposits.v1` | `DepositService` | `ListDeposits`, `PollDeposits` | `Deposit` (`deposits`) |
| `structure.withdrawals.v1` | `WithdrawalService` | `ListWithdrawals`, `PollWithdrawals` | `Withdrawal` (`withdrawals`) |

- Each list's page returns its own `tail_cursor` for the matching poll. The
  `kinds` field, the per-kind tail cursors and the merged row `oneof` are
  gone.
- `Deposit` and `Withdrawal` are separate messages with the same fields.
- The activity table (D2) shows the four tables in one time order. The
  client now merges four lists. Each list is sorted by
  `(event_time, event_id)`, so the client keeps one page per list, shows the
  smallest next row, and fetches a list's next page when its rows run out.
- D5 is `ListDeposits` and `ListWithdrawals`.

### 34. `NetContributions` stays

User decision (2026-09-29): the agent's proposal to drop `NetContributions`
is rejected. D4 stays a server-side sum, and D5 is the two transfer lists
(decision 33).

## Open questions

- **Raised by decisions 10–18 (2026-09-29):**
  - The values of `wait_ms`, the per-feed linger, and the row and byte limits
    per reply (decisions 10 and 18).
  - The exact key of `ingest.committed.<key>` for each table, and its NATS
    subject layout (decision 18).
  - The message schemas for list, poll and range requests. The transport is
    NATS (decision 17).
  - The values of the range deadline, `lease_ms` and the renewal period
    (decision 17).
  - Check in Cloud Run: the SIGTERM grace period for worker pools, and whether
    a new revision's instance starts before the old one stops. This decides
    which rollout path a normal deploy takes (decision 17).
  - Runtime events reach event-gw over plain NATS, which delivers at most
    once. Events buffered on an event-gw instance that crashes are lost
    unnoticed. None of decisions 10–17 fixes this.
  - `event_id` is optional on `event_logs`, so duplicates can't always be
    removed. Make it required, or accept rare duplicates.
  - Deferred (owner partitioning skipped, decision 14): balancing event-gw
    partitions. Agent proposal: many hash slots, placed on
    instances by measured load, with a list of power users pinned to their own
    slots.
  - Deferred (decision 14): routing each message to the instance that owns
    its owner. For NATS feeds the owner can be read from the message
    (`subject()` in `strategy_deployment_feed.rs`), not from the hashed feed
    subject. Either producers put a slot in the NATS subject and instances
    subscribe to their slots, or any instance receives and forwards over NATS.
  - The catch-up query needs a minmax skip index on `ingestion_orderand`.
    `event_logs` is partitioned by `event_time` day, and its ORDER BY has no
    orderand.
  - The accounting service reading domain events from event-gw (agent
    proposal): the same cursor loop, with TigerBeetle transfer ids derived from
    `event_id`. Some results (average price, realized PnL) depend on
    application order; venue order may differ from orderand order.

- **Raised by decisions 19–21 (2026-09-29):**
  - **D4 as an aggregate.** Whether `Contributions.read` returns only the sum
    at `from`, with the transfers paged separately. The agent's draft in
    decision 26 does this: `NetContributions` for D4, and `ListDeposits`
    with `ListWithdrawals` for D5. **Decided in decision 34:**
    `NetContributions` stays.
  - **Raised by decision 26:**
    - Relative time ranges: should the client resolve them once, or should
      the cursor store the resolved range so a relative range can be sent
      again?
    - Whether `LatestPositionUpdates` should also accept a time ("positions as
      of T") for strategies that restart from a snapshot.
    - **Only the first page's `tail_cursor` is safe** (agent, 2026-09-29).
      Each page reads up to the W current when it runs. A client that lists
      pages 1–3 and tails from page 3's `tail_cursor` skips a row that landed
      in `(W₁, W₃]` with an `event_time` inside pages 1–2. Agent proposal,
      not decided: the first page's W goes into the page token, and every
      later page reads up to that W. The whole list is then one snapshot and
      every page returns the same `tail_cursor`. Kubernetes paginated lists
      work this way: the continue token keeps the first page's
      `resourceVersion`, and the watch starts from it. The alternative is to
      return `tail_cursor` on the first page only.
    - **`PositionWindow` returns two kinds of rows** (user asked why,
      2026-09-29). The seed is each position's state at `range.from`; the
      chart needs it for positions that do not change inside the window.
      Today the client reads both halves in one `UNION ALL` query and splits
      them by `effective_time`
      (`clickhouseStxrDeploymentDataProvider.ts:175-186`). Paging makes the
      mix awkward: the seed is on the first page only, and `page_size` counts
      only transitions. Agent proposal, not decided: split it into
      `PositionsAt { accounts, at }` (the seed, not paged, same size bound as
      `LatestPositions`) and `ListPositionTransitions { accounts, range,
      page_size, page_token }`. Rows are full states, not deltas, so a row
      at exactly `from` returned by both is harmless.
    - **The package and service are named after event-gw** (agent,
      2026-09-29). Decision 28's reason also applies to `package event_gw.v1`
      and `service EventGw`: when positions move to the accounting service,
      those names are wrong for them. The wire format does not carry the
      package, so callers would not break on the wire, but generated code
      would move. Agent proposal: one service per entity, in a package not
      named after event-gw. **Decided in decision 30.**
    - **How the log parent is enforced** (user asked, 2026-09-29). Today's
      design, not changed:
      - The client never sends a parent. The application server builds it
        from the authenticated user, as `LogsService.listUserLogs` does
        today (`structure-web/packages/api/src/logs/logs-service.ts:42-44`).
      - The server rejects a request without a scope, and every query
        filters on `subject_parent_type` and `subject_parent_id`
        (`event-gw/crates/db/clickhouse/schema.sql:421`: "ownership must
        always be enforced"). The scope is also in the cursor fingerprint.
      - Other callers inside the infrastructure are trusted (decision 24).

      Two gaps found (agent, 2026-09-29). **Both settled by decision 32:**
      parents become a list, with no `oneof`, and NATS auth is not wanted.
      - **An empty `Parent` reads the platform's own logs.**
        `PARENT_TYPE_SYSTEM` is 0 (`msg-schemas/proto/common.proto:18-21`)
        and `SYSTEM_PARENT_ID` is nil (`telemetry/rust/src/ids.rs:17`), so
        `Parent {}` decodes as the System parent. The server cannot tell
        "not set" from "System", so the `REQUEST_INVALID` rule for an
        unspecified enum cannot catch it. Proposal: make the choice explicit
        with `oneof parent { SystemParent system = 1; common.ParentId user =
        2; }`, so nothing set is rejected. Adding `PARENT_TYPE_UNSPECIFIED` to
        `common` instead would renumber the stored `UInt8` values.
      - **"Trusted inside the infrastructure" means the whole VPC.** NATS has
        no auth and no TLS, and its VM has only a private address
        (`infra/infra/nats.ts:45-49`). Any process in the VPC can ask for any
        parent's logs or any account's rows. GCP checks IAM on every
        `resource_names` entry in the service itself. Proposal: NATS users
        with subject permissions, so only the application server and the
        strategy runtimes may send on the query subjects. If a caller inside
        the VPC can run user code, the entry point should also sign the
        scope, and the server should verify the signature.
  - **The fold and sharding (decisions 14 and 19).** The accounting book lives
    in one event-gw instance's memory, and so does its record of folded event
    ids (decision 25). If instances share the sim venue feed through a queue
    group, each instance folds only part of an account's events. While the
    fold stays in event-gw, the sim venue feed must reach a single instance.
    Today there is only one instance (`manualInstanceCount: 1`).
  - Answered in decisions 22–25: W covering the aggregate rows, limits for D5
    and D6, who calls event-gw for `/api/v0/positions`, and live duplicates
    in the fold.

- **Accounting service, deferred** (agent notes, 2026-09-29, not decided).
  These are kept for when decision 19 is revisited.
  - Fold order comes from the venue, not from ingestion. sim-gw stamps each
    fill, fee, deposit and withdrawal with a contiguous sequence number per
    account. The fold
    applies `last + 1`, drops anything at or below `last`, and holds anything
    above. This also fixes live duplicates.
  - The accounting service reads committed raw rows up to W from ClickHouse
    instead of subscribing. event-gw stays the durable ingestion boundary. The
    sim venue feed needs at-least-once delivery (Pub/Sub, acked after all rows
    are inserted), or a lost event is a permanent hole.
  - Checkpoints: the whole book plus the input cursor and the per-account
    frontiers. They replace the full-history read at startup.
  - The service numbers its own output rows; it doesn't need the sequencer
    for them. It serves its own queries and tails: current positions from
    memory, history from ClickHouse.
  - Four copies of the average-price and realized PnL logic diverge today:
    event-gw, sim-gw, the backtest sim venue and backtest-post-processor.
    event-gw rounds the average price, ignores the settlement multiplier and
    books no quote side for spot fills. They merge into one crate before the
    split.
  - The fold's dependency is per trading account, so it can be partitioned by
    account later. It is not a global order.
  - TigerBeetle: quantity, cost basis, realized PnL, fees, volume and turnover
    map to accounts; average price does not, because TigerBeetle has no
    division. A fill is linked transfers across the instrument ledger and the
    quote ledger (TigerBeetle's currency-exchange recipe).


- **Log tail as a feed** (asked 2026-09-28, decided 2026-09-29). The user named two
  candidates:
  1. The application server queries ClickHouse on a timer for each
     subscription (every 2 s).
  2. event-gw republishes every stored `event_logs` row as a data feed, and the
     application server republishes the rows to the matching client
     subscriptions.

  event-gw already republishes other traffic on NATS: Pub/Sub `DataFeed`
  payloads 1:1 (`logic/event_log.rs:15`) and the trading account feed
  (`logic/trading_account_publication.rs`). `EventLog` rows are only stored,
  not republished.
  - **Decided 2026-09-29 (decision 10):** candidate 1, polling, with the
    orderand as the cursor.

- **Recovering missed rows in the log feed** (proposed by the agent
  2026-09-28, not accepted). This follows from decision 8. The proposal:
  - **Server to client.** Each delivery carries an opaque resume position into
    the owner's full, unfiltered stream. It means "complete up to here for
    your filter".
    - The server also sends a position-only message when nothing has
      matched for a while.
    - To resume, the client sends the position back. The server fills the gap
      from ClickHouse (`owner AND ingestion_orderand > P AND <filter>`), then
      goes live.
    - The client de-duplicates by `event_id`.
    - The gateway cancels the subscription (`ServerSubscriptionError`,
      DEC-0BBPJ) instead of silently dropping messages under backpressure.
  - **event-gw to application server.** This hop carries a per-owner feed with
    no filter, so `ingestion_orderand` is usable here.
    - event-gw publishes a row only after the ClickHouse insert is confirmed.
    - It publishes in `ingestion_orderand` order: only up to the last
      contiguous confirmed batch.
    - The application server refills from its last position after a NATS
      reconnect or a slow-consumer error.
  - **Found while checking this.** Data feeds run on plain NATS, which delivers
    at most once. `data-feed-core` has no per-message sequence number, and
    nothing uses JetStream. Detecting a single lost message on this hop would
    need a contiguous per-owner sequence number from event-gw, or JetStream.
  - **Superseded in part by decision 8a:** the orderand-based parts of this
    proposal do not hold with several event-gw instances.
  - **Superseded by decisions 10 and 12 (2026-09-29):** the tail polls by
    cursor, so nothing needs to be recovered.

- **NATS for the client subscription stream instead of websockets** (asked
  2026-09-28, not decided). Facts gathered on 2026-09-28:
  - **NATS today** (`infra/infra/configs/nats-server.yaml`): a plain `nats`
    container on ports 4222, 6222 and 8222. It has no config file, so no
    JetStream, no websocket listener, no auth and no TLS.
  - **DEC-0BEKM** (proposed): realtime-gateway is the only public server and
    the authorization boundary. Clients connecting to NATS directly would
    contradict it.
  - **DEC-0BBJ8** (accepted): the gateway's NATS dispatcher uses a
    non-blocking send to each client. A failed send drops that event, and the
    subscription is not cancelled. So the websocket path can also lose events
    silently, and the client would not know.
  - **JetStream would give** a stream sequence assigned by the NATS server,
    independent of how many event-gw instances publish. That is usable as a
    resume position. It would also give a consumer sequence that is
    contiguous for a filtered consumer, which is usable for gap detection.
  - **Superseded in part by decision 8b:** JetStream is rejected.

- **Application-level sequencing and recovery** (proposed by the agent
  2026-09-29, not accepted). It follows the pattern of exchange market data
  (CME MDP 3.0 snapshot + incremental, Nasdaq MoldUDP64 rewinder), FIX sessions
  (MsgSeqNum, ResendRequest, SequenceReset) and Kubernetes list+watch
  (resourceVersion, 410 Gone, relist).
  - **Messages.** Every message of a stream carries `(stream_id, epoch, seq)`.
    - One sequencer owns each stream.
    - `seq` is contiguous from 1 within an epoch.
    - The epoch changes whenever the sequencer's state is lost (restart,
      failover).
  - **Receiver rules.**
    - `seq == last + 1`: apply.
    - `seq <= last`: duplicate, drop.
    - `seq > last + 1`: gap, recover.
    - New epoch: full resync.
  - **Heartbeats** carry the current `seq`, so the loss of the last message is
    also detected when there is no other traffic.
  - **Recovery, tier 1:** the sender keeps a bounded retransmit buffer and
    replays the missing range.
  - **Recovery, tier 2:** when the range is older than the buffer, the sender
    answers "reset". The receiver then:
    1. keeps buffering live messages;
    2. takes a snapshot (for logs, the ClickHouse page query) that is tagged
       with the `seq` it is consistent up to;
    3. drops buffered messages at or below that `seq`, and goes live.
  - **Where sequencing happens.** Sequence after filtering: the application
    server sequences each filtered feed binding.
    - The gateway fans out the application server's sequence unchanged in the
      header frame, so the client detects gaps end to end. That includes
      drops by the gateway itself (DEC-0BBJ8).
    - Recovery requests go client → gateway → application server.
  - **Third boundary** (event-gw instances → application server): the same
    pattern, with one stream per event-gw instance and owner, and the epoch
    changing on instance restart.
  - **Not adopted (decision 10, 2026-09-29):** polling needs no gap detection.
    Kept as the option if push is needed later.

