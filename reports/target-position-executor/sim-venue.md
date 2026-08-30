# Minimal Target-Position Execution Through `sim-gw`

Date: 2026-09-03

## Decision

Paper trading is the only supported execution mode for this path. A target
position addressed to an attached paper account should be converted directly
into one limit create order and published to `sim-gw`.

The target executor does **not** need to model Hyperliquid, Drift, or any other
live venue. It does not need a generic live-venue execution policy either.
`sim-gw` is the execution venue.

The intended flow is:

```text
TargetPosition(account, instrument, target quantity)
  -> validate the exact account is an attached PaperAccount
  -> read the account's current position
  -> delta = target quantity - current quantity
  -> if delta is zero, report Completed
  -> resolve a limit price from the latest L1 midpoint
  -> submit one create-limit order directly to stxr.gw.sim.request
  -> consume the fill from stxr.gw.sim.response
  -> update the local position and report Completed
```

`sim-gw` immediately and completely fills a valid create-limit order at the
submitted price (`sim-gw/src/state/ready.rs:118-296`). “Immediately” still
means asynchronously over NATS, so the executor must retain enough state to
correlate the response and avoid duplicate orders while the fill is in flight.

## What the strategy template must do

The strategy should continue to publish desired absolute **positions**, not
orders. It already preserves account identity in the target map and publishes
the resulting target-position request through
`ActionManager::dispatch_live_action_set`
(`dsl-runtime/src/actions.rs:176-217`).

One behavior must change: spot targets currently encode as `Swap`, while
perpetual and future targets encode as `Limit(RelativePrice)`
(`dsl-runtime/src/utils.rs:44-130`). `sim-gw` supports limit create orders, not
swaps. For paper trading, spot, perpetual, and future targets should therefore
all use the same relative-limit mode:

```text
reference instrument = target instrument
beta                 = 1
c                    = 0
slippage             = configured execution slippage
clip                 = 100% of the remaining delta
```

The strategy does not need to send an absolute limit price. Its present
derivative encoding describes a price relative to the target instrument's
midpoint, allowing the executor to use the freshest price at submission time.
If the strategy later sends an absolute price, the executor's market-data
dependency can be removed for that request.

The setting currently named `swap_slippage_bps` should eventually be renamed
to describe limit execution, but that rename is not required to prove the
paper path.

## What the target executor must do

The entry point remains
`ReadyState::handle_target_position_request`
(`strats_v2/src/target_executor/engine_state/ready_state.rs:1052`). For every
target in the request, the paper-only path needs the following logic.

### 1. Validate the target

Validate the account named by that target, rather than asking whether the
strategy has any executable account:

1. the strategy exists;
2. the target account exists;
3. it is a `PaperAccount`;
4. it is attached to the requesting strategy;
5. the instrument exists;
6. the execution mode is `Limit`.

Reject live accounts and `Swap` requests with a target-position `Failed`
status. Do not attempt venue selection. The existing
`check_strategy_executable` only proves that some executable account is
attached and is insufficient for this check
(`strats_v2/src/accounts.rs:143-181`).

### 2. Calculate the remaining position delta

Read the current spot balance or derivative position for the target account:

```text
delta = target quantity - current quantity
```

If `delta` is zero, or below the configured execution tolerance, emit
`Completed` without creating an order. Otherwise:

```text
side     = Buy  when delta > 0, otherwise Sell
quantity = abs(delta)
```

For this simulator milestone, the whole remaining delta can be sent in one
order. There is no need for slicing, participation logic, or venue-specific
minimum-notional rules. Price and quantity may still be rounded to the static
instrument increments so paper behavior remains compatible with future
execution rules.

### 3. Resolve one limit price

Only one market-data value is needed: the latest L1 book midpoint for the
target instrument. A full depth book is unnecessary, and oracle data is not
used.

`LimitExecMode::px` already resolves a linear-relative price from
`MktDataManager::get_book_mid_px`
(`strats_v2/src/target_executor/types.rs:230-242`). It must also apply the
configured slippage directionally:

```text
buy limit  = relative price * (1 + slippage_bps / 10_000)
sell limit = relative price * (1 - slippage_bps / 10_000)
```

If no midpoint is available, retain the latest target and wait for a book
update. Do not submit a default or zero price. Startup currently does not wait
for book readiness (`engine_state/init_state.rs:225-233`), so this case is a
normal ordering race rather than a fatal error.

### 4. Send directly to `sim-gw`

Build a generic uni-gateway create-limit request containing:

- client order ID;
- paper account ID;
- instrument ID;
- side;
- quantity;
- limit price.

Publish it directly to `SimGwTopics::Request` / `stxr.gw.sim.request`. This
should use either a small `SimOrderRequestBuilder` or direct generic uni-gw
encoding. It must not construct a Hyperliquid or Drift context, inspect the
instrument's live venue, or require live-venue credentials.

The current `PaperAccount + Hyperliquid` routing through
`HyperliquidVenueContext { is_paper: true }`
(`ready_state.rs:1655-1696`) is accidental coupling and should be bypassed or
removed for this path.

### 5. Keep only the asynchronous state required for correctness

Use one target key consistently:

```text
TargetKey = (strategy_id, account_id, position identifier)
```

Retain only:

- the latest requested target for each `TargetKey`;
- at most one in-flight client order ID for each `TargetKey`;
- the reverse correlation from client order ID to its `TargetKey` and request;
- the current position/balance already maintained from execution reports and
  account updates.

This account dimension is necessary because the strategy request can target
the same instrument in multiple paper accounts. The current target storage and
order correlation lose part of that identity
(`target_position_manager.rs:157-219`, `:439-466`).

If a newer target arrives while an order is in flight, store it but do not
submit a second order. After the old fill is applied, recalculate from the
newest target. This is the only reconciliation behavior needed.

### 6. Complete from the simulator response

Keep the existing inbound simulator path. `ReadyState` already routes
`stxr.gw.sim.response` through `SimVenue::handle_order_update` and then into
order-result processing (`ready_state.rs:1820-1832`). The execution-report
handler already updates local balances and positions
(`ready_state/order_handler.rs:70-143`).

On a terminal fill:

1. apply the fill to the local account state;
2. clear the in-flight correlation;
3. compare the newest target with the updated position;
4. emit `Completed`, or submit the remaining delta if the target changed while
   the fill was in flight.

Terminal rematching must cover spot as well as derivatives. The current path
only rematches derivatives (`ready_state/order_handler.rs:757-1003`) because
spot historically used swap mode.

On a simulator rejection, clear the in-flight record and emit `Failed`. A
venue-aware retry heap is not required for the first paper-only implementation.

## Existing code to retain

- target-position wire decoding and status publication;
- paper-account, balance, and position repositories;
- `MktDataManager`'s L1 midpoint;
- order IDs and the order/execution-report tracker;
- the `SimGwTopics::Response` subscription;
- `SimVenue`'s uni-gw response decoder;
- account-position updates published by `sim-gw`.

## Logic that is not required

- Hyperliquid or Drift contexts and request builders;
- routing based on the instrument's live venue;
- `VenueTradeSpecs` or a new `PaperTradeSpecs` abstraction;
- oracle prices;
- full order-book depth;
- spot swap mode and the swap manager;
- modify, cancel, cancel-all, or open-order reconciliation;
- resting-order and partial-fill handling;
- order slicing or multi-clip execution;
- live-venue minimum notional, margin, leverage, or authentication logic;
- complex venue-classified retry policies.

Those abstractions may remain elsewhere in the repository, but the paper path
should neither depend on them nor extend them.

## Minimal implementation changes

1. In `dsl-runtime/src/utils.rs`, encode spot targets as the same
   midpoint-relative limit mode used by derivatives.
2. In `ReadyState::handle_target_position_request`, add the exact
   paper-account gate and drive a direct paper-target handler.
3. Make target and order correlation account-aware.
4. Calculate `delta`, side, quantity, and the slippage-adjusted midpoint price.
5. Add a generic sim create-limit encoder and publish to
   `stxr.gw.sim.request` without a live-venue context.
6. Defer a target when its midpoint is unavailable and reconsider it on a book
   update.
7. Rematch both spot and derivative targets after a simulator fill.
8. Report `Completed` or `Failed` against the correct request and account.

## Acceptance criteria

- A spot, perpetual, or future target for an attached paper account produces
  exactly one create-limit request on `stxr.gw.sim.request`.
- No Hyperliquid or Drift context, credentials, or request topic is involved.
- The order side and quantity equal the remaining target delta.
- Its price comes from the latest midpoint with directional slippage.
- A missing midpoint delays submission without losing the target.
- The simulator fill updates the correct paper account and produces
  `TargetPositionStatusUpdate::Completed`.
- A second target received during the in-flight fill does not create a
  duplicate order and is recalculated after that fill.
- Two paper accounts targeting the same instrument cannot overwrite or
  complete each other's targets.
- Oracle, swap, modify, cancel, and live-venue code are not exercised.

## Open product choices

Only three choices materially affect this minimal contract:

1. whether paper spot sells may create a negative balance;
2. how old an L1 midpoint may be before it is considered stale;
3. whether a simulator rejection is immediately `Failed` or gets one bounded
   infrastructure retry.

They do not require any live-venue integration.
