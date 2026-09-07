# Venue Core and Per-Venue Simulators

Date: 2026-09-24

## Context

Paper trading (`sim-gw`) and backtesting need the same matching and accounting
logic, so a strategy behaves the same against live market data and against a
replay. We support four venues: CME, CBOT, NYMEX and COMEX. For the demo, all
four fill every order.

Today the logic exists twice:

- `sim-gw/src/logic/{order,deposit,withdrawal,position}.rs`
- `SimVenue` in `dsl-runtime/crates/dsl-backtest-runtime/src/sim_venue.rs`

Both are replaced by one reusable library in `venue-core`.

## How a real exchange is organized

The venue simulator combines what are separate systems at a real exchange.

```text
Customer ─► FCM (broker) ─► Order entry gateway ─► Pre-trade risk ─► Matching engine ─► Clearing house
              │                                                           │
              │                                   Market data, drop copy ◄┘
              └─ holds customer cash; deposits and withdrawals happen here
```

- **Order entry gateway**: sessions, authentication, message sequencing,
  duplicate client order id rejection, throttling.
- **Pre-trade risk**: credit limits, price bands, maximum order size.
- **Matching engine**: one order book per instrument, a matching algorithm per
  product, market states, execution reports.
- **Clearing house**: turns trades into positions, computes margin, settles
  gains and losses daily against the settlement price, handles expiry.
- **FCM**: holds the customer's account and cash.

CME, CBOT, NYMEX and COMEX run on the same platform (Globex) and clear through
the same clearing house (CME Clearing). They differ mostly in listed products
and rulebooks, so sharing one simulator across them matches reality.

Our mapping: `matching` plays the matching engine, `accounting` plays the
clearing house and the FCM together. The gateway concerns (transport,
sessions, persistence) belong to the hosts.

## venue-core: `venue-core/rust/crates/venue-simulator`

A library, not an engine component. It does no I/O: no network, no clock reads
(time is passed in), no randomness. The same inputs always give the same
events, which a reproducible backtest depends on.

| Module       | Role                                                                                                                                                                                     |
|--------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `command`    | What the user requested: `SubmitOrder`, `Deposit`, `Withdraw`.                                                                                                                           |
| `event`      | What happened: `OrderAccepted`, `OrderRejected`, `Fill`, `DepositApplied`, `WithdrawalApplied`, `WithdrawalRejected`, `TradingAccountPositionsUpdate`.                                  |
| `order`      | Validation, venue order ids from a counter, duplicate client order id check.                                                                                                            |
| `risk`       | Pre-trade check. Accepts every order for now.                                                                                                                                            |
| `matching`   | `Matcher` trait and `AlwaysFill`, which fills at the order price for the full quantity.                                                                                                  |
| `accounting` | Cash and positions per trading account on top of the prototype position tracker. Applies fills, deposits and withdrawals, and credits realized P&L to cash when a position is reduced. |

```text
SubmitOrder ─► order ─► risk ─► matching ─► accounting ─► [OrderAccepted, Fill, PositionsUpdate]
Deposit     ─────────────────────────────► accounting ─► [DepositApplied, PositionsUpdate]
Withdraw    ─────────────────────────────► accounting ─► [WithdrawalApplied | WithdrawalRejected, PositionsUpdate]
```

### handle and apply

Each operation is split in two:

```rust
fn handle(&self, command: Command, now: NanoTimestamp) -> Result<Vec<VenueEvent>, Rejection>; // decides, changes nothing
fn apply(&mut self, event: &VenueEvent);                                                        // changes state, cannot fail
```

- Live: `handle`, publish the events, `apply` each one.
- Restart: `apply` every stored event in order. This rebuilds cash, positions
  and the duplicate id buffer with the same code the live path ran.
- Backtest: the live path. The starting deposits are the first events.

### Orders

- Orders always refer to an instrument (the market).
- Every order gets a venue order id from a counter, even though it fills at
  once. The events carry the order's history; the venue keeps no order store.
  The book of resting orders is empty while every order fills.
- An order is reported as `OrderAccepted` followed by `Fill`s that reference
  the venue order id. Cancellations and partial fills fit the same shape when
  resting orders arrive.
- Duplicate client order ids are rejected using a ring buffer of the last 30
  ids per account, keyed by `(account, client order id)`. One buffer shared by
  all accounts would let a busy account push out everyone else's ids.

### Risk

Accepts every order. No margin and no liquidation. The seam exists so a check
(balance for spot, margin for futures) is a change in one place later. A
failed check will reject the whole order with a reason and book nothing, as
Binance, CME and Coinbase do.

### Matching

`Matcher` is the extension point. `AlwaysFill` turns an order into one
execution at the order price. A book-based matcher that takes market data and
rests orders can replace it without changing accounting, which only sees
executions.

### Accounting

- Positions are keyed by contract id (derivatives) or asset id (spot).
  Instrument → contract or asset resolution, contract multipliers and
  settlement assets come from the market info repo.
- Futures fills move the position, not cash. Cash moves on deposits,
  withdrawals and realized P&L.
- Realized P&L is settled into cash when a position is reduced or closed,
  using the average cost method (the same model as Binance futures):

  | Fill          | Position | Average entry | Realized             |
  |---------------|----------|---------------|----------------------|
  | buy 2 @ 100   | +2       | 100           | 0                    |
  | buy 2 @ 110   | +4       | 105           | 0                    |
  | sell 3 @ 120  | +1       | 105           | (120 − 105) × 3 = 45 |
  | sell 1 @ 120  | 0        | none          | 15                   |

  Multiplied by the contract multiplier. Increasing a position updates the
  average; reducing it leaves the average unchanged and realizes P&L on the
  reduced quantity; flipping closes the old side, then opens the new side at
  the fill price; a flat position has no average.
- The tracker stores the total outlay and derives the average entry price as
  `outlay / qty` on read, as the prototype does. Summing outlay is exact;
  storing the average would round on every fill that grows the position.
- A withdrawal larger than the balance is rejected (the no-negative-balance
  policy in DEC-07XKF). This is the one rejection that exists while risk
  accepts everything.
- No fees.

### Position updates

Every state change emits a `TradingAccountPositionsUpdate` for the affected
account with coverage `Full` and amount semantics `Absolute`: the account's
whole state after the change. A consumer that misses an update is back in
sync after the next one.

## Per-venue crates: `{venue}/rust/crates/{venue}-venue-simulator`

Thin. Each holds:

- the venue identity;
- its configuration;
- a constructor that picks the matcher, e.g. `VenueSimulator<AlwaysFill>`.

Venue-specific rules (trading hours, price bands, a different matching
algorithm) go here when a venue needs them. Until then, the four crates stay
nearly identical.

## Hosts: sim-gw and the backtest

The hosts own what sits outside the venue logic:

- transport: NATS for sim-gw, the replayed wires and their latency for the
  backtest;
- event ids, trace ids, the feed orderand (`SimGwOrderand`, DEC-0ANEJ) and
  `send_time`; the venue stamps only `event_time`;
- storing events and restoring state (sim-gw only).

The backtest starts every run from its configured deposits and needs no
restore.

### sim-gw restore

sim-gw currently loads positions and balances from the backend API at boot
(`load_positions_into_trackers` in `sim-gw/src/init.rs`). The backend derives
those from the venue's own feed, and they lack the cost basis settling on
reduce needs. The venue should restore from its own events instead:

1. Now: replay every stored venue event through `apply`.
2. Later, when replay gets slow: load a snapshot taken at feed position N and
   replay only the events after it.

sim-gw publishes to NATS and something downstream stores the events, so the
store can lag behind what was published. On boot, sim-gw has to confirm the
stored orderands are contiguous and complete before accepting commands.
Reading from a durable stream with a known end (e.g. NATS JetStream) is the
simplest way to guarantee that.

## Open work

- The prototype's `CostBasisUpdate::Remove` only handles long positions:
  buying back part of a short fails with `RemoveExceedsQuantity`. Contract
  positions need a signed reduce operation that uses up cost basis at the
  average price, for both reducing and flipping.
- The target executor and the backtest results feed only handle fills today.
  They need to handle `OrderRejected` once risk starts rejecting.
- Choose the durable source sim-gw restores from and how it knows the store
  has caught up.
