---
create_time: 2026-10-06T12:34:10Z
title: "Databento download job: failures, empty day files, scheduling and alerting"
summary: "databento-download-job: header-only empty day files; no-wait runs, */30 6-14 schedule, 1 task; alerts via Cloud Monitoring -> monitoring-incidents topic -> alert-service -> Discord; alert-service reads one subscription per feed+encoding (alerts feed, incidents feed, legacy alerts topic); dev-env: agent replies refresh window, one socket per instance (dev-env-<pid>.sock), CLI picks window showing the project"
related_sessions:
  - SESS-00PVAZ2
---

# SESS-00PYCE2: Databento download job: failures, empty day files, scheduling and alerting

## Context (2026-10-06)

Two scheduled executions of `databento-download-job` (project `stxr-prop`,
`asia-northeast1`) failed:

- `databento-download-job-7gfbs` (2026-10-04, task 7, day 2026-10-03):
  Databento's download URLs answered 404 for 2-3 random files of a batch job
  that had just turned done (`GLBX-20261004-5VKKN9QX7V`), different files on
  each attempt, including `condition.json`. The job classified 404 as
  permanent: no retry inside the run, and a failure before the header blocks
  every day of the job. Exit 2.
- `databento-download-job-vq2v9` (2026-10-05, tasks 6 and 7): Databento API
  504 Gateway Timeout from about 06:01 to 06:07 UTC. Only `wait_done`
  retried transient errors; `available_range`, `list_jobs`, `list_files`
  did not. Cloud Run retried about 12 s apart, so all 3 attempts hit the
  outage.
- The 2026-10-06 06:00 run (`tjs8g`) filled both days. A manual run
  (`fs84b`) later found nothing to do.

A backtest then failed: replay planner wanted
`GLBX.MDP3/mbp-1/inst_6DNWS5YM8VQ6R/2026-10-03.dbn.zst` (ZFZ6). 2026-10-03 is
a Saturday: CME is closed the whole UTC day, Databento has no file, and the
job logged ZFZ6 as `resolve.not_at_venue`. The day marker existed.

Measured wait from batch job selection to finished download, 10 scheduled
day downloads 2026-09-26 to 2026-10-06: 5, 6, 15, 28, 31, 40, 72, 187, 195,
236 minutes.

## Decisions

### D1. Empty day files are written by the downloader (2026-10-06)

The user rejected fixing the replay planner to skip missing days ("nah, we
should write an empty file. It's a bug in the databento mkt data
downloader"). Refined: "not completely empty, but rather with no mkt data in
a file". Every market-info market listed on a resolved day without a stored
MBP-1 object gets a DBN file with the header only (dataset, mbp-1,
[D, D+1), instrument_id symbology, no symbols). Written before the marker; a
failed one blocks the marker. Implemented in
`databento-mkt-data-download-job` (`core/empty_files.rs`, port method
`FileSourcePort::empty_day_file`). Days marked before this have no empty
files until a backfill (open).

### D2. Runs never wait for Databento; frequent schedule (2026-10-06)

The user did not want to "waste compute just waiting" and asked about a
workflow (submit, then download after ~15 min) or two timers (9:00 submit,
10:00 download). Accepted instead: the default run submits or downloads and
exits; a covering job that is not done leaves its days pending (exit 0,
`download_job.batch.pending`). `--wait` opts back into polling. Scheduler
`*/30 6-14 * * *` UTC.

Rejected: fixed delay split (15 min misses 7 of 10 days, 1 hour misses 4 of
10); Cloud Workflows polling loop (needs a check that runs another execution
or copies Databento API logic into YAML; only useful for backfills). Noted to
the user: waiting compute is cheap (about $0.60 on the worst day), the gain
is robustness.

### D3. Keep sharding by day; 1 task daily, --tasks for backfills (2026-10-06)

The user asked why parallelism is over time and not instrument shards (8
tasks over 7 lookback days left one idle). Answer accepted ("your advice is
sound"): DEC-0BPWJ R2 reasons (single writer per day marker; CME reuses
security ids) and the daily run's time is Databento preparation, not
transfer. Template runs 1 task; backfills pass `--tasks=N`, about a week per
task (month 5, quarter 13, year 52). Instrument/product sharding rejected.

### D4. Retries (2026-10-06)

Databento reads (`available_range`, `list_jobs`, `list_files`) retried on
transient errors, 5 s doubling to 60 s, 6 attempts. 404/410 on a file of a
done job is transient (jobs within 12 h of expiry are never reused). Submit
still not retried on 5xx (no idempotency key).

### D5. Alerting route: Cloud Monitoring -> Pub/Sub -> alert-service -> Discord (2026-10-06)

Chosen by the user over Monitoring -> email and over the job publishing
`Alert.T` itself. Three policies: log match `download_job.overdue` (day
without marker 14 h after it ends; 14 so the 14:00/14:30 runs log it), log
match `download_job.failed retryability=permanent`, metric absence of
`run.googleapis.com/job/completed_execution_count` for 20 h. Notification
channel type `pubsub` on the `alerts` topic. alert-service routes JSON
messages starting with `{` to a Cloud Monitoring incident schema (v1.2).

Finding: alert-service only decodes protobuf `ipc.Message` + JSON `Alert.T`
(TS services). Rust publishers (event-gw, gw-mon, target-executor) send JSON
`EventMsg` or `EventLog` proto and are acked and dropped: 368 decode errors
vs 32 delivered in 14 days. Nothing consumes `monitoring-alerts-sub`. Not
fixed in this session.

### D6. Persist as KB revision and implement (2026-10-06)

User chose "KB revision + implement". DEC-0BPWJ got revision 2026-10-06
(R6-R10) and REF:databento-market-data was updated. Code in
databento-mkt-data, infra, structure-web; all uncommitted.

### D7. dev-env: agent replies must show in the window (2026-10-06)

The user found replies posted with `dev-env annotations reply` missing in
the app ("it's a bug in the app"). Cause: the webview reloads annotation
lists only after its own changes, notebook file changes and saved runs.
Fix accepted ("yeah, fix it"): the socket's reply handler notifies the
window (`AnnotationsView`, Tauri event `agent_annotations_changed`), and the
webview reloads for the active session.

### D8. dev-env: one socket per instance, CLI picks the window (2026-10-06)

The user: several agents launch the app at once and the second instance
fails with a popup about the Unix socket; "I don't think it should fail
because of 2 windows". The user asked whether instances could share one
socket as MPMC; explained that one path has one listener and a shared
listener spreads connections to a random instance, so requests (runs with
Touch ID prompts) would land in arbitrary windows. Broker model (first
instance owns the socket, others register) offered and not chosen.

Accepted ("ok, go for it"): each instance listens on
`~/.dev-env/run/dev-env-<pid>.sock` and prints `dev-env: agents connect to
<path>`; `ping` reports pid, started_at and the window's project and
session (webview reports it with `set_window_view`). The CLI uses
`--socket`/`DEV_ENV_SOCKET` when set; otherwise pings every socket, removes
stale ones, and ranks: same project and session, then same project, then
others; ties go to the newest instance. Each instance also watches the
active session's `session.sqlite` so every window showing a session
refreshes whoever wrote.

### D9. alert-service picks the decoder by subscription, not by bytes (2026-10-06)

The user rejected D5's first-byte routing in a dev-env annotation ("You
cannot just mix 2 completely different shapes with 2 completely different
encodings ... Based on subscription, you know exactly what to expect").
Choices made by the user:

- Two feeds in data-feed-definitions: alerts (`fkind_77317e301c9325b1a30352cc5d4a3399`,
  protobuf, subject `Other(<service name>)`) and Cloud Monitoring incidents
  (`fkind_ea7474dcf26f59ab291440e4fee725fa`, json, TS types + zod via
  export-ts).
- Incidents on their own topic `monitoring-incidents` (Cloud Monitoring sets
  no attributes, so they cannot carry `feed_kind`). Rejected: `feeds` with a
  `NOT attributes:feed_kind` filter.
- TS decodes the alerts feed with protobuf-es generated from the codec's
  .proto. Rejected: a decode in the application-server wasm, a new wasm in
  data-feed-definitions.
- `alert-service-alerts-feed-sub` on `feeds`, filtered on kind and
  `encoding = "protobuf"`. Legacy `alerts` topic and subscription stay until
  publishers move (later, separate change).
- alert-service config: `subscriptions: [{subscription, source: alerts_topic
  | feed, feed_kind, encoding}]`; an unknown feed fails startup.
- DEC-0BPWJ R10 rewritten in the same uncommitted revision.

## Open

- Backfill of empty files for days marked before D1 (offered a fill mode for
  marked days without Databento calls; not built).
- Deploy order: new job image and infra together (config needs
  `freshness`; old binary would wait on a 30 min schedule).
- Monitoring notification service agent may need
  `gcloud beta services identity create --service=monitoring.googleapis.com`.
- KB `just catalog` fails on pre-existing duplicate DEC-0BRC4.
- Rust alert publishers dropped by alert-service.
- Move alert publishers (TS and Rust) to the alerts feed; then remove the
  `alerts` topic.
- A local smoke start of alert-service on 2026-10-06 acked the backlog of
  `stxr-prop-dev` `alerts-event-gw-sub` (Discord posts went to a fake URL).
