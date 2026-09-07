## 2. Target executor cancellation

```text
TargetPositions
  → reconcile one wanted position
  → inspect every tracked order for that account/instrument
  → retain matching quantity
  → cancel every remaining live order
  → sim-gw rejects every cancellation
  → clear pending_cancel and restore order as live
  → next target/position update repeats everything
```

The ingress begins in [target_position.rs](strats_v2/src/target_executor/logic/target_position.rs:58).

The critical decision has no batch limit: every unmatched tracked order produces a cancellation in one pass [calculation.rs](strats_v2/src/calculation.rs:282). That explains the observed 5,989 cancellation requests in one second.

`sim-gw` rejects cancellation as unsupported: [ready.rs](sim-gw/src/state/ready.rs:631). The response clears `pending_cancel`: [state.rs](trade_v2/src/order/state.rs:375), then deliberately restores the still-live order to the searchable index: [tracker.rs](trade_v2/src/order/tracker.rs:1079).

So the tracker is behaving consistently: a rejected cancellation means the order still exists. The incompatibility is between the executor expecting cancel support and the simulator rejecting it.

Demoting logs controls the bill, but the functional fix is to align simulator cancellation semantics, deduplicate target events, and cap reconciliation work so one event cannot emit thousands of requests.
