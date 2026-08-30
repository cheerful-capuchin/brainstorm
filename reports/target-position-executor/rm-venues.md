# Removing Drift and Hyperliquid from the Target Position Executor

Date: 2026-08-30

## Purpose and scope

This report estimates the engineering cost and rollout risk of retiring Drift
and Hyperliquid execution from `strats_v2` so the target position executor can
focus on CME first.

The intended audience is the engineers planning the CME execution rollout. The
analysis distinguishes:

1. removing the two venue trade-spec implementations;
2. retiring the venues end to end inside the target executor; and
3. deleting Drift/Hyperliquid support from shared crates across the workspace.

Only the first two are in scope. Removing the global Drift or Hyperliquid
domain, market-info, messaging, or `trade_v2` support would affect other
components and is not justified by “CME first.”

This is a static repository analysis performed with three independent GPT-5.6
Luna reviews covering Drift, Hyperliquid, and the shared/CME path. No removal
probe was applied. File sizes and line references describe the inspected
workspace on the date above.

### Assumptions

- Drift is operationally dead: there are no orders, swaps, retries, or accounts
  that must remain executable after the cutover.
- Hyperliquid may be revisited later, but preserving its global domain and wire
  contracts is preferable to deleting and recreating them.
- CME support will use the existing target-position manager and generic order
  reconciliation where their semantics fit.
- CME execution work itself is estimated separately from venue removal.

## Executive summary

Removing only
`strats_v2/src/target_executor/venue_trade_specs/drift.rs` and
`hyperliquid.rs` is cheap but incomplete. The files total 2,241 lines, including
31 venue-specific tests, yet the shared dispatcher directly names both
implementations. Deleting the files without replacing the dispatcher does not
compile.

The recommended CME-first change is a **conservative retirement**:

- make CME the supported trade-spec arm;
- route Drift and Hyperliquid targets to an explicit unsupported-venue error;
- delete the two calculation implementations and their tests;
- remove Drift/Hyperliquid target-executor routing only after traffic and
  outstanding work are drained;
- preserve generic reconciliation, simulator code, and shared workspace
  contracts unless they are proven unused.

Estimated removal cost, excluding CME implementation:

| Scope | Estimate | Risk | Result |
|---|---:|---|---|
| Delete the two trade-spec leaves and retire their dispatch arms | 0.5–1.5 engineer-days | Medium | Targets for both venues fail explicitly; inbound/account plumbing remains. |
| Conservative target-executor retirement | 2–4 engineer-days | Medium | Venue calculations, target routing, Drift inbound handling, HL target subscription/context, examples, and focused tests are removed; reusable seams remain. |
| Deep executor purge, including Drift-shaped swaps/accounts/fixtures | 5–10 engineer-days | High | Maximum local cleanup, but it mixes retirement with a structural rewrite and risks deleting seams CME or the simulator needs. |
| Global workspace removal of Drift/HL contracts | Not recommended; multi-week | High | Affects `trade_v2`, messaging, market info, gateways, and other products outside this decision. |

The important dependency direction is:

`CME market model -> CME order/wire boundary -> CmeTradeSpecs -> retire old venue dispatch -> remove old inbound plumbing`

The removal does not unblock CME by itself. CME is currently explicitly
unsupported by the resolver, and the workspace does not yet have an end-to-end
CME order request/status path.

## What is being removed

### Trade-spec leaves

| File | Size | Runtime responsibility | Tests |
|---|---:|---|---:|
| `strats_v2/src/target_executor/venue_trade_specs/drift.rs` | 1,317 lines | Drift spot swaps, derivative limit orders, matching, sizing, price/quantity quantization | 18 |
| `strats_v2/src/target_executor/venue_trade_specs/hyperliquid.rs` | 924 lines | HL spot/perp limit orders, live tick calculation, min-notional and reduce-only rules | 13 |

Only about 699 of the 2,241 lines are runtime implementation; most of the rest
is useful behavior proof. Deleting the tests is mechanically easy, but CME must
replace the shared behavioral coverage rather than merely lowering coverage.

### Shared dispatch that must change

`strats_v2/src/target_executor/venue_trade_specs.rs` declares and imports both
modules at lines 1–2 and 47–48. Its resolver directly accepts a Drift closure
and an HL closure at lines 580–614. More importantly, the exported
`with_venue_specs!` macro constructs the two concrete types at lines 616–653.

The macro is used for:

- target validation at
  `target_executor/target_position_manager.rs:221,266,323,357`;
- spot/derivative matching at lines 404 and 437;
- action calculation at lines 481 and 503; and
- order reconciliation at
  `target_executor/engine_state/ready_state.rs:643,726`.

CME, CBOT, NYMEX, and COMEX currently enter the unsupported arm at
`venue_trade_specs.rs:599-612` and `637-651`. A CME implementation or an
intentional temporary unsupported executor must exist before both current
implementations disappear.

`VenueTradeSpecsResolver` itself appears unused despite being public and
imported in two files. It can probably be removed in favor of the macro or
replaced with one dispatch mechanism, but that is a cleanup rather than a CME
prerequisite.

## Code that should survive

Most of `venue_trade_specs.rs:200-576` is not venue retirement code. It defines:

- `VenueCalcContext`;
- position matching helpers;
- minimum order size/notional checks;
- `VenueAction`;
- the generic three-pass cancel/replace reconciliation algorithm.

The reconciliation algorithm and direct account/instrument lookups are useful
for CME. Keep them and review their semantics explicitly:

- whole-contract quantity and contract multipliers;
- venue tick and price-band rules;
- session state and order-entry cutoffs;
- expiration/trading termination;
- whether reduce-only or a min-notional close waiver has any CME meaning.

The current shared comments and helper parameters encode HL and Drift examples.
Those should be generalized when `CmeTradeSpecs` becomes the primary
implementation, but the helpers should not be deleted simply because their
first two consumers are retired.

Also keep the generic `WantedLimitOrder.reduce_only` and `venue_params` fields
in `strats_v2/src/calculation.rs:399-437`. CME may need venue-specific order
parameters, and these fields are not intrinsically Hyperliquid-only.

## Conservative retirement blast radius

### Drift

A target-spec-only deletion leaves Drift execution plumbing compiled but
unreachable from new targets. A complete target-executor retirement also
touches:

| Area | Evidence | Recommended action |
|---|---|---|
| Inbound order/swap lifecycle | `target_executor/engine_state/venue/drift.rs` (302 lines) | Delete after Drift orders/swaps are drained. |
| Drift protobuf conversion | `target_executor/wire_msg/drift_order_update.rs` (642 lines) | Delete with the inbound handler. |
| Drift swap conversion | `target_executor/wire_msg/swap_msg.rs` (271 lines) | Delete only if no retained venue uses the swap pipeline. |
| Topic routing | `engine_state/ready_state.rs:1918-1923,1998-2046` | Remove the Drift response arm and handler. Update the external ingress topic set separately if the binary still subscribes to it. |
| Venue context | `engine_state/ready_state.rs:1710-1723` and `engine_state/venue/drift.rs:255-301` | Remove the Drift account/context arm. |
| Account/delegate indexes | `strats_v2/src/accounts.rs:105-247,349-370` | Remove in a deeper pass; this is more coupled than calculation retirement. |
| Invalid market catalog | `strats_v2/src/markets.rs:1-29` | Remove or generalize; it currently contains only Drift data. |
| Spot routing | `target_executor/spot_route.rs:1-49` | Likely dead already because asset-ID targets are rejected; remove after proving no CME/simulator use. |
| Example configuration | `strats_v2/etc/target_exec_config.yaml.example:8-23` | Replace Drift-only instrument/account examples with CME-safe examples. |

`strats_v2/src/venue.rs` and `src/venue/drift.rs` are also Drift-only helpers
used by the executor's Drift message path. They can leave with that path, not
with the initial trade-spec deletion.

Removing Drift account/delegate support may allow `solana-pubkey` and other
stale Solana dependencies to leave `strats_v2/Cargo.toml`, but dependency
removal should follow a usage check. Some Solana dependencies already appear
unused independently of this change, so they should not be counted as proof of
venue-removal completeness.

### Hyperliquid

HL is cheaper to retire because real HL accounts are already rejected:

- `accounts.rs:229-234` returns `HyperliquidAccountNotSupported`;
- `ready_state.rs:1714-1716` returns `HlRealAccountNotWired`.

The live behavior that would regress is paper Hyperliquid. A paper account is
mapped to `HyperliquidVenueContext { is_paper: true }` at
`ready_state.rs:1717-1721`, and `ready_state.rs:1836-1848` consumes the HL
gateway status topic.

The conservative cleanup should:

- send `Venue::Hyperliquid` to the explicit unsupported arm;
- remove the paper-HL context and `HlRealAccountNotWired` path if no longer
  needed for diagnostics;
- remove the HL status subscription/dispatch when operators no longer expect
  paper-HL execution;
- retain `SimVenue` in
  `target_executor/engine_state/venue/uni_gw.rs`, because CME paper execution
  may reuse the simulator protocol;
- leave global HL request builders, market info, and protobuf contracts intact.

There are no HL-only features or dependencies in `strats_v2/Cargo.toml`, so
this is source and routing cleanup, not a meaningful dependency-pruning win.

## Deep-cleanup traps

### The swap pipeline is larger than DriftTradeSpecs

Drift is the current native-swap consumer, but `SwapManager`, `VenueAction::Swap`,
swap retry/status processing, and balance reconciliation are threaded through
Init/Ready state and the target manager. Deleting them can be reasonable for a
CME-derivative-only executor, but it is a separate refactor. It increases cost
and makes future spot-venue support harder to reintroduce.

Recommendation: leave the generic swap seam in the first CME release unless it
creates an actual implementation obstacle. Remove Drift wire conversion and
topic handling independently where possible.

### Test fixtures are Drift-shaped but not Drift-only in purpose

`target_executor/test_helpers.rs:98-280,348-362` builds Drift markets and
accounts for tests across calculation, balance/position tracking, target
types, target management, and both venue specs. It cannot be deleted wholesale.

The migration should create neutral or CME fixtures, then move tests that prove
generic behavior. In particular:

- generic reconciliation and matching tests should move beside shared code;
- CME tests should prove contract quantity/tick/session/termination behavior;
- venue-specific Drift/HL action tests can be deleted with their
  implementations;
- the target-manager invalid-market and swap integration tests at
  `target_position_manager.rs:792-1060` need replacement or intentional
  removal.

### Historical design documents become stale

`strats_v2/docs/MULTI_VENUE_HBGW_PRD.md` and the
`docs/venue-request-builder/` material describe Drift/HL-first assumptions.
They are historical artifacts, so rewriting them as current architecture would
destroy context. Mark them superseded by the CME decision/report or clearly
label their status instead.

### Operational drain precedes code deletion

Even if Drift is believed dead, removing response handlers while outstanding
orders or retry tasks exist leaves the executor unable to reconcile late
updates. Before removing inbound paths:

- prove there are no open Drift or paper-HL orders/swaps;
- disable new targets for the venues;
- drain/cancel retries and inflight work;
- decide what happens to old snapshots/replay inputs and retained NATS
  messages; and
- remove alerts/dashboards that would otherwise interpret the lost handlers as
  a failure.

This operational check is small if the venues truly have zero traffic, but it
is a release gate, not an assumption the compiler can verify.

## CME prerequisites not included in the removal estimate

Removing old venues does not create a CME executor. The following work is
required independently:

1. **Future market representation and catalog.** The current primary market
   sum types expose only Drift/HL spot and perpetual variants. The future traits
   exist, but a usable CME future `MarketInfo` variant/static catalog is still
   missing. See `brainstorm/reports/cme-mkt-info/dec-blast-radius.md`.
2. **CME account/venue context.** `trade_v2/src/order/request.rs:1-65` currently
   dispatches only Drift and Hyperliquid contexts/builders.
3. **Outbound request and inbound status protocol.** No CME gateway topic,
   order request builder, execution report decoder, or simulator route was
   found in `strats_v2`, `trade_v2`, `messaging`, or `sim-gw`.
4. **CME trade specs.** `CmeTradeSpecs` must implement validation, matching,
   action calculation, price/quantity quantization, and reconciliation policy.
5. **Behavior proof.** Tests must cover whole contracts, tick tables, sessions,
   order expiry/trading termination, fills, position updates, and restart/replay.

These prerequisites explain why “delete both files, then add CME” is the wrong
sequence: after the deletion there is no supported concrete executor, and the
compiler churn becomes mixed with the new venue design.

## Cost breakdown

### Option A — narrow trade-spec retirement: 0.5–1.5 days

- add or stage the CME/unsupported dispatch behavior;
- delete 2,241 lines from the two leaf files;
- update module declarations, imports, resolver/macro arms, and venue-specific
  comments;
- move the small amount of shared helper coverage that would otherwise vanish;
- run focused compile/tests.

This is the best choice if CME transport is being built in parallel and the
team wants to stop evolving Drift/HL calculations immediately.

### Option B — conservative executor retirement: 2–4 days

Includes Option A plus:

- Drift inbound handler and wire-parser retirement;
- HL target context/status retirement while preserving `SimVenue`;
- target-executor topic/config/error cleanup;
- operational drain checks;
- replacement of shared Drift-shaped fixtures where necessary;
- current-architecture documentation updates.

This is the recommended scope for the CME-first rollout.

### Option C — deep local purge: 5–10 days

Includes Option B plus:

- removal/redesign of Drift delegate/account indexing;
- removal of the generic swap pipeline and spot route provider;
- broader fixture conversion across `strats_v2`;
- manifest pruning;
- restart/replay and state-transition validation after structural state changes.

The upper end applies if account loading, simulator behavior, or generic order
submission must be redesigned simultaneously. The code deletion itself is not
the expensive part; proving that shared state and lifecycle behavior still work
is.

## Recommended sequence

1. Reject new Drift and HL targets explicitly and confirm zero live/inflight
   work.
2. Land the CME market representation/catalog.
3. Land the CME venue context, request builder, topics, and status decoder.
4. Add `CmeTradeSpecs` and make the resolver/macro dispatch CME Group venues
   intentionally. Decide whether CBOT/NYMEX/COMEX share the same ZST or use
   separate policy types.
5. Move generic matching/reconciliation tests to neutral/CME fixtures.
6. Delete the Drift and HL trade-spec leaves and route both venue variants to
   `UnsupportedFeature`.
7. Remove Drift inbound parsing and HL target subscription/context after the
   drain gate.
8. Run a later dead-code pass for swaps, delegate indexes, Solana dependencies,
   and historical docs. Keep that pass separate from CME bring-up.

This sequence minimizes the time the target executor has no supported venue
and keeps CME behavior reviewable apart from deletion noise.

## Acceptance and verification

The retirement is complete when:

- Drift and HL target requests return a deliberate unsupported-venue result;
- no target-executor subscription or context can accidentally submit new
  orders to either venue;
- CME targets pass validation and reach the CME order builder;
- shared order reconciliation retains dedicated tests;
- simulator status handling still works if retained;
- no Drift/HL examples remain in active target-executor configuration; and
- focused checks pass for `strats_v2`, `trade_v2`, and messaging, followed by
  the repository's `just check` gate.

Recommended execution tests:

- CME target -> wanted order -> encoded request;
- gateway accepted/rejected/cancel/modify responses;
- partial and complete fills updating positions;
- retry and reconciliation after an outstanding order;
- session closed and post-termination rejection;
- restart/replay with no retired-venue work present.

### Current verification baseline

The analysis attempted:

```text
RUSTC_WRAPPER= CARGO_TARGET_DIR=/tmp/rm-venues-target \
  cargo test -p strats_v2 --lib --no-fail-fast
```

The current workspace does not pass this baseline. Compilation fails in the
existing venue code because `Venue::home_spot_asset` is unavailable at three
Drift call sites and an HL test fixture calls the changed
`HlPerpMarketInfo::new` signature with too few arguments. These failures were
present before this report and no source files were changed to address them.
They reinforce the need to record a clean baseline—or explicitly accept known
failures—before using compile results to validate the removal.

## Recommendation

Proceed with **Option B**, but implement it as two reviewable changes:

1. add the CME execution seam and retire Drift/HL trade-spec dispatch; then
2. remove the old inbound/context plumbing after the operational drain gate.

Do not combine global Hyperliquid deletion or a generic swap/account rewrite
with the CME rollout. The likely saving is a few days of local maintenance and
roughly 2,241 immediately deletable lines, while preserving the abstractions
that make CME cheaper to land. A deep purge can follow once the CME path proves
which seams are genuinely reusable.
