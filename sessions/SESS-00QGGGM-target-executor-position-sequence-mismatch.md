---
create_time: 2026-10-13T09:34:12Z
title: "Target executor position off by one from mixed sequence numbers"
summary: "Target executor fills ordered by gateway_receive_time vs sim-gw orderand (ISS-0C0KR). Decided: fills carry the same venue orderand as the feed Fill, required on every execution report, sim-gw orderand a persisted counter not time, keep trade_v2 SequenceNumber for now (D7), demo deployment nuked. Open: counter crash safety (block reservation proposed), uni-gw VenueOrderand proto"
related_sessions: []
agents:
  - claude-code:7f074ada-7590-48bd-b348-5fcc0df37972
---

# SESS-00QGGGM: Target executor position off by one from mixed sequence numbers

## Bug report (transcribed)

The user received this report as two screenshots and will delete them. The
text below is the full report, kept close to the original wording.

> The target executor has the wrong idea of its own position. It thinks ESZ6
> is −1, which matches the target, so it does nothing. The venue says −2, and
> so does the UI. The executor has been off by +1 since its very first trade,
> at 2026-10-11 21:08:47. It cannot correct itself, because it now throws away
> every position report the venue sends. I only investigated; the code to fix
> is in the server repos (`strats_v2`, `sim-gw`, `trade_v2`), not this one.

### Root cause (as reported)

The executor updates the same position counter from two sources, and each
source orders its messages by a different numbering scheme:

| Source | Kind of update | Sequence number used |
| --- | --- | --- |
| Fill reports from the gateway (`strats_v2/src/target_executor/wire_msg/uni_gw_status_update.rs:203-215, 283`) | adds the filled quantity | the gateway's wall-clock time in nanoseconds, about 1.79×10¹⁸ (`sim-gw/src/state/ready.rs:294`) |
| Position reports from the venue (`strats_v2/src/target_executor/logic/venue/position_update.rs:191-193`) | sets the absolute position | the venue's counter, built as `(seconds since 2026-01-01) << 31 \| bump`, about 5.27×10¹⁶ |

The position counter in `trade_v2/src/position.rs:217-340` treats these
numbers as comparable. A position report is applied only if its number is
strictly higher than the last update's, and a fill is applied if its number is
higher than the last report's. The venue's own code says its counter must not
be compared with numbers from another source (`sim-gw/src/orderand.rs`).

The result:

- Every fill always looks newer than any venue report, so it is always applied.
- Once a fill has been applied, every later venue report looks older and is
  thrown away. This is about 49 years away from changing.

### What happened, from ClickHouse (as reported)

- 21:08:47.893: the target became +1 and the executor bought 1, so the venue
  held +1.
  - The venue's report of +1 (sequence 52,672,033,661,648,897, decoded from
    the raw event) arrived first and was accepted, because the executor had no
    ESZ6 entry yet.
  - The fill report then added +1 on top of it, so the executor believed +2.
    When the order finished, it saw +2 against a target of +1 and sold 1.
  - The reporter inferred the arrival order from the logs: if the fill report
    had come first, the +1 report would have been rejected and logged as
    stale, and no warning appears at that time.
- 21:08:47.894: the sell filled, so the venue held 0.
  - The venue's report of 0 was rejected as stale. This is the first
    `target_executor.market_data.account_position_update.stale` warning, at
    .895.
  - The fill report subtracted 1, so the executor believed +1 and the target
    looked met.
- From then on: every target change produced a trade of 2: sell 2 at 05:46,
  buy 2 at 07:49, sell 2 at 08:38, buy 2 at 12:14, sell 2 at 12:34. Each was
  followed by exactly one rejected venue report. That makes 6 stale warnings,
  which are the only target executor warnings since the deployment started.
  The venue's reports match its fills exactly (+1, 0, −2, 0, −2, 0, −2), so
  the venue is correct and the executor is off by one.

### Fix (as reported, not implemented)

- Recommended: use one numbering scheme for both sources. `sim-gw` would stamp
  each fill report with the venue sequence number it gives the matching fill.
  The executor would then use that number for the fill instead of
  `gateway_receive_time`. Because the venue's position report for a fill
  always gets a later number than the fill, the counter comes out right
  whichever message arrives first.
- Avoid: making venue reports always win, or ignoring fill reports for
  position. A late venue report could overwrite a newer fill, or a finished
  order could re-run the target against an out-of-date position. Either way
  it would overtrade.
- Detection meanwhile: any `...account_position_update.stale` warning on the
  simulated venue means the executor has stopped listening to the venue's
  positions.

## Verification against the code (2026-10-13)

Checked in the local checkouts; the report's root cause holds.

- `strats_v2` `sequence_number_from_timestamp` turns `Trade.gateway_receive_time`
  into `SequenceNumber::Generic { sn: secs * 1e9 + nanos }`. Its doc comment
  already calls it a fallback until a real ordering field lands on `Trade`.
- `strats_v2` `apply_trading_account_positions_update` uses
  `SequenceNumber::Generic { sn: msg.feed_orderand().0 }`.
- `trade_v2` `SequenceNumber::partial_cmp` compares any two `Generic` values
  as plain `u64`, so it cannot tell the two schemes apart. Snapshots apply only
  on strictly greater; deltas apply on greater, or equal after a delta.
- `sim-gw` fill handling (`state/ready.rs`) publishes in this order: the
  uni-gw `Trade` status update (stamped with `now_timestamp`), then the feed
  `Fill` event (`publish_fill`, draws an orderand), then the feed
  `TradingAccountPositionsUpdate` (draws the next, larger orderand). Both feed
  events get their orderand from `next_event_metadata` in `logic/feed.rs`.
- The `Trade` proto (`messaging/msg-schemas/proto/gw/uni-gw/status_updates.proto`)
  has no sequence field today, so the recommended fix needs a schema change.
- The 49 years check out: the gap is about 1.74×10¹⁸ and closes at
  2³¹ − 10⁹ ≈ 1.15×10⁹ per second, about 1.5×10⁹ seconds.

## Proposed fix (agent proposal, not yet a user decision)

1. `messaging`: add a venue sequence field to `uni_gw.Trade`.
2. `sim-gw`: draw the fill's orderand before publishing the `Trade`, put it on
   the `Trade`, and reuse the same value for the feed `Fill` event. The
   position snapshot that follows draws a later orderand.
3. `strats_v2`: build the fill's `SequenceNumber` from that field instead of
   `gateway_receive_time`.
4. A table test in `strats_v2` for both arrival orders (report first, fill
   first) ending on the venue's position.

Open questions for the user:

- Whether the field is a sim-gw specific value or a general per-venue
  ordering field on `Trade` (the existing comment expects Hyperliquid block
  numbers there).
- What the executor should do with a `Trade` that has no sequence field
  (other gateways): reject, or keep the timestamp fallback with a distinct
  `SequenceNumber` variant so it never compares with feed orderands.
- How to repair the running deployment: a restart rebuilds the executor's
  position from the venue, or a fix deploy alone is enough.

The explanation for the user is the dev-env notebook
`target-exec-position-bug` in session `sess-00qgggm`.

## Decisions (2026-10-13, from notebook annotations)

D1. Fill reports are ordered by an orderand, never by time. The user: "this
is for sure fucked up, it cannot do that, we need an orderand" and "we need
the same orderand, never depend on time". `sequence_number_from_timestamp`
and every use of `gateway_receive_time` for ordering in the executor go.

D2. The fill report on the gateway and the `Fill` event on the sim venue feed
carry the same orderand. The user confirmed they are the same thing ("Those
are the same things"). The position report that follows keeps its own, later
orderand. Affects `messaging` (uni-gw `Trade`), `sim-gw`, `strats_v2`.

D3. Every venue execution report must carry a sequence number. There is no
fallback for a report without one ("It's impossible. each venue execution
report MUST have a sequence number"). Replaces the open question above about
gateways without the field: the field is required, a report without it is
invalid.

D4. The sim-gw orderand stops depending on time. It is a counter persisted in
the sim-gw rkyv state snapshot. Affects `sim-gw/src/orderand.rs` (drop the
`seconds << 31 | bump` layout) and the snapshot, which needs a new version
(never edit v1). The snapshot already stores `last_feed_orderand`; how the
counter survives a crash between periodic snapshots is open (see below).

D5. Ideally the executor does not use `trade_v2`'s `SequenceNumber` enum at
all (the user: "Ideally, we don't even use that shitty thing"). If replacing
it is too much work, fix sim-gw first and keep the enum for now. Open: how
large the replacement is; whether the user's earlier position tracker
prototype can take its place.

D6. No repair of the running demo deployment. The user will delete it and
start a new strategy.

D1-D6 supersede the "Proposed fix" open questions above: the gateway without
a field question is settled by D3, the repair question by D6.

## Findings that shape the fix (2026-10-13)

- No knowledge-base record decides the uni-gw message schema. The only design
  document is `sim-gw/docs/research/schema_proposal/client_order_gateway_schema_proposal.md`
  (Draft 3); its `Trade` matches the current proto and has no ordering field.
- DEC-07RD2 (Feed Orderand, proposed): orderands are feed-scoped and never
  compared across feeds; do not name the concept `sequence_number`.
  DEC-07RE5: orderands are venue-scoped, one per simulated venue.
  DEC-08VKD sketches `enum VenueOrderand { Simulation { sequence_number: u64 } }`,
  not comparable across venue kinds.
- ISS-0C0KR (paper deployment sells right after its first fill) is an earlier
  sighting of this bug: its hypothesis 2 is "sequence numbers came from
  different counters". ISS-0B206 (orderands depend on wall clock time,
  ENG-2027) covers sim-gw and event-gw; D4 closes the sim-gw half.
- sim-gw already persists `last_feed_orderand` in snapshot v1 and resumes
  after it. Snapshots are written after init, hourly when deployed, and
  before shutdown (sim-gw ADR-0004); a crash loses up to an hour (sim-gw
  ISSUE-0002). A plain counter restored from the hourly snapshot would reuse
  up to an hour of orderands after a crash, and consumers would drop those
  events as stale. sim-gw also uses the snapshot's `taken_at` wall clock as
  the sequence number of restored positions, which conflicts with D1.
- The user's position tracker prototype is `prototypes/position-tracker`
  (`src/tracker_traits.rs`: `PositionValue`, `CostBasisUpdate::{Set, Add, Remove}`,
  `go_flat`). It is in no crate; the `venue-core` venue simulator crate it was
  planned for does not exist. It has no ordering at all (arrival order).
- The executor uses `SequenceNumber` because `trade_v2::MultiAccountPositionTracker`
  takes it on every update; about 34 mentions in `strats_v2/src/target_executor`.

D7 (2026-10-13). For now the executor keeps `trade_v2`'s `SequenceNumber`:
the fill's `VenueOrderand::Simulation` maps to `SequenceNumber::Generic` in
one place. Refines D5: replacing `SequenceNumber` with a tracker keyed by
`VenueOrderand` is deferred, still the preferred later step.

## Agent proposals awaiting the user (not decisions)

- Proto shape (shown as a diff in the notebook): `VenueOrderand venue_orderand = 18`
  on `uni_gw.Trade`, `= 11` on `TradeCancel`, `= 16` on `TradeCorrect`;
  `message VenueOrderand { oneof value { SimulationVenueOrderand simulation = 1; } }`,
  `message SimulationVenueOrderand { fixed64 value = 1; }`. Required by
  validation in the `strats_v2` wire crate.
- sim-gw counter crash safety: reserve blocks (store "reserved up to R" in a
  new snapshot version, save before issuing past R; a v1 file upgrades by
  resuming after its `last_feed_orderand`). Alternatives: a durable write per
  event; or the hourly snapshot only (rejected by the agent: reuses values).
  The user asked how block reservation works; explained in the notebook with
  a worked example (snapshot 1,000, crash at 5,000, restart at 10,001). No
  decision yet.
- strats_v2: settled by D7 for now.
- Whether to record the uni-gw orderand field as a knowledge-base decision.
