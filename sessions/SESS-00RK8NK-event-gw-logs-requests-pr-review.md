---
create_time: 2026-10-26T13:54:59Z
title: "Review of event-gw PR #22: logs, account events and positions over NATS"
summary: "Review prep for event-gw PR #22 (logs-requests, head a8848b28): notebooks 01-04 in sess-00rk8nk (overview, R1-R28, message lifecycle, feed-ingress comparison). Top: unpublished db submodule commit, redelivery rewrites position history, single instance not enforced, ring stalls on a lost insert answer, protos say tail cursor is per-list. Buffering thread: ipc sets no Pub/Sub flow control; 256-byte charge and 10 MiB/1 MiB sizes are guesses, derive from flow control + parts/s; async_insert server batching REJECTED (HTTP per message too costly at strategy traffic). User writes the review; only gh: \"...\" annotations get posted"
related_sessions:
  - SESS-00P9RZK
  - SESS-00QKRBE
agents:
  - claude-code:e051a666-915d-4600-9887-c1a8aa9ce656
---

# SESS-00RK8NK: Review of event-gw PR #22: logs, account events and positions over NATS

## Context (2026-10-26)

User asked for a summary of event-gw PR #22 (`logs-requests`, author
malicious-marmoset, 21 commits 2026-10-20..26, head `a8848b28`) with the
parts most important to review, as a dev-env notebook. This PR implements
the SESS-00P9RZK design (event-gw serves client ClickHouse queries over NATS,
ingestion orderands + watermark W, long polls).

Facts gathered:

- 135 files, +48 131/-19 144; ~40 000 lines are two insta snapshots.
- GitHub reports the PR as CONFLICTING with main (main has #20 stocks and
  #21 markets_max since the merge base `32e0d06`).
- `crates/db` (timeseries-db) is bumped to `41511498`, which does not exist on
  GitHub: the schema changes (ingestion generations table, event_logs
  orderand index, target_positions account bloom index) cannot be reviewed.
- The ingestion sequencer is a library inside event-gw, not the separate
  service with a GCS lease that SESS-00P9RZK described.
- PR worktree for reading: `/tmp/event-gw-pr22`.

## Review workflow (user's terms)

- The user writes the review comments themself as dev-env annotations.
- Only annotations the user marks `gh: "<text>"` may be posted to GitHub;
  everything else stays local. Post nothing without that marker.

## Notebooks (2026-10-26)

dev-env session `sess-00rk8nk`:

- `01-what-the-pr-changes`: the four parts (ingestion acks after storage,
  sequencer + W, 11 query routes, seeder), diagrams, reading order.
- `02-review-points`: R1-R27 ranked, each with a location at head `a8848b2`;
  a `pr-state` cell lists posted review comments (needs `github_token` in the
  app's secret store; the app reported it missing).

Top points: R1 db submodule commit `41511498` unpublished (startup panics
without `ingestion_generations`); R2 redelivered accounting event re-appends
the key's latest state at the old event's time, which replaces correct
history in `ReplacingMergeTree(frontier_orderand)`; R3 one instance assumed
(DEC-0CZQP) but deploy overlap not ruled out, generation claim not atomic,
no queue group; R4 slot rings stall behind the oldest entry and nothing
expires a missing insert answer; R5 merged protos (msg-schemas `4f7d030`)
say "tail cursor the same on every page" and "each event comes once",
contradicting the code and DEC-0CZQP; R6 logs have no dedupe identity and
the page key can tie.

DEC-0CZQP (accepted 2026-10-23, kb main) already covers: records repeat,
page token holds only a key, per-page W, one instance, combined
account_events route, oversized target-position events.

## Rewrite and corrections (2026-10-26, later)

User feedback: the first notebooks read like fragments; rewrite in plain
prose with context, and embed the important code snippets (with file path
and a sentence of context) so the user does not open the code. Both
notebooks rewritten that way.

Correction to R5: the merged protos at msg-schemas `4f7d030` already say a
record "can come more than once" and name `event_id` as the account event
identity; the reviewers had read an older commit. The one stale sentence is
"tail cursor ... the same on every page" (logs.proto:19,
account_events.proto:19 and :104, positions.proto:26 and :92), while the
code puts the per-page W in each cursor. R5 narrowed to that.

## Notebooks 03 and 04 (2026-10-26, later)

- `03-message-lifecycle`: one Pub/Sub event log message from arrival to
  ack, with the code of each step (begin → append_row → hold → flush →
  writer → on_insert_response → resolve → PubSubMsgAckRequest) and a table
  of where the state lives after each step.
- `04-what-feed-ingress-does-differently`: user asked what event-gw can
  learn from monitoring's feed-ingress crate. Findings: ipc never sets
  Pub/Sub flow control (gcloud-pubsub default 50 outstanding per sub) and
  event-gw refuses after the pull, so a refused message holds a flow slot
  180 s; feed-ingress sizes a ticket table to the flow limit and stops
  reading when full. feed-ingress's TicketTable is a free-list + per-slot
  generation (never stalls behind one entry, unlike event-gw's SlotRing,
  R4). It has Settlement::Nack (used on drain, never for lack of room),
  NackImmediately + 10 s flush on shutdown, reopen backoff 250 ms→30 s with
  10 attempts per outage, a tickets-undersized startup warning, and
  proptests over a fake SettleHandle. Not transferable as a crate: it uses
  google-cloud-pubsub 0.33.2 (official client; 1.x needs tokio 1.52), ipc
  uses gcloud-pubsub 1.7.1, and event-gw's per-batch bookkeeping has no
  counterpart there.

## Buffering and back-pressure discussion (2026-10-26, later)

Prompted by notebook 03 (message lifecycle) and 04 (feed-ingress
comparison). Three questions from the user, and where they landed.

**Q1. Do we still need the 256-byte per-message charge
(`ROW_OVERHEAD_ESTIMATE_BYTES`) if we adopt feed-ingress's pull-side
back-pressure?** Mostly no. The constant does two jobs: it bounds the
message count (10 MiB / 256 = 40 960 ring slots, ~43 MB of preallocated id
lists) and it guesses row bytes so a buffer cannot fill mid-message. With
Pub/Sub flow control configured (`max_outstanding_messages` and
`max_outstanding_bytes` per subscription; ipc today passes `None`, so the
gcloud-pubsub default of 50 messages / 1 GB applies), the count is
flow control × subscriptions and the bytes are bounded upstream. `append_row`
already knows the exact bytes per row, so any remaining charge can be exact.
NATS still needs a fixed count bound with drop-when-full. `InFlightMessages`
stays for batch counting and the orderand run; it stops being the admission
gate. Reality check: with 50 × 3 subscriptions the budget never bites on
Pub/Sub today; it only bites on NATS floods.

**Q2. Can the 10 MiB buffer ("demo bound") and 1 MiB flush threshold be
derived from ClickHouse's capability instead of guessed?** ClickHouse's
constraint is inserts per second per table (one part per INSERT;
`parts_to_delay_insert` 1000, `parts_to_throw_insert` 3000; guidance about
1 insert/s/table). Proposed derivation: capacity per table = M × S × R
(admitted messages × max payload × measured row expansion), so an admitted
message never fails to append; flush on time at a target T inserts/s/table,
not on bytes, which removes mid-message flushes and the `current_batches`
two-batch case; pool = T × L with L measured (the PR's
`WRITER_LATENCY_BUDGET_MS = 1000` is a constant). Preallocate the worst case
at init, adapt cadence within it. Recorded as R28 in notebook 02 and as the
last two sections of notebook 04.

**Q3 / user decision. Server-side batching with `async_insert=1,
wait_for_async_insert=1` is REJECTED.** I proposed it as the simplest way to
make ClickHouse the limiter. The user's objection: strategy traffic is very
high, and one HTTP request per message (or small group) is far too expensive;
they would rather not use HTTP at all. So batching stays on the event-gw
side, sized as in Q2. A non-HTTP transport (the ClickHouse native TCP
protocol) is an open idea, not decided; the vendored `clickhouse-rs` client
is HTTP-only.

What carries into the review: R4 (ring stalls behind the oldest slot; a
free-list table like feed-ingress's `TicketTable` fixes it), R7 (no retry
backoff), R8 (`async_insert=0` not pinned on inserts; still relevant since
we rely on synchronous inserts), R28 (sizing constants), plus the ipc flow
control gap (not set at all) as the first thing to fix regardless of this PR.

User is continuing this thread with another agent; this record is the
hand-off.
