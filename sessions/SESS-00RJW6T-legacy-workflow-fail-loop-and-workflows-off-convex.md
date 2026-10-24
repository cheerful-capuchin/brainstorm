---
create_time: 2026-10-26T10:22:18Z
title: "Legacy backtest workflow fail loop and moving workflows off Convex"
summary: "D1 fail pre-2026-10-15 workflows; D2 narrow fail-path parse; D3 workflows to app-db Postgres + Avro (DEC-0D3NG, kb #213 merged as proposed); D4 app-db conventions; D5 no Convex migration; D6 step u32, trace_id u128; D7 .avsc history test; D8 startup check alerts only"
related_sessions:
  - SESS-00QNZ2Y
  - SESS-00Q1C5S
  - SESS-00R0BCD
agents:
  - claude-code:15215f4c-e8d2-4a80-9f83-69a60909b367
  - claude-code:1e510f75-c30b-42e0-8948-f1114d785f50
---

# SESS-00RJW6T: Legacy backtest workflow fail loop and moving workflows off Convex

## Context (2026-10-26)

Production deploy of structure-web a704d3d (application-server image built on
market-info 577eb62, application-server 3f7f67e wasm). Right after it, the
application-server logged, at growing intervals since 10:00:12 UTC:

```
[ERROR] workflow_service.engine_fail reason=deadline_exceeded;workflow_id=ns710q7xa9x1abbp50rnc41y7182b4x5;type=Backtest;step=poll_execution;tick_version=250;deadline_at=undefined;...
[ALERT] json_handler.response_error path=/api/v0/workflows:tick;...;error=Error: workflow_service.backtest_of_workflow.invalid_input err=[
```

Findings:

- The workflow has no stored `deadlineAt` (created before deadlines were
  stored), so its deadline is `createdAt + LEGACY_DEADLINE` (8 days,
  `packages/api/src/workflows/workflows-service.ts`).
- It had been dormant: no log line mentions it in the 30 days of retention
  before 10:00:05 UTC today. The first line is
  `workflow_service.fail_overdue.ticked` from the deadline sweep. structure-web
  #231 (in this deploy) made the sweep page past workflows it cannot read and
  give legacy workflows the 8-day deadline, so the sweep now reaches them.
- Failing a Backtest workflow calls `backtestOfWorkflow`, which parses the
  whole stored `input` against the current `BacktestInput`
  (`packages/workflow/src/reducers/backtest-reducer.ts`). The old input does
  not parse (most likely missing `cloudrun_job_timeout_s`, added 2026-10-15
  in 9ec31418a, see SESS-00QNZ2Y; the zod error was lost because the
  multi-line text log line was split). The tick returns an error, the
  workflow never reaches failed, and Convex/Cloud Tasks retry it with backoff,
  each retry logging an ALERT line.
- Same class of failure recurs whenever a required field is added to a
  workflow input or state while workflows of that type are running.

## Decisions

### D1: fail the old workflows, don't delete them

User: "is this just an issue with the old workflows? We can get rid of them."
Assistant proposed failing rather than deleting, because each Backtest
workflow has a backtest row in Postgres that still says running; deleting the
workflow leaves it. User accepted ("do 1 & 2").

- A one-off cleanup script fails every running workflow created before
  2026-10-15, together with its backtest or strategy record.
- Affects: structure-web (script), production Convex + Postgres.
- Open: the exact cutoff; the assistant proposed "before 2026-10-15" (the
  `cloudrun_job_timeout_s` change) and asked the user to confirm how far
  back to go.

### D2: the fail path parses only the ids it needs

Assistant proposal accepted by the user ("do 1 & 2"):
`backtestOfWorkflow` validates only `backtest_id`, `strategy_id` and
`strategy_revision`, so a workflow whose input predates the current schema
can still be failed and the retry loop stops. Test with an old-format input.

- Affects: structure-web `packages/api/src/workflows/workflows-service.ts`.

### D3: move workflows from Convex to the application-server Postgres, payloads in Avro

User proposed: "we can get rid of convex if you can move workflows to the
application server database and use apache avro to store the payloads."
User asked for a decision document in the knowledge base.

Facts gathered for it:

- Convex's schema has two tables, `kv` and `workflows`; kv is already read
  from Postgres (`PgKV`), so `workflows` is all that's left in Convex.
- Ticks are queued through Cloud Tasks and the deadline sweep runs from a
  scheduler job, so scheduling does not depend on Convex.
- Ticks write Postgres and then Convex; the code works around the gap
  ("a failed write fails the tick, and the retried tick records it").
- Releases need `just convex_prod` right before `pulumi up` when Convex
  function shapes change (#228, #231 today).
- SESS-00R0BCD measured ~220 ms per Convex call in tick/activity latency.

Assistant recommendations (part of the proposal, the user has not ruled on
them individually):

- Every row stores the fingerprint of the Avro writer schema; known schemas
  are kept in a table; reads go through Avro schema resolution; CI checks
  that each new schema reads every recorded one. Without that check Avro
  fails the same way zod does today.
- Alternative considered: `jsonb` with a schema version per row and explicit
  upgrade functions (payloads stay queryable in SQL, migrations are written
  by hand). Recommended Avro because structure-web already uses Avro
  (DEC-0C6J2).

Formalized as DEC-0D3NG (proposed), knowledge-base PR #213
(https://github.com/stxr-prop/knowledge-base/pull/213), branch
`dec-workflows-postgres-avro`. It builds on DEC-0C6J2 (Avro blobs +
`avro_schemas`) and ISS-0CYT8 (tick fencing). The DEC takes precedence over
this record once accepted.

### D4: the DEC-0D3NG table sketch follows the app-db schema conventions

User (2026-10-26, reviewing PR #213): "the decision document SQL schema
doesn't match the structure-web/packages/app-db standards. Ensure it does".

- Conventions applied (from the `schema.ts` guideline comment and
  REF:application-db): `id` and u64 values `numeric(20,0)`, times as unix ns
  `bigint`, enums (`type`, `status`) as `smallint` enforced in code, no
  nullable columns (`0` / `''` mean absent: `parent_workflow_id`,
  `parent_activity_name`, `next_run_time = 0` means run on the next tick), no
  foreign keys, `varchar` not `text`, blob columns commented with their
  `structure.app_db.*` type, `tick_version` is u64 `numeric(20,0)`.
- Indexes from query shape: the deadline sweep (`status = running AND
  deadline_time < $before ORDER BY deadline_time, id`) is the only list query
  the api runs, so one partial index `idx_workflows_running_by_deadline` on
  `(deadline_time, id) WHERE status = running`. Convex's `by_status_type`,
  `by_type`, `by_createdAt` serve only `listWorkflows`, which has no caller;
  `by_nextRunAt` has no query. Not carried over.
- The fenced UPDATE sets `update_time = $now` from the application clock.

### D5: Convex workflow rows are not migrated

User: "I don't need to migrate the convex rows".

- From the cutover release on, workflows are created and ticked only in
  Postgres; workflows still running in Convex at the cutover stop. Convex is
  removed in the cutover (DEC-0D3NG Decision 5 and 6).
- Removes the migration, id mapping (Convex string ids vs u64), dual-read and
  legacy-row (missing deadline / trace id) questions.
- Still open in the DEC: what happens to work the stopped workflows drove
  (backtest jobs, backtests left running) and how a tick or callback carrying
  a Convex id is acknowledged so Cloud Tasks stops retrying; rollback across
  the cutover loses Postgres workflows.

### D6: `step` is a u32, `trace_id` is the u128 TraceID

- `step`: user: "put a regular u32" (instead of the assistant's smallint
  enum). Stored as Postgres `integer`.
- `trace_id`: user asked whether anything uses text trace ids or everything
  u128. Found: `TraceID` in `@structure/telemetry` is u128, logger2 stores
  `[u8; 16]` big-endian, ClickHouse uses `UInt128`; only the api carries the
  ULID text in its request context, and that text parses into the same
  `TraceID` (`trading-accounts-handler.ts` does it). The DEC stores it as
  `bytea`, 16 bytes big-endian; the repository parses before writing. The
  user went on to merge the DEC with it.

### D7: Avro compatibility check = committed .avsc history + app-db test

The user did not know how Avro works in app-db; findings: storage types are
listed in `AppDbAvro.ALL` (`packages/app-db/src/avro/storage-types.ts`); the
api inserts them into `avro_schemas` (a Postgres table, append-only by
trigger) at startup (`AvroSchemasRepository.registerAll`, `api/src/run.ts`).
structure-web has no CI pipeline (`.github` holds only a PR template), and
`check-app-db` in the root justfile runs fmt, lint, typecheck but no tests.

User accepted ("yes") each of:

1. Add the app-db tests to `just check` (`check-app-db` gets `ts-test`).
2. Commit the schema history: `packages/app-db/avro-schemas/<fingerprint>.avsc`,
   one per writer schema ever shipped, seeded once from production
   `avro_schemas`, never edited or deleted.
3. An app-db test: every type in `ALL` has its file; file name equals the
   fingerprint of its content; every file resolves (`createResolver`) against
   the type of the same full name, unless the name is listed as retired with
   an upgrade function.

The user asked for the simplest way to keep the files up to date; written
into the DEC (assistant proposal, merged by the user): the test writes a
missing file and fails once, snapshot style, never overwriting; `just build
application-server` (which infra's Docker image build runs) also runs `just
check app-db`; `encode` refuses a type not in `ALL`. A probe confirmed avsc
rejects at resolver build time: removed union branch, added field without
default, removed enum symbol without enum default.

### D8: the startup check alerts, it never blocks startup

The user asked what "current reader" meant and confirmed the shape: the api
reads the `avro_schemas` rows and checks each against the in-memory type with
the same `full_name`. Accepted ("Okay, sounds good. Update the DEC document"):

- Each row that does not resolve is logged as an alert; startup never fails,
  because after a rollback an older build cannot resolve a newer schema that
  appended a union branch, and failing would block the rollback.
- A `full_name` the build has no type for (added by a newer release) is
  skipped unless listed as retired.
- Purpose: catch a schema that reached production without a committed file.
  The committed-files test is the gate; this is the backstop.

### DEC-0D3NG merged as proposed

D4-D8 are in DEC-0D3NG. User asked to sign and merge: knowledge-base PR #213
merged 2026-10-26 (merge commit be2fff3, branch commits re-signed as 70405e3,
6bdcbcc). The DEC status is still `proposed`. The DEC takes precedence over
this record.

## Open

- Cutoff date for D1.
- DEC-0D3NG open questions: fate of work driven by stopped Convex workflows
  and stray Convex-id ticks/callbacks, rollback across the cutover,
  `running_activities` blob vs child table, tick transaction isolation and
  retry, tests, observability, transition history.
- Whether the Avro check (D7/D8) moves to its own change or a DEC-0C6J2
  amendment, since it covers every app-db blob: raised by the assistant, not
  answered.
