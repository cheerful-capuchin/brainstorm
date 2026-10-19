---
create_time: 2026-10-19T11:02:39Z
title: "notify-gw alert flood: throttling, mute command, burst handling"
summary: "Weekend 2026-10-16..19 Discord flood was a notify-gw delivery failure, not alert volume: pool stuck full, feed-ingress nacked on tickets_full -> ~200 Pub/Sub redeliveries/s, ~12 GB/day of warning logs, ~1 Discord post per 6 min. D1 alerts sub seeked to 2026-10-19T10:11:29Z (~560 dropped). D2 implemented, uncommitted in monitoring + infra: one Discord send at a time, 429 not an attempt, throttle (feed+service+event+first tag, 1 h window, summary post), per-message logs limited to 1/min, feed-ingress waits for a ticket instead of nacking, retryPolicy 10s-600s. D3 mute triggered from a phone via a cloud agent (or admin dashboard), backend = Pub/Sub control topic; open. D4 decided: lossy compression toward Discord, full alert data stored elsewhere (ClickHouse or similar; storage design open). D5: at most one post a minute; under load the cadence backs off 1 min -> 5 min -> 15 min -> 1 h and steps down after quiet windows; a lone waiting alert is posted in full, two or more become one digest (replaces the 6/min budget). sim-gw logged 231 GB on 10-13..15."
related_sessions:
  - SESS-00R0BCD
  - SESS-00R0C3Y
  - SESS-00PYN1M
  - SESS-00QKS30
  - SESS-00QKRBE
agents:
  - claude-code:e92b2840-ec0f-4261-822b-0cba65d0ff96
---

# SESS-00R0FYF: notify-gw alert flood: throttling, mute command, burst handling

## Trigger (2026-10-19)

The user got pinged in Discord about every 5 minutes over the weekend and asked
for (a) throttling of similar events in notify-gw and (b) a message they can
send to make it stop ("shut up"). Mid-session they added (c): prevent the log
bursts that cost money. notify-gw source: `monitoring/rust/crates/notify-gw`.
Production: Cloud Run worker pool `notify-gw`, project `stxr-prop`,
asia-northeast1, revision notify-gw-00004-xtz.

## Findings

### The flood was a delivery failure, not alert volume

- First `feed_ingress.pubsub.tickets_full` at 2026-10-16T15:48:25Z. About 460
  alerts arrived on `notify-gw-alerts-feed-sub` at once (this matches the
  ~1,000 `execute` calls in 5 s on 10-16 15:39:57Z in SESS-00R0BCD and the
  4xx-as-ALERT volume there). The backlog then sat at 400-577 until the seek.
- All 64 tickets were held by route 0 (alerts), even though
  `max_outstanding_messages` was 32 per subscription. Streaming pull flow
  control is best effort.
- feed-ingress nacked every message it had no ticket for. A subscription with
  no retry policy redelivers at once, so this became a hot loop.
  `subscription/sent_message_count` was ~4.4M per 6 h (~200/s) for a backlog
  of ~500. Every refusal logged one WARNING line: ~2,100 lines per 10 s, about
  12 GB/day of Cloud Logging (33 GB over 10-17..19).
- Only ~20 acks/hour: ~10 delivered to Discord (the "every 5 minutes"
  pings, really one post every ~6 min) and ~10 `notify_gw.delivery.gave_up
  attempts=8`. Likely cause, not confirmed because no status was logged:
  every waiting delivery was sent in parallel to one webhook (Discord allows
  ~5 req / 2 s). After a 429 hold they all fired at the same moment again,
  and each 429 used up one of the 8 attempts. SESS-00R0C3Y saw the same
  thing from the other side (backtest-failed incidents never reached
  Discord).
- Incidents subscription: backlog 0-8, not part of the flood.
- The webhook posts no mentions (`@here`/roles); "pinged" means the channel
  notifications.

### Log volume (Cloud Logging byte_count, stxr-prop, 2026-10-12..19)

- sim-gw: 231 GB (163 GB on 10-14 alone), ~3,800 lines/s of
  `sim-gw.on_nats_msg.dispatch.error error:
  ready_state.error.feed_decimal_out_of_range`, one per market data message.
  0 bytes since 10-16. Not touched in this session.
- notify-gw: 33 GB (10-17..19), all `tickets_full`.
- event-gateway: 1.6 GB on 10-13. Everything else is negligible.

### Pub/Sub SDK facts (google-cloud-pubsub 0.33.2, the official crate)

- Only streaming pull is public (`Subscriber::subscribe`, flow control via
  `set_max_outstanding_messages/bytes`). Unary `Pull` exists only as proto
  structs, with no public client. A strict "give me N" pull would mean REST
  `:pull` / `:acknowledge` / `:modifyAckDeadline` with our own lease
  extension.
- The stream buffers a server batch client-side (`pool: VecDeque`). The SDK
  extends the leases of every message it holds.

## Decisions

### D1: drop the stuck backlog (done 10:11:29Z)

User approved `gcloud pubsub subscriptions seek notify-gw-alerts-feed-sub
--time=2026-10-19T10:11:29Z` (~560 unseen alerts acked; irreversible). At
10:12:03Z the user scaled the worker pool to 0 instances
(`manualInstanceCount: 0`, from kdoichev@stxr.io). notify-gw is not delivering
until it is scaled back or redeployed. Pulumi sets it back to 1 on the next
`pulumi up`.

### D2: order of work: delivery fix and throttling first, then the mute

The user said yes to doing the delivery fix and throttling first. All of it
is implemented and uncommitted:

monitoring (`just check notify-gw feed-ingress` and `just e2e` pass):
- Delivery: one Discord request at a time, the oldest queued delivery first
  (`DeliveryStage` Queued/Sending/BackingOff in `logic/delivery_pool.rs`,
  `pump` in `logic/delivery.rs`). While Discord asks to hold, one Resume
  timer wakes the pump. A 429 re-queues the delivery and does not count as an
  attempt. `gave_up` logs the last status (0 = no HTTP answer).
- Timers: `messages::TimerCtx { Retry(CorrelationId), Resume, ThrottleSweep }`
  replaces `DeliveryTimerCtx`. Timer ids: correlation id, 0, u64::MAX.
  Re-arming an id replaces its timer; handlers are idempotent.
- Throttle (`logic/throttle.rs`, config `throttle: { window_ms: 3600000,
  keys_max: 128 }`, both optional):
  - Key = hash(feed kind, service_name, event, first tag).
  - The first alert of a kind in a window is posted. Repeats within the
    window, or while that kind's summary is still owed, are acked and
    counted, not posted.
  - When the window ends, one summary post: same title, tag `throttled`
    (grey), "Repeated N more times between T1 and T2…".
  - The window opens only when the body is written and a delivery is free,
    so a nacked message is not counted as posted.
  - When the table is full, new kinds are posted untracked. Fail open.
  - The delivery pool has 4 extra slots for summaries (`DeliveryOrigin::
    Summary`, nothing to settle).
  - Memory only: after a restart the first alert of each kind posts again,
    and summaries owed at drain are dropped (counted in the
    `drain.started` log line).
  - Cloud Monitoring incident open and closed posts are different kinds.
- Log limits (`logic/log_limit.rs`): `feed.dropped`, `delivery.pool_full`,
  `throttle.full` are written at most once a minute, with `suppressed=N`.
- feed-ingress: a full ticket table no longer nacks. The binding holds the
  message and waits for a settle (`Notify`, enabled before retrying insert).
  It logs one `tickets_full` per stall and `tickets_resumed waited_ms=` when
  it ends. Stop while waiting nacks the held message. Back-pressure now reaches
  Pub/Sub: we stop reading the stream, so the server stops sending.

infra (`just check` passes; not deployed):
- `NOTIFY_GW_RETRY_POLICY = { minimumBackoff: 10s, maximumBackoff: 600s }`
  on `notifyGwAlertsFeedSub` (event-bus.ts) and
  `notifyGwMonitoringIncidentsSubscription` (monitoring.ts).

Not done: commits, PRs, image build, deploy, README of infra.

### D3: the "shut up" command is sent from a phone through a cloud agent

Options presented:
- A: Pub/Sub control topic + `gcloud pubsub topics publish`.
- B: Discord slash command; needs a bot plus a public endpoint that checks
  Discord's signature and forwards to the same topic.

The user's answer: "I should be able to do it from my phone. So, we either
have an admin dashboard or better a cloud agent" (message cut off). So the
backend is A: notify-gw reads a control subscription. A cloud agent (or later
an admin dashboard) publishes to it.

Proposed semantics, not yet confirmed:
- `mute <duration>`, capped at 24 h; optional scope (everything, or one
  event/service); `unmute`.
- While muted, alerts are acked and counted. One post when the mute starts,
  one summary when it ends.
- Lost on restart, and the startup post says so.

Open questions put to the user:
- Is a publish-only service account key in the cloud agent's environment
  acceptable?
- Should the control message get its own definition in data-feed-definitions
  (one shape per subscription)?
- What did the cut-off message say about an admin dashboard?

## Proposal: reliable burst handling (not decided)

The user asked whether we can "pull" instead of being pushed. Their framing:
`claim_ticket` and the bursts exist because messages are pushed and we
cannot process them while Discord throttles us. They see compressing
information (not publishing every event to Discord) as one strategy, but want
a reliable answer to bursts.

Agent's answer:
- We already pull. Streaming pull is client-initiated with server-side flow
  control. The flood came from our nacks (immediate redelivery) and from the
  best-effort flow control letting through 64 instead of 32. After D2 a full
  table stops our reads, the SDK keeps extending the leases it holds, and the
  backlog stays in Pub/Sub, which is the durable buffer.
- A strict unary pull via REST would remove only the small overshoot, at the
  cost of our own lease handling. Not recommended.
- Discord takes ~30 messages/min per channel (and people read far fewer).
  Faster input can only be delayed or merged. Delaying is reliable but
  useless for alerting (the weekend's posts were hours late), so merging is
  required and has to be a hard limit.
  1. Merge repeats: done (D2 throttle).
  2. Global post budget (proposed default 6 posts/min across all kinds).
     Past it, switch to digest mode: count everything and post one digest a
     minute ("N alerts, top 5 events x count"); go back to normal posting
     when the rate drops. Needed because the throttle only merges the same
     kind: a burst of many distinct kinds, or more than `keys_max`
     (untracked fallback), is still one post each.
  3. Stale folding (proposed: older than 10 min by event_time): an alert that
     waited in Pub/Sub (outage, restart) goes into the digest instead of its
     own post.
  4. Fast acks: a merged alert costs one count and is acked at once, so the
     subscription drains at Pub/Sub speed whatever Discord's rate.
- Guarantees with 2+3:
  - Discord sees at most the budget per minute.
  - The first alert of each kind is posted at least once; the rest show up
    as counts.
  - Counts are in memory and lost on a crash. Persisting the throttle table
    through the engine's snapshot persister would close that, at the cost of
    more code.
- The same budget can also sit with the publishers (AlertSink in
  structure-web, per SESS-00R0BCD/SESS-00R0CQR), but notify-gw is the single
  point on the way to Discord, so the hard limit belongs there.

Asked: implement the budget + digest mode (6 posts/min, stale after 10 min,
both config)? No answer yet. The user wants to discuss digests and alert
storage with another agent first.

### D4: lossy compression toward Discord, full data stored elsewhere (decided)

User: "yeah, definitely. That's the only way to handle it - by using a lossy
compression and then having access to the actual data being stored somewhere
in clickhouse or something."

- Discord gets a lossy view: global post budget, digest mode past it,
  alerts that waited too long folded into the digest (the proposal above).
- Every alert is kept in queryable storage, ClickHouse or similar. Which
  store, how it is written (event-gw, a direct consumer of the feeds topic, a
  BigQuery subscription) and how a digest links to the stored alerts are
  open (Q2).
- Agent implements the budget + digest mode in notify-gw with config
  defaults (6 posts/min, digest every minute, stale after 10 min by Pub/Sub
  publish time). The digest's content and format can still change with Q1.

Implemented (uncommitted, monitoring; `just check notify-gw feed-ingress`
passes):
- `logic/budget.rs` `PostBudget`: generic cell rate. One `paid_until`
  timestamp, a burst of `posts_per_minute`, then one per 60 s /
  posts_per_minute. Single alert posts and throttle summaries spend it;
  digests do not.
- `logic/digest.rs` `DigestTable`: fixed `kinds_max` slots keyed by
  `ThrottleKey`, with counts and cut event/service text. Kinds beyond the
  table are counted unnamed. `write_text` gives a header ("N alerts between
  T1 and T2 were not posted one by one."), up to 10 busiest kinds
  ("• event (service) × n", ties to the first arrived), then "• other
  alerts × rest". A line that does not fit is left out whole.
- The digest post: title `notify_gw.digest`, tag `digest` (grey), service
  `notify-gw`, no help_url yet. Linking to the alert store is the place for
  Q2.
- Flush: `TimerCtx::DigestFlush` (timer id u64::MAX-1), armed one interval
  after the first folded alert. It uses the summary delivery slots and
  retries after 5 s when none is free.
- Feed path (`Intake::take`): repeats go to the throttle first. A would-be
  post is folded when stale or over budget, and a folded alert opens no
  throttle window. Otherwise: delivery free check, write, spend, open
  window.
- Staleness uses only the Pub/Sub `publish_time`. A message without one
  (NATS) is never stale. The alert's own time is not used, because a
  closing incident carries its start time.
- Throttle sweep: a summary over budget is folded into the digest with its
  repeat count.
- Draining ignores DigestFlush. `drain.started` logs
  `digest_alerts_dropped`.
- Config `digest: { posts_per_minute: 6, interval_ms: 60000,
  stale_after_ms: 600000, kinds_max: 32 }`, all optional. The README, crate
  docs and the example config are updated.

### D5: at most one post a minute, and the cadence backs off under load

User: "I would say at most 1 a minute. There is rarely something so critical
that it requires the fix within the same minute. And if there are too many
events still, we backoff further and compress them further. e.g. if for the
last 5 minutes we got a bunch of events, then compress them to 5 mins, then
15 mins, then hour. Pinging me 6 times a minute or every minute is not
helpful. If there is a burst, I won't be able to react quick enough and it
will just annoy me more."

Replaces the 6 posts/min budget of D4 (rejected: too many pings during a
burst). Design implemented by the agent:
- One outbox, one post per cadence window. The cadence ladder is
  1 min -> 5 min -> 15 min -> 1 h (config `digest.cadence_ms`).
- An alert that arrives while no post is owed and the window is over is
  posted at once, in full. Otherwise it waits in the outbox.
- When the window ends:
  - Exactly one alert waiting: posted in full (its body was kept).
  - Two or more: one digest, and the cadence steps up one level.
  - A window that posted a single alert, or ended empty, steps the cadence
    down one level.
  - So after a burst it takes 1 h + 15 min + 5 min of quiet to get back to
    1 min.
- Throttle summaries go into the outbox as counts; they are never posted
  on their own.
- Stale alerts (D4) go into the outbox and are never posted alone.

Implemented (uncommitted, monitoring; `just check notify-gw feed-ingress`
passes), replacing the D4 budget code (`logic/budget.rs` deleted):
- `logic/digest.rs`:
  - `DigestPolicy { cadence_ms: [NonZeroU32; 8], cadence_len,
    stale_after_ms, kinds_max }` and `Cadence { level, window_ends_at }`.
  - `DigestData` holds the policy, the cadence, the `DigestTable`, a
    `held` flag plus `held_body` (the full post of a lone waiting alert,
    BODY_CAPACITY reserved), `window_armed` and the digest text.
- Feed path (`Intake::take`):
  - Repeats go to the throttle.
  - A fresh alert is posted at once when the window is over and the outbox
    is empty (the window restarts at the current level). Otherwise it waits
    and is acked; it is kept in full when it is the outbox's first.
  - Waiting alerts open no throttle window.
- `TimerCtx::DigestWindow` (id u64::MAX-1) is armed while the outbox owes a
  post or level > 0. When it fires:
  - Early (a post moved the window's end): re-arm.
  - Empty: step down and start a new window.
  - Otherwise: the lone held alert, or a digest. A digest steps up; a lone
    alert steps down. Retries after 5 s when no delivery is free.
- The digest text says "Busy: the next post comes in 15 min at the
  earliest." when level > 0.
- Throttle summaries are no longer posted. At window end the repeat count
  goes into the outbox (`digest::count`); `ThrottleSummaryNotice` was
  removed.
- Config: `digest: { cadence_ms: [60000, 300000, 900000, 3600000],
  stale_after_ms: 600000, kinds_max: 32 }`. Validation: 1-8 steps, never
  shorter up the ladder. The e2e config uses `cadence_ms: [1]`.
- Tests:
  - Unit tests cover the table.
  - The delivery tests run with a 1 ms cadence and space their alerts.
  - The cadence tests use the production ladder: calm posting, a lone alert
    in full, the climb 1->5->15->60->60 min and back down 60->15->5->idle,
    the digest text, and stale alerts.
- Open: should a burst of *different* alerts also climb when only one
  arrives per window (it does not)? Is one alert per window "calm"?

## Open for the next discussion (digests and alert storage)

- Q1: Digest content and cadence. Top-N events with counts? Per service?
  Links to where the full list lives? One digest a minute, or one per budget
  window?
- Q2: Alert storage. With merging, most alerts are never posted
  individually. Where can someone see every alert behind a count?
  Candidates:
  - Cloud Logging (notify-gw logs each one; costs per GB, the thing we just
    cut).
  - A BigQuery subscription on the feeds topic (alerts feed filter).
  - The ClickHouse event log via event-gw (SESS-00QP5W3 D7).
  - Pub/Sub retention (7 days, not queryable).
- Q3: Should counts survive restarts (engine snapshot of the throttle table)
  or is "first post at least once, counts best effort" enough?
- Q4: Should publishers dedupe too (AlertSink batching already exists), or
  only notify-gw?
- Q5: How does the mute (D3) interact with the budget and digests? Muted
  alerts would go into one end-of-mute digest.
- Q6: sim-gw-style per-message error logs: a per-call-site rate limit in
  logger2 for every service, instead of fixing each service?
