---
create_time: 2026-10-14T15:18:56Z
title: "Service alerts through log lines: crash loops and runaway orders went unnoticed"
summary: "D7 revised: quick fix = per-event policies + JSON log lines with jsonPayload.event, rest postponed to SESS-00QKRBE; D8 revisions read from image labels (no SOURCE_REVISIONS, Pulumi provider token); D9 strategies in health alerts. No alerts reached anyone for event-gw crash loop + target-exec/sim-gw runaway order loop (2026-10-13/14). D1 crash alerts all services, D2 CPU/memory alerts, D3-D5 Rust alerts via logger2 program events (runtime.panic, log_alert!), filter for text+JSON lines, alerts topic + alert-service removed; D6 no deploy, rich commits, PRs logger2#14 runtime#5 event-gw#19 gw-mon#5 strats_v2#15 sim-gw#18 structure-web#183 infra#35; dev-env notebooks"
related_sessions:
  - SESS-00QKRBE
  - SESS-00PYN1M
  - SESS-00PYCE2
  - SESS-00QGGGM
agents:
  - claude-code:4eebf8da-9218-431b-ace2-d14784b98909
---

# SESS-00QKS30: Service alerts through log lines: crash loops and runaway orders went unnoticed

## Trigger (2026-10-14)

The user saw in the Cloud Run console that target-exec ran at 100% CPU and
event-gw crash-looped and could not start (log: `main.accounting.seed.fail`,
ClickHouse `MEMORY_LIMIT_EXCEEDED` on `demo_fees`), and asked why no alert
reached them. Then asked how sim-gw's
`sim-gw.on_nats_msg.dispatch.error error: ready_state.error.feed_decimal_out_of_range`
happened.

## Findings

- Only 8 alert policies existed; none covered the Pulumi-deployed services.
  `strategy-crashed` matches strategy pools only (`d-..-r-..`,
  `u-..-s-..-r-..`). No metric-threshold policy existed.
- event-gw's panic hook published to the `alerts` topic; the only reader,
  the TS alert-service, decodes protobuf `ipc.Message` only and acked the
  Rust JSON away (`subscription.decode_err` at 10:18 UTC right after the
  10:17 panic). target-exec sent every Error+ log there as protobuf
  `EventLog`, also dropped. The application-server alert sink had been
  switched off on 2026-10-13 (structure-web 1d729f21b).
- Cloud Run marks a revision Ready once its first instance starts; later
  crash loops keep it Ready (event-gateway-00016-qb6 Ready from 2026-10-12
  19:25 through the whole loop). Answer to "shouldn't the worker pool go red".
- sim-gw error: target-exec revision target-exec-00022-nth (strategy
  strt_02V26PEW80400) rejected every positions update for account
  tacc_02V26M3ZG0400 (102534548809584640) with
  `PositionUpdateFeedError(IncompatibleSequenceNumber ..)` from 2026-10-12
  19:39 UTC (the mixed sequence numbers of SESS-00QGGGM; the deployed image
  predates the orderand fix), kept ordering ~2,000/s, sim-gw filled every
  order until ESZ6 position ~9.2e20 and USD balance ~1.4e15 exceeded the feed
  Decimal's i64 mantissa (`logic/feed.rs` `decimal_from_numeric`) at 23:08;
  then ~2,000 errors/s for 37 h until target-exec was scaled to 0 at
  2026-10-14 12:15 UTC. State already mutated before the failing step; the
  bad values are in sim-gw's hourly snapshots, so a restart restores them.
  sim-gw and target-exec at 100% CPU from ~00:00-03:00 UTC 10-13 (2-30%
  before). event-gw ClickHouse inserts started failing 19:49 on 10-12
  (likely load from the loop, not proven).

## Decisions

- D1 (user): crash alerts for every service. Done as log-match policies on
  Cloud Run's system log (`Container called exit(`, `probe failed`,
  `Memory limit of`), one per resource type, every pool/service except
  strategy pools, name as extracted label (rate limit 1 h per pool).
- D2 (user): CPU and memory alerts for all services. Median CPU > 90% for
  15 min; p99 memory > 85% for 5 min; per pool/service.
- D3 (user): fix the Rust alert path "through the logger" (logger2 program
  events table, DEC-0CHAM) instead of Pub/Sub inside each process and
  "weird tokio runtimes in a panic hook".
- D4 (user approved the plan items): runtime panic hook logs one
  `log_emergency!` event (`runtime.panic`) and drains logger2 before the
  abort; event-gw and gw-mon `send_alert` -> `log_alert!`; target-exec stops
  publishing Error+ logs; each binary commits program-events.json; infra
  makes policies per alerted event; then remove the `alerts` topic and the
  alert-service.
- D5 (user asked what it meant, then approved): infra filter matches text
  lines (`textPayload`) and JSON lines (`severity` + `jsonPayload.message`),
  because target-exec and sim-gw log with `GCPLogSink`.
- D6 (user): no deployment; commit with messages that are a snapshot of the
  context and decisions for a reader months later. Later the same day: open
  pull requests, and write dev-env notebooks.
- Agent decisions the user has not reviewed yet: TS application-server
  alerts go to the alerts feed (DEC-0BPWJ R10) rather than log policies;
  activity-worker alert sink removed (it had no publish grant); gw-mon not
  deployed, so no infra policies for it; a panic posts twice (event +
  crash) on purpose; default rate limit 1 h for service events;
  `SOURCE_REVISIONS` in infra pins each image's source commit.

- D7 (user, revised the same day): quick fix vs postponed. My first D7
  proposal (one global `severity>=ALERT` rule, or a Log Router sink pushing
  log entries to notify-gw, with a description table in notify-gw) was
  dropped: internal traffic to notify-gw is FlatBuffers over the monitoring
  NATS (SESS-00QKRBE P5/P8), only Google-originated input is JSON, and the
  event table belongs to notify-gw's future rules. GCP takes no custom
  protobuf payloads (`protoPayload` is AuditLog/RequestLog only).
  - Now: land the PRs (per-event Cloud Monitoring policies with the doc
    comment as incident text); all services log JSON lines (`GCPLogSink`)
    and logger2 writes the event name as `jsonPayload.event`, so logs are
    queried with `severity>=..` and `jsonPayload.event="..."`.
  - Postponed to SESS-00QKRBE: monitoring crate + NATS FlatBuffers,
    notify-gw rules on alert/emergency with an event description table
    (load once, later per active build), event name on the wire, typed
    keys, panic backtraces, metrics, and retiring the per-event policies.
- D8 (user): no hand-kept source revisions in infra (`SOURCE_REVISIONS`
  rejected). infra reads `org.opencontainers.image.revision` and
  `io.stxr.source-repo` from the image it deploys (labels `just bake`
  writes). Shelling out to `gcloud auth print-access-token` rejected; the
  user pointed to `@structure/gcp`. `ArtifactRegistry.getImageLabels` was
  added there (gcp#4), but infra cannot install `@structure/gcp` standalone
  (pnpm `blockExoticSubdeps`, and runtime/ts depends on
  `pure-rand@workspace:*`), so infra takes the token from the Pulumi GCP
  provider (`gcp.organizations.getClientConfig().accessToken`) and reads the
  registry itself. An image whose commit has no program-events.json gets no
  per-event policies (warning), so infra#35 can deploy before new images.
- D9 (user): strategy deployment pools are not excluded from the crash,
  CPU and memory policies; `strategy-crashed` removed (narrower duplicate).
  Evidence: the strategy pool of strt_02V26PEW80400 idled at 2-3% CPU and
  sat at 96-100% from 10-13 00:00 to 10-14 12:00 UTC.

## Pull requests (2026-10-14)

- logger2#14 `drain_global_logger`
- runtime#5 `log_panic`, `alert` feature removed
- event-gw#19, gw-mon#5, strats_v2#15 (target-exec), sim-gw#18
- structure-web#183 (alerts feed, alert-service deleted)
- monitoring#1 (notify-gw JSON lines), gcp#4 (`ArtifactRegistry.getImageLabels`,
  not used by infra yet)
- infra#35 (health alerts, program-events policies, alerts topic removal,
  rebased revisions); deploy order in its description: services first,
  the removal commit never before the new images.

## Open

- Reset sim-gw and target-exec state for tacc_02V26M3ZG0400 before
  target-exec runs again; sim-gw should validate fits-on-the-wire before
  accepting an order; rate-limit the `feed_decimal_out_of_range` warning.
- Knowledge-base not updated: DEC-0CHAM (JSON-line filter, worker pools),
  platform-topology (alert-service gone). Needs the user's go-ahead.
- Workspace-root pnpm-lock / `@structure/alert-service` override for
  structure-web#183.
- event-gw FIXME: a failed event-log flush loses entries without an alert.
