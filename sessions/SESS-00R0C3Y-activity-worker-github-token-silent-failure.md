---
create_time: 2026-10-19T09:57:18Z
title: "Activity worker expired GitHub token and failed workflows raised no alert"
summary: "Investigation, no decisions yet. 2026-10-18 09:07-14:50 UTC activity worker static GitHub PAT (from 2026-05-11, never rotated) returned 401 for prepare_template: 37 workflows failed (17 backtests, 20 strategy starts); fixed by rotation 17:06. Worker logs INFO text only; engine logs INFO/NOTICE, drops the cause, child StrategyBuild stays running; strategy-deployment-failed policy filter matches no existing log line; backtest-failed fired 11 incidents but notify-gw has failed every Discord delivery since 2026-10-16 19:11 (556+ alerts stuck). User wants alerts in the activity worker and the workflow engine."
related_sessions:
  - SESS-00QKS30
  - SESS-00Q1C5S
  - SESS-00R0BCD
agents:
  - claude-code:cf5e8cbc-edbd-4b80-acd7-c1684ee33cfd
---

# SESS-00R0C3Y: Activity worker expired GitHub token and failed workflows raised no alert

## Trigger (2026-10-19)

On Sunday 2026-10-18 the activity worker ran with an expired GitHub token
and nobody was notified: neither the activity worker nor the workflow
engine (for the workflow that failed because of it) raised an alert.

User position: alerting is needed in both places, the activity worker and
the workflow engine on a failed workflow; otherwise it is a silent failure.

## Findings: code paths (agent code read, 2026-10-19)

### Token

- Static fine-grained PAT, read once at boot from env `GITHUB_TOKEN`
  (`activity-worker/src/config.ts` `github_api_token_var`), one client for
  the process lifetime (`run.ts`). No GitHub App, no refresh.
- Infra: Pulumi secret `activity_worker:gh_token` -> Secret Manager
  `activity-worker-gh-token` (asia-northeast1), env `secretKeyRef` pinned to
  that version (`infra/workflow/activity-worker.ts`). Rotation =
  `pulumi config set --secret` + `pulumi up` (new version, new revision).
- Only `prepare_template` uses it (zipball of the strategy source repo via
  `loadGitHubRepoSourceCode`). Skipped when the prepared template or source
  zip is cached, or the image already exists, so an expired token only
  breaks builds of new strategy revisions.
- A 401 becomes a plain `Error`
  (`github.download_repository_zip_archive.unsuccessful_response status=401`);
  ky does not retry 401.

### Activity worker on failure

- `jobs.ts`: only timeouts get `RetryInfo`; anything else is wrapped as
  `ErrorCode.Unknown` without `RetryInfo`, so non-retryable.
- One INFO line `jobs.execute_activity_job.end ...;result=err=...`; text
  logger via `console.log`, so Cloud Logging gets `textPayload` with
  DEFAULT severity. No argus call on this path.
- Failure reported to the engine by a Cloud Task POST to
  `/api/v0/activities:fail`.
- AlertSink is back in the worker (`run.ts`, minSeverity ERROR, feeds
  topic; re-added 2026-10-15 with the infra publisher grant), contrary to
  the SESS-00QKS30 note that it had been removed. It only sees
  `argus.error`/`argus.alert`, which this path never emits.

### Workflow engine on failure

- `activities-api.ts` `activities:fail`: non-retryable or attempts >=
  MAX_ATTEMPTS (5) -> notify the parent activity, or tick the workflow
  itself. Logs only at INFO.
- `StrategyBuild` runs only as a child (from backtest and strategy start
  reducers). Its failed activity notifies the parent directly; the child
  workflow itself is never marked failed and stays `running` with no
  further tick.
- Parent `FAIL` (`workflows-service.ts`, `ENSURE_IMAGE_FAILED`):
  - Backtest: `BacktestService.failRun` -> `Backtest.Event.Failed` at
    NOTICE (`stxr.trading.backtests.v1.failed`), with `ApiError.nil()`, so
    the cause is dropped; nothing if the backtest is already terminal or
    deleted.
  - StrategyStart/Stop: revision status change event at NOTICE, no failed
    log.
  - No `argus.alert` on any workflow failure; the only workflow alerts are
    logic errors.

### Infra policies

- `services/health-alerts.ts`: crash/probe/OOM/CPU/memory only.
- `strategies/alerts.ts` `backtest-failed`: matches
  `textPayload:"stxr.trading.backtests.v1.failed"` on application-server;
  would fire for a failed Backtest if the line was logged.
- `strategies/alerts.ts` `strategy-deployment-failed`: matches
  `strategy_deployment_revisions_service.complete_workflow.failed`, a
  string that exists nowhere in structure-web. It can never fire, so
  strategy start/stop failures are silent.
- No policy on activity-worker logs at all.

### Candidate alert points

1. Activity worker, `jobs.ts` `result.isErr()` branch (argus.error/alert
   through its AlertSink); narrower: tag 401/403 in `github.ts`.
2. Engine, `activities-api.ts` non-retryable/exhausted branch: covers
   every activity including child workflows.
3. Engine, `workflows-service.ts` `FAIL` case: covers every workflow type.
4. Infra: fix or remove the dead `strategy-deployment-failed` filter.

## Findings: production logs (agent log read, project stxr-prop, UTC)

### Incident timeline

- Activity worker = Cloud Run `activity-worker-tokyo` (asia-northeast1),
  revision `activity-worker-tokyo-00024-2tx` during the failures.
- Last successful GitHub download before: 2026-10-16 14:09:35. No worker
  traffic on 10-17. First 401 "Bad credentials": 2026-10-18 09:07:00
  (trace 01m57469r8m686v2hm165qfqrm); last: 14:50:54.
- 37 failed `prepare_template` activities, one workflow each: 17 backtests
  (first bt_02XET3ZEG0400, two re-run with `:run` and failed again) and 20
  strategy starts (`strategies:start` and `execute`).
- Fix: secret `activity-worker-gh-token` v2 added 2026-10-18 17:06:00 by
  bsun@stxr.io, service revision 00025-kht at 17:06:15, v1 destroyed
  17:06:54. v1 dated 2026-05-11, never rotated before. Successful builds
  from 17:12:34 on.
- Worker log lines are text `[INFO ]` with no Cloud Logging severity; each
  error spans ~16 log entries (GitHub JSON body + stack frames); the trace
  id is on the start and notify_activity_failure lines, not on the error.

### What alerted and what did not

- Backtests: application-server logged `[NOTIC] stxr.trading.backtests.v1.failed`
  with `error: ApiError[UNKNOWN]: : []` (cause lost). The `backtest-failed`
  policy fired: 11 incidents published to Pub/Sub `monitoring-incidents`
  between 09:00 and 15:00.
- Strategy starts: revision `stopped -> baking -> stopped`, no failure
  event; `strategy-deployment-failed` cannot match (dead filter).
- Nothing at ERROR/ALERT in application-server for any of the 37 traces.

### notify-gw has delivered nothing since 2026-10-16 19:11 (separate, ongoing)

- notify-gw worker pool revision `notify-gw-00004-xtz` (since 10-16
  15:19) logs only `ERROR notify_gw.delivery.gave_up correlation_id=N;attempts=8`
  since 2026-10-16 19:11: 606 lines in bursts ~every 33 min, no successful
  delivery in the window. The per-attempt cause is not logged
  (`monitoring/rust/crates/notify-gw/src/logic/delivery.rs` gives up on
  timeout, protocol error, 5xx or rate limit).
- `notify-gw-alerts-feed-sub`: ~556 undelivered, oldest ~67 h (since
  ~10-16 14:00), still growing. Incident subscription backed up to 8
  (oldest ~6.4 h) on 10-18 before draining.
- `discord-webhook` secret has only v1 (2026-05-11).
- So even the backtest alert that fired never reached Discord, and every
  other alert since 10-16 evening is silent too. This is the larger gap.

## Q1 (user, 2026-10-19): store alerts in ClickHouse for a dashboard or an AI agent?

Not decided. Agent answer: yes, as history and as a second, independent
check, but not as the way people get notified.
- Today nothing stores alerts: event-gw has no alerts feed consumer; the
  alerts feed (Topic.Feeds) and Cloud Monitoring incidents
  (`monitoring-incidents`) are read only by notify-gw.
- Proposal P1: event-gw subscribes to the alerts feed with its own
  subscription (one feed + encoding per subscription) and writes an
  `alerts` table; notify-gw emits a delivery outcome per alert
  (delivered / gave_up + cause) that lands next to it. "Raised but not
  delivered" becomes one query; the 2026-10-16..19 outage would have
  shown as hundreds of undelivered rows.
- Incidents from Cloud Monitoring need the same path to be in the table.
- A dashboard or an agent that polls is pull: nobody looks on a Sunday,
  and an agent that notifies needs a channel and its own monitoring. Fit:
  daily digest, grouping and triage; not paging.
- It would not have caught Sunday's strategy starts: those never produced
  an alert at all. Emitting alerts at the source (worker, engine) is still
  needed.
- P2: a watchdog on notify-gw that does not go through notify-gw, e.g. a
  Cloud Monitoring policy on `notify_gw.delivery.gave_up` (or no
  successful delivery for N hours) to an email channel.
