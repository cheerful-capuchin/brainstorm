---
create_time: 2026-10-07T15:48:09Z
title: "Workflow activity completion race and the backtest download stream branch"
summary: "activities:complete 500 'Running activity poll_execution not found' spammed Discord: tick created the activity task before addRunningActivity; fix marks running first (new Convex removeRunningActivity rollback) and complete acks a not-running activity; structure-web branch backtest-download-stream off origin/main also carries the streamed results download; depends on uncommitted gcp requestStream; not pushed; the six backtests finished 15:38-15:46 and the alerts stopped; internal endpoints adopt the caller x-trace-id after auth (f30f2dbd2); one trace id per workflow stored in Convex, inherited by children, sent on ticks/activities/callbacks (3088cdd0a); activities-api logs via argus; dev-env notebook activity-complete-race"
related_sessions:
  - SESS-00PYCE2
  - SESS-00PE96K
---

# SESS-00Q1C5S: Workflow activity completion race and the backtest download stream branch

## Context (2026-10-07)

Discord received an alert on almost every backtest poll from the production
application-server (`stxr-prop`, `asia-northeast1`, revision
`application-server-00005-2wd`, deployed 2026-10-01):

```
POST /api/v0/activities:complete -> 500
ApiError[INTERNAL]: Running activity 'poll_execution' not found
```

Facts measured from Cloud Logging and Cloud Run:

- 135 `activities.complete.activity_not_found` errors, all for
  `poll_execution`, all after 2026-10-07T15:18. None in the 14 days before.
- Six backtest executions (`s-02syk09pg0400-r-0000000000001-bt-*`) started at
  15:17:57 to 15:18:03. They were still running at 15:35 (progress logs about
  229M ticks). The previous single backtest (`bt-0y9wcez7hv1ad`) took about
  22 minutes and succeeded.
- No deploy happened that day. The race was always there; six concurrent
  backtests changed the timing.
- At 14:35, with one backtest running, the callback came about 0.5 s after
  `running_activities_updated`. At 15:27 it came about 10 ms after the task
  was created, while the running-state write took about 450 ms.
- Each rejected callback was retried by Cloud Tasks 5 s later (queue
  `workflows-tokyo`: min backoff 5 s, max 15 attempts) and then succeeded.
  416 callbacks answered 200 and 214 answered 500 in 30 minutes. No task was
  stuck in the queue. Workflow tick versions kept rising (one workflow reached
  212).
- The user reported "It doesn't move on". The workflows did move: they stay
  on the `poll_execution` step until the Cloud Run execution finishes, and
  every poll cycle produced one alert.
- The Postgres proxy and Convex data were not needed; the logs were enough.
- All six executions succeeded between 15:38:50 and 15:46:28, and the errors
  stopped with them (277 `activity_not_found` from 15:18 to about 15:46).
  The race comes back with the next set of concurrent backtests until the
  fix is deployed.

## Cause

In `structure-web` `packages/api/src/workflows/workflows-service.ts`, the
tick handled a `RUN` command in this order:

1. `scheduleActivityRun` creates the Cloud Task for the activity worker.
2. After all commands: `getWorkflow`, then `addRunningActivity`, then
   `getWorkflow` again (about 450 ms under load).

The activity worker runs `poll_execution` in about 60 ms and posts
`activities:complete` through the callback queue. When the callback came
before step 2, `runningActivities` had no entry, and
`activities-api.ts` returned `ErrorCode.Internal`. The JSON handler logs
that as an ALERT, which goes to Discord.

## Decisions

### D1. Commit the feature branch, fix on a separate branch from main (2026-10-07)

The user asked to commit the current `structure-web` changes, push the
feature branch, then branch from main so the fixes "don't collide" with the
feature work.

- `dec-0bzbc-strategy-deployment-entity`: commit `ae40d1c0e` ("checkpoint:
  Avro blob storage, alert-service incidents and strategy config work in
  progress"), pushed as a new remote branch. Scratch files left untracked:
  `p.md`, `packages/api/t.ts`, `prompts/`, `ai-docs`,
  `migrations/portfolio.txt`, `.githooks/`, `.run/`,
  `.opencode/package-lock.json`,
  `docs/plans/2026-05-19-market-info-catalog.md`.
- New branch `backtest-download-stream` from `origin/main` (`5e368e24a`),
  upstream unset. Local `main` was behind `origin/main`.

### D2. Carry the streamed results download to the new branch (2026-10-07)

The user asked to copy "the backtest download fix stream http instead of
buffer in memory". It was in feature commit `255247276` ("[PLAN-0BZET
T3/A1] review fixes"), mixed with log and timestamp changes. Only the
`packages/api/src/backtests/` part was applied, as commit `8610f3c1d`:

- `BacktestRepository.downloadResults` opens the results database with
  `GcpClient.requestStream` and `Storage.parseDownloadObjectStreamResponse`.
- `downloadResultsBuffered` keeps reading the small `summary.json` into
  memory.
- `BacktestService.downloadResults` passes only `cache-control`, `etag` and
  `last-modified` from GCS. Without `content-length` the response is chunked;
  Cloud Run rejects buffered responses above 32 MiB.

Open: `requestStream` and `parseDownloadObjectStreamResponse` exist only as
uncommitted changes in the local `gcp` repo (`ts/gcp/src/runtime/client.ts`,
`ts/gcp/src/storage/mod.ts`, on its `main`). The branch does not build for
anyone else until they are pushed. `HttpClient.StreamResponse` is already
committed in `ipc` (`ts/http-client`).

### D3. Mark the activity running before its task exists (2026-10-07)

The user asked to "apply fixes there". Commit `918823ec7`:

- The `RUN` branch calls `addRunningActivity` (tick version + 1) for that
  activity before `scheduleActivityRun`. The batch `addRunningActivity` after
  the command loop is removed.
- When the task cannot be created and the activity was not running before
  this tick, the new Convex mutation `removeRunningActivity` deletes the
  entry, only if the attempt matches. It does not change the tick version, so
  the failure retry tick is still accepted. Without the rollback,
  `runIfMissing` in the reducers would see the activity as running and never
  schedule it again.
- A retry (entry already present, set by `activityFailedWithRetry`) keeps its
  entry, as before.

Rejected: delaying the worker task, and only downgrading the error. Both
leave the race in place.

### D4. activities:complete acknowledges an activity that is not running (2026-10-07)

After D3 an early callback cannot happen. A callback for an activity that is
not running can only repeat one already recorded (Cloud Tasks delivers at
least once). It now logs `activities.complete.activity_not_running` as a
warning and answers 200. The 500 had Cloud Tasks retry up to 15 times, each
with an alert.

Not changed: the attempt mismatch path in `complete` still answers
`Internal` (500), and `fail` still answers `NotFound` for a missing activity.

### D5. Internal endpoints take the caller's x-trace-id (2026-10-07)

The user asked whether the request trace id is set every time. It is sent:
the tick sets `x-trace-id` to the activity id on the worker task, the worker
adopts it (`activity-worker/src/routes.ts`), and sends it back on the
callbacks. The application-server ignored it since `5e2199631`
(2026-07-23, by a colleague: "The trace id is generated server side"), so
each callback, each Cloud Tasks retry and each Discord alert had its own
ULID.

The user accepted: "Yeah, let's do that. Keep it wherever there is a fix
for the activities". Commit `f30f2dbd2` on `backtest-download-stream`:

- `CallerTraceID()` in `packages/api/src/lib/api.ts`, added after the
  authentication middleware on the 18 internal routes (not on
  `/openapi.internal.json`, which has no authentication).
- Accepted values match `^[A-Za-z0-9+/=_-]{1,128}$` (base64 activity ids,
  ULIDs, `trace_` ids); anything else is ignored with a
  `api.caller_trace_id.invalid` warning.
- Public requests keep the server ULID. The request log line keeps the ULID;
  `api.caller_trace_id.adopted caller_trace_id=...` links the two.
- Table test in `src/lib/api.test.ts` (8 cases); the file's 9 tests pass.

Not done: tick tasks (`enqueueTickTask`) send no `x-trace-id`, so ticks keep
server trace ids.

### D6. One trace id per workflow, start to end; argus in activities-api (2026-10-07)

The user asked why the activity trace id is base64 and not a ULID. It is the
callback token (`encodeActivityID`: workflow id, activity name, attempt,
base64), reused as `x-trace-id` since `ca6f1de7d` (2025-10-08). It is not
unique per run: every `poll_execution` cycle is attempt 1.

The user decided: "Ideally, everything from start workflow until finished
workflow should have the same trace id. and use argus in the
activities-api, not simple logger". Commit `3088cdd0a`:

- Convex `workflows.traceId` (`v.optional`, as a migration: older workflows
  have none). `Workflow.traceID(wf)` falls back to the workflow id.
- `startWorkflow` stores `context().traceID`; child workflows inherit the
  parent's. `enqueueTickTask` takes `traceID` (all 13 call sites);
  `scheduleActivityRun` and `ActivityWorker.buildTaskHttpRequest` send the
  workflow trace id instead of the activity id.
- The internal client (`app/internal-client.ts`) sets `x-trace-id` from the
  context in a ky `beforeRequest` hook, so `POST /backtests` -> internal
  `workflows:start` keeps the user request's ULID for the whole workflow.
- Activity worker: `ActivityJob.details.traceID` is the request's trace id
  (from the header); `executeJob` no longer switches to the activity id.
- `CallerTraceID` accepts `^[A-Za-z0-9_-]{1,128}$` (no `+ / =`); test cases
  for workflow ids and rejected base64.
- `activities-api.ts`: 27 logger calls -> argus with snake_case fields.
  `logger.error` became `argus.warn`, because the JSON handler alerts on
  every code the handler returns (`ERROR_CODE_TO_REPORT` includes
  InvalidArgument, NotFound, FailedPrecondition "for the release period")
  and argus ERROR goes to Discord (`minSeverity: ERROR`), which would alert
  twice.

Not changed: `activities:fail` still answers NotFound / FailedPrecondition
for a missing activity or attempt mismatch, which alerts and is retried.

## Verification

- `just typecheck` in `packages/api` stops at pnpm's dependency check
  (`ERR_PNPM_EXOTIC_SUBDEP`): main's `package.json` differs from the
  installed modules. The root lockfile was not modified.
- `node_modules/.bin/tsc --noEmit` gives the same 286 errors with and
  without the changes (compared ignoring positions). They come from local
  sibling repos ahead of main, such as `strategy-core`
  (`StrategyRevision.Status`).
- No tests: main has no test harness for the workflow tick.

## Open

- Push `backtest-download-stream`; commit and push the `gcp` streaming
  helpers. The user has not decided.
- Deploy order: `just convex_prod` (new `removeRunningActivity`, optional
  `traceId` field) before the application-server; deploy the activity worker
  with it.
- Code not formatted (structure-web rule: formatting is a human task before
  the PR); `just check` will flag `activities-api.ts` until `just fmt api`.

## dev-env

Notebook `activity-complete-race` in session `sess-00q1c5s` explains the
race and the fix, and its cell `complete-errors` counts
`activity_not_found` and `activity_not_running` per 10 minutes from Cloud
Logging (last 6 hours). The first real run showed 19, 123, 124 and 11
errors in the 15:10 to 15:40 buckets.
