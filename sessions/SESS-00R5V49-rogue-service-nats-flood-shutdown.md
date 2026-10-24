---
create_time: 2026-10-21T11:44:09Z
title: "Rogue service flooding NATS: detection, complaint and shutdown"
summary: "D1: sender identity by per-sender subject, enforced by NATS publish permissions (a convention alone is spoofable). Question: can a service that floods others over NATS (target-exec <-> sim-gw loop 2026-10-12..14) be reported and shut down, and how would sim-gw know who floods it? Findings: requests carry no sender field, ipc drops NATS headers, account_id is the only per-message identity; no rate limits, no NATS auth, exporter has no per-connection series, Cloud Run restarts an exited process, only kill switch is all-or-nothing kill_traffic; app-server strategies:shutdown has no caller. Proposal L0-L3 (sender guard, sim-gw per-account throttle + account kill switch rejecting with a reason target-exec treats as fatal, complaint event, per-connection NATS rates) and open Q1-Q6. Follow-up: corrupt messages carry no account, so identity must come from outside the payload; agent proposes a per-sender subject (stxr.gw.sim.request.<source>) over a header because NATS permissions can enforce it; open Q8. Explained NATS users/permissions, JWT accounts, revocation, auth callout."
related_sessions:
  - SESS-00QKS30
  - SESS-00QRJ0S
  - SESS-00QKRBE
  - SESS-00R0FYF
  - SESS-00QGGGM
  - SESS-00QRK20
agents:
  - claude-code:64b0046b-7bd7-4300-b8bc-e35a1ab09e70
---

# SESS-00R5V49: Rogue service flooding NATS: detection, complaint and shutdown

## Trigger (2026-10-21)

The user: several times a buggy service flooded other services with NATS
messages; the worst was target-exec and sim-gw sending junk to each other in an
endless loop (2026-10-12..14, SESS-00QKS30 findings: target-exec rejected every
positions update for tacc_02V26M3ZG0400 with `IncompatibleSequenceNumber` and
kept ordering ~2,000/s; sim-gw filled until the feed Decimal overflowed, then
~2,000 errors/s for 37 h until target-exec was scaled to 0 by hand). Asked:
can a process report that another went rogue so a supervisor shuts it down?
How would sim-gw know which service floods it, and how would it complain?

## Findings (code and infra survey, 2026-10-21)

Sender identity at sim-gw:
- sim-gw subscribes to `stxr.gw.sim.request` and the trading account feed on
  one plain subscriber connection (no queue group). Every sender publishes to
  the same subject.
- `UniGwRequest` carries `correlation_id`, `idempotency_key`, `trace_id`,
  `request_time`, command; `CreateOrderRequest` adds `client_order_id`,
  `instrument_id`, `account_id`. No `common.Source`, strategy or deployment
  field. target-exec leaves `idempotency_key` empty and `request_time` unset.
- ipc `RawNatsMsg` exposes subject, payload, reply; headers are reachable only
  through `.0.headers` and nobody reads them. Publishers send no headers and no
  reply subject, so sim-gw answers on the shared `stxr.gw.sim.response`.
- So per message sim-gw sees only `account_id` (+ trace id). An account is
  exclusive to one active deployment (SESS-00PE96K), so the account maps to
  one strategy deployment.
- Connection names (SESS-00QRJ0S D1-D3) are committed (telemetry 7946d09,
  ipc a567e3d, sim-gw eb65cb5, strats_v2 8c6038e, ...); that record still says
  uncommitted. D4 (several connections, `connection_id`) is not implemented.

Limits and stop paths:
- No order rate limit or budget in sim-gw or target-exec; ingress/egress
  channels unbounded. sim-gw has `FailureLogThrottle` (log lines only, 300 s).
  target-exec caps retries at 5 per target (`retry.rs`) and then
  `fail_strategy` publishes `TargetExecStatus::Fatal`; the strategy's
  `ShutdownHandler` stops the strategy on Fatal. That cap did not stop the
  2026-10-12 loop (why: not investigated).
- `ComponentReport` / `supervise` (SESS-00QRJ0S idea) not implemented.
- NATS: one VM, 2.14.8, config is only `port`, `http_port`,
  `no_fast_producer_stall: true`. No accounts, users, permissions or limits;
  firewall admits all of 10.0.0.0/16. Exporter runs `-varz -connz -healthz`
  without `-connz_detailed`, so no per-connection series; the comment in
  `infra/nats-monitoring.ts` that clients set no names is stale. No alert on
  message rate.
- NATS 2.10+ has `$SYS.REQ.SERVER.<id>.KICK` (by client id), but clients
  reconnect at once and there is no auth to keep them out, so a kick stops
  nothing.
- Cloud Run: a process that exits is restarted (and sim-gw restores its
  snapshot), so "exit" is not "stop". The only stop lever for system pools is
  Pulumi `kill_traffic` (all pools to 0, needs `pulumi up`). Strategy pools:
  internal `POST /api/v0/strategies:shutdown` (discovery key + internal API
  key, which sim-gw and target-exec already have) deletes the pool; no caller.
  `convex@` and `activity-worker@` hold project-wide `run.developer`; the
  gateways' `cloud-run@` does not.

## Proposal (agent, not decided)

Observation: in a two-party loop each side sees the other as the flooder.
sim-gw saw target-exec; target-exec saw a positions feed it rejected. The
fault was target-exec ordering while its own view of the account was broken.
So the shutdown unit should be the account / strategy deployment, not the
process: target-exec and sim-gw serve every strategy and stopping them stops
everyone.

- L0 sender guard: target-exec stops ordering for an account while its
  positions feed for that account is rejected, and fails the strategy after a
  bound. Fixes the cause class (acting on state it knows is inconsistent).
- L1 sim-gw behaves like a venue: per-account order rate budget (token bucket,
  as CME messaging throttles); over budget the order is rejected with a typed
  reason (`RateLimited`); sustained over budget trips an account kill switch
  (all new orders rejected with `AccountDisabled`, persisted in the snapshot,
  released only by an operator command). Also the overflow check from
  SESS-00QKS30 Open (validate fits-on-the-wire before accepting).
- L2 complaint: sim-gw emits an alert event naming the account (and the
  deployment if it can resolve it) when the switch trips; notify-gw posts it.
  target-exec treats `AccountDisabled` as fatal for that strategy ->
  existing `fail_strategy` -> `TargetExecStatus::Fatal` -> strategy's
  `ShutdownHandler`. The stop needs no new supervisor; the rejects themselves
  are small and stop once the strategy is gone. Alternative: sim-gw (or the
  future monitoring-gw) calls `strategies:shutdown` directly.
- L3 process-level watchdog for floods that carry no account (junk, other
  subjects): add `-connz_detailed` to the exporter, alert on msgs/s per
  connection name (names are Source strings). Action stays human, or a
  per-pool scale-to-0 lever; a process supervisor (`ComponentReport::Stop`)
  only helps for self-detected faults, and exit alone gets restarted.
- Later: NATS users per service with publish permissions, which would make
  kick + revoke a real stop and stop any VPC workload from writing
  `stxr.gw.sim.request`.

## Open questions

- Q1: Shutdown unit: account / strategy deployment (agent recommends) or the
  whole process?
- Q2: Automatic stop or human in the loop? Agent: automatic for a strategy
  (L1/L2), human for system pools (L3).
- Q3: Does sim-gw only reject + complain (target-exec turns it into Fatal), or
  also call the app-server `strategies:shutdown`?
- Q4: Budget numbers: normal order rate per account; what window and burst?
- Q5: Kill switch release: operator command over NATS, sim-gw config, or the
  app-server?
- Q6: NATS auth per service now or later?

## Follow-up: a sender that publishes invalid or corrupt messages (2026-10-21)

User: what if the service just sends a bunch of invalid/corrupt messages?

Today: sim-gw `on_nats_msg` -> `dispatch_raw_msg` fails -> counted by
`FailureLogThrottle`, one warning per 300 s, no reply (no correlation id to
answer). So junk does not feed a loop back and the log flood is capped; what
is lost is who sent it: `account_id` is inside the payload that failed to
decode. The warning carries count + error, not the subject or a sender.

Agent's reading (not decided):
- Identity must come from outside the payload. Two ways:
  - Header stamped by the ipc publisher (`Source` string) and exposed on
    `RawNatsMsg`. Survives a payload bug, but any client can write any header.
  - Per-sender subject: `stxr.gw.sim.request.<source>`, sim-gw subscribes
    `stxr.gw.sim.request.>` and reads the sender from `get_topic_str()`
    (already exposed, no ipc change). Agent prefers this: once NATS has users
    (Q6), a permission `publish: stxr.gw.sim.request.<own source>` makes the
    identity unforgeable, and the same permission is the stop lever (revoke).
    Same pattern for every request subject that has many senders.
- sim-gw budget for decode failures per sender (subject token): over budget
  -> drop without work, count, one digest line (fits SESS-00QKRBE P9), and
  one complaint event naming the sender source + count + first error.
  Unattributable junk (no sender token) is counted per subject only; the
  NATS per-connection rates (L3) attribute it.
- A junk sender ignores rejects, so in-band answers cannot stop it; the stop
  is out of band, keyed by the source: strategy deployment source ->
  `strategies:shutdown`; system pool -> human / per-pool scale-to-0, or
  revoke its NATS user.
- Not every decode-failure storm is a rogue process: a schema change deployed
  on one side only looks the same. Complaint should carry the sender's build
  id (or the decode error kind) so the reaction can be a rollback, not a kill.
- Invariant for sim-gw: decode and validate fully before mutating state (the
  2026-10-13 overflow mutated state first; SESS-00QKS30 Open).

- Q7: Sender identity via per-sender subject (agent) or header?
- Q8: Should a decode-failure storm stop the sender automatically, given it
  may be a version mismatch rather than a rogue loop?

## D1: Sender identity is the subject, enforced by NATS permissions (2026-10-21)

User picked the per-sender subject (answers Q7). Reason given: the header
option, and the subject option without auth, both assume the rogue process
follows the convention and does not spoof another sender. So the subject is
only an identity once NATS enforces who may publish on it; NATS users with
publish permissions are part of the design, not an afterthought (moves Q6
forward).

User asked what "a user per service" means in NATS. Agent's explanation:
- Today the server accepts anyone in 10.0.0.0/16 with no credentials.
- Static config: `authorization { users: [...] }` with an nkey (ed25519
  public key; client signs the server nonce) or password per user, and per
  user `permissions { publish/subscribe allow/deny }`. Adding a user or
  changing permissions = edit config + reload. Fits fixed system pools, not
  strategy pools created at runtime.
- Decentralized JWT (operator -> account -> user, `nsc`, resolver): a holder
  of the account signing key mints a user JWT with its permissions and
  expiry; nothing on the server changes per user. Revoking a user in the
  account JWT disconnects it and refuses reconnects. Templated permissions
  (e.g. `{{name()}}`) let one rule say "publish only on your own subject".
  Fits per-deployment strategy credentials minted by the app-server at
  start and revoked at stop.
- Auth callout (2.10+): the server asks our own service to authenticate a
  connection and it returns the user JWT; could check a GCP identity token
  instead of distributing secrets, but the gateways share the `cloud-run@`
  service account, so that needs one service account per service.
- NATS still has no message rate limit per user or account; permissions
  answer "who may publish where", the rate budget stays in sim-gw.
