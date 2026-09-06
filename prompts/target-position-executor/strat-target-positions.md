# Strategy target positions: slots, bitsets, partial coverage

Status: blocked on the target position contract
(`data-feed-definitions/rust/crates/data-feed-definitions/src/demo/target_position.rs`).
`TargetSetCoverage::Partial` must exist and be documented as "absent means
unchanged" before this task starts.

## Topology

```
strategy runtime (dsl-runtime + generated strategy)
  -> ActionManager::dispatch_live_action_set            dsl-runtime/src/actions.rs:176
    -> build_action_proto_request                       dsl-runtime/src/utils.rs:44
    -> NATS TargetExecRequestTopic                       <emits TargetPositions>
target executor (strats_v2)
  -> ReadyState::handle_target_position_request          ready_state.rs:1052
    -> SingleStratTargetManagerWithCtx::update_target_position  target_position_manager.rs:157
       insert-or-replace per target; absent targets are left untouched
```

The executor already consumes the strategy deployment feed
(`demo/strategy_deployment_feed.rs`, protobuf codec under
`data-feed-definitions/rust/crates/codecs/data-feed-codec-protobuf-8ab444b323e391fcd0006ecf4b026ca5`).
The runtime side still emits the old `TargetPositionRequest` schema.

## Problem

`TargetPositions` in `dsl-runtime/src/actions.rs:262` is an
`AHashMap<(TradingAccountId, InstrumentId), Target>`. The key does not fit the
new contract, where identity is account plus subject plus market, and market
may be `Automatic`. Iteration order is random, so the wire order and log lines
differ per process. Uniqueness is already enforced at compile time by semantic
rule E3101038, so the map re-derives a guarantee it already has.

Two diffs disagree. The dispatch gate `should_dispatch_action_set`
(`actions.rs:163`) uses `is_similar` with a tolerance. The logging trigger in
`dsl-processor-core/src/versions/v1_1/codegen/strategy_policy.rs:319` uses an
exact compare and treats absence as zero, while the executor treats absence as
unchanged. Both resend the whole state set when any target moves.

## Design

Codegen assigns every distinct target declaration across all states a slot
index in canonical order (`ir/canonical_ids/state_ids.rs` already sorts them).
A state arm writes quantities into a fixed array and returns a per-state mask
built once at init. `N` is a codegen constant.

```rust
// dsl-runtime/src/actions.rs
pub struct TargetSlots<'a, const N: usize> {
    /// Read only where `constrained` is set.
    pub qty: [Qty; N],
    /// Which slots this state declares. One FixedBitSet per state, built at init.
    pub constrained: &'a FixedBitSet,
    pub block_seq: SequenceNumber,
}

/// Resolved once at init from strategy params. Indexed by slot.
pub struct SlotMeta {
    pub account_id: TradingAccountId,
    pub subject: TargetPositionSubject,
    pub market: TargetPositionMarket,
    pub price: TargetPositionPrice,
}
```

One diff replaces both `is_similar` and `target_positions_changed`. A slot is
sent only when it crosses the tolerance on its own, or has never been sent.

```rust
pub struct EffectiveTargets<const N: usize> {
    qty: [Qty; N],
    known: FixedBitSet,   // slots dispatched at least once
    changed: FixedBitSet, // scratch, reused every evaluation
}

impl<const N: usize> EffectiveTargets<N> {
    pub fn diff(&mut self, cur: &TargetSlots<'_, N>, tolerance_bps: u64) -> &FixedBitSet {
        self.changed.clear();
        for i in cur.constrained.ones() {
            let unknown = !self.known.contains(i);
            if unknown || !within_tolerance(self.qty[i], cur.qty[i], tolerance_bps) {
                self.changed.insert(i);
            }
        }
        &self.changed
    }

    /// Call after a successful dispatch.
    pub fn commit(&mut self, cur: &TargetSlots<'_, N>) {
        for i in self.changed.ones() {
            self.qty[i] = cur.qty[i];
        }
        self.known.union_with(&self.changed);
    }
}
```

Dispatch when `changed` has any bit set. The message carries
`coverage = Partial` and exactly the slots in `changed`, in slot order.
`EmitTrigger::TargetPositionChange` is the same condition.

`SlotMeta` and `qty` are parallel arrays: four contract fields are fixed per
deployment, only quantity is computed per tick. A view joins them at one index.

```rust
// dsl-runtime/src/utils.rs
pub struct SlotView<'a> {
    meta: &'a SlotMeta,
    qty: Qty,
}

impl TargetPosition for SlotView<'_> {
    fn account_id(&self) -> TradingAccountId { self.meta.account_id }
    fn subject(&self) -> TargetPositionSubject { self.meta.subject }
    fn market(&self) -> TargetPositionMarket { self.meta.market }
    fn quantity(&self) -> Qty { self.qty }
    fn price(&self) -> TargetPositionPrice { self.meta.price }
}

/// Handed to the codec. Borrows the runtime, allocates nothing.
pub struct TargetPositionsEvent<'a, const N: usize> {
    slot_meta: &'a [SlotMeta; N],
    cur: &'a TargetSlots<'a, N>,
    changed: &'a FixedBitSet,
    // identity, tracing, orderand, strategy ids, times ...
}

impl<const N: usize> TargetPositions for TargetPositionsEvent<'_, N> {
    fn coverage(&self) -> TargetSetCoverage { TargetSetCoverage::Partial }
    fn positions(&self) -> impl ExactSizeIterator<Item: TargetPosition> {
        // FixedBitSet::ones() is not ExactSizeIterator; wrap it with count_ones(..).
        SlotIter::new(self.changed, self.slot_meta, &self.cur.qty)
    }
}
```

If a later DSL version sets price or market per state, that field moves from
`SlotMeta` into a second per-slot array written by the state arm. Still one
index.

`fixedbitset` is already a dependency of `dsl-runtime` and is used in
`src/computation_graph.rs`.

## Files

- `dsl-runtime/src/actions.rs`: replace `TargetPositions`, `Target`,
  `is_similar`, `should_dispatch_action_set` with the types above.
- `dsl-runtime/src/utils.rs`: `build_action_proto_request` emits the strategy
  deployment feed event through the codec, not `TargetPositionRequest`.
- `dsl-processor-core/.../codegen/decision_program.rs:61`: slot assignment,
  per-state `constrained` masks, array writes instead of `insert`.
- `dsl-processor-core/.../codegen/strategy_policy.rs:319`: delete
  `target_positions_changed`, take the trigger from `diff`.
- `dsl-processor-core/.../semantic/decision_program_rules.rs`: add a warning
  when a state stops constraining a slot another state sets. Under Partial the
  executor keeps the old value silently.
- `knowledge-base/docs/references/strategy-runtime.md:173`: already describes
  Partial behavior; update the code references after the change.

## Behavior delta

Today a target inside tolerance is refreshed whenever any other target crosses
tolerance. After this change it is sent only when it crosses on its own. The
first evaluation sends every constrained slot, including explicit zeros, which
matches the dispatch gate today and fixes the logging trigger.

## Out of scope

- Full coverage on the wire. Never-mentioned slots would be flattened by the
  executor, which is a product decision.
- Executor changes. Its insert-or-replace map is exactly Partial semantics.
