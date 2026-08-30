# Simulation Venue Feed Implementation Requirements

Status: brainstorm implementation assessment  
As of: 2026-09-01  
Parent: [ENG-1942: Implement the sim venue feed](https://linear.app/stxr/issue/ENG-1942)  
Governing decision candidate: [DEC-0ANEJ: Simulation Venue Feed](../../../knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md)

This report inventories the work necessary to implement the simulation venue
feed. It is not an implementation plan, a protobuf design, or permission to
create the missing traits and messages. Contract ownership and exact file
placement remain explicit TODOs.

Planning context: the issue key places the work in the Linear Engineering team.
No Linear project was established by the available sources, so this report does
not assume one. The private contents of ENG-1942 were not available during this
assessment; only the title/link supplied in the request are used, and no unseen
ticket acceptance criteria are inferred.

## Executive conclusion

The feed cannot yet be implemented safely as a single `sim-gw` change. The
runtime already has most of the source facts for fills and account snapshots,
and Uni-GW already has deposit/withdrawal command and response messages. It does
not have the dedicated simulation-venue feed contract, event-specific semantic
traits, wire/domain conversions, feed topic, feed definition, reliable
orderand/identity state, fee behavior, or working transfer mutation handlers.

The minimum dependency chain is:

1. Reconcile the proposed decisions/specs and publish a living simulation-venue
   feed specification.
2. Decide ownership and placement for semantic traits, generated protobuf
   bindings, conversions, feed topics, and the feed definition.
3. Define the domain contract and protobuf wire contract without cost basis.
4. Add a dedicated wire adapter and parse/encode at the boundary.
5. Add event identity, tracing, timing, orderand, snapshot/recovery, and
   publication capabilities to `sim-gw`.
6. Emit fills and full/absolute position updates from the existing successful
   fill path.
7. Implement deposit and withdrawal mutations, then emit their raw events and
   resulting position updates.
8. Define the demo fee policy and only then implement fee mutation and emission.
9. Integrate the feed definition, downstream raw-event ingestion, semantic
   projections, replay/deduplication, observability, and end-to-end tests.

The cost-basis boundary is non-negotiable for this assessment: the simulation
venue does not calculate, maintain, validate as accounting policy, or emit cost
basis. Consumers derive cost basis from raw economic events.

## Assumption register

Checked items are working assumptions used to make this report actionable.
Uncheck any item that is not acceptable; requirements depending on it then need
to be revised before implementation.

- [x] **A-01 — Scope boundary.** ENG-1942 owns the producing feed and its
      prerequisite shared contracts. Downstream storage/compute changes are
      integration dependencies and acceptance work, not automatically part of
      the `sim-gw` implementation patch.
- [x] **A-02 — Proposed decision as target.** DEC-0ANEJ describes the desired
      target even though its lifecycle status is `proposed`; implementation must
      not begin until its unresolved contradictions are accepted or amended.
- [x] **A-03 — Separate command and event contracts.** Uni-GW request/reply
      remains the command path. The simulation-venue feed is a separate egress
      event stream, not another Uni-GW response branch.
- [x] **A-04 — NATS/protobuf transport.** The first wire encoding is protobuf
      over NATS because `sim-gw` already publishes NATS protobuf messages and
      the requested schema area is `messaging/msg-schemas/proto/sim-venue`.
      The package, envelope, binding owner, and subject are still undecided.
- [x] **A-05 — Backward compatibility.** Existing Uni-GW responses, order
      updates, and `position_server.accounts.*.position_update` publications
      remain available while the new feed is introduced, unless a separate
      migration decision explicitly replaces them.
- [x] **A-06 — Initial position shape.** The current post-mutation full account
      snapshot maps to `coverage = Full` and `amount_semantics = Absolute`.
      Partial/incremental updates are supported by the contract but are not
      required for the first producer slice.
- [x] **A-07 — Transfer milestone.** Deposit and withdrawal apply only to paper
      accounts and the configured valuation asset. The older documents name USD
      specifically; replacing USD with another valuation asset requires an
      explicit contract/configuration change.
- [x] **A-08 — Provenance deferral.** Provenance remains out of the demo payload
      until its source and shape are decided. The design must leave an extension
      point, but must not invent provenance.
- [x] **A-09 — No venue accounting analytics.** PnL, cost basis, average entry
      price, portfolio value, volume, turnover, normalization, and aggregate
      computation remain consumer responsibilities.
- [x] **A-10 — One semantic derivation.** Existing Uni-GW trade output and the
      new feed fill must be derived from one validated fill result, rather than
      independently re-deriving price, quantity, side, timing, or identifiers.

## Source authority and conflicts

The sources do not form one internally consistent contract. Implementation must
apply this precedence for ENG-1942:

1. The user's explicit constraint in this task: **no cost basis in the venue**.
2. The final accepted simulation-venue feed spec/decision created from this
   work.
3. Current living references/specs that do not conflict with that contract.
4. Proposed decisions and draft specs as design evidence, not automatically as
   implementation authority.
5. Current code as evidence of existing behavior, not as authority when it
   conflicts with the standards or desired contract.

Material conflicts that must be resolved:

| ID | Conflict | Required resolution |
| --- | --- | --- |
| `CONFLICT-01` | [DEC-07XKF](../../../knowledge-base/docs/decisions/records/DEC-07XKF-paper-trading-account-deposit-withdrawal.md) and the draft [transfer spec](../../../knowledge-base/docs/specs/SPEC-trading-account-deposit-withdrawal-application-server.md) require client-supplied deposit `cost_basis` and `cost_basis_asset_id`. DEC-0ANEJ exposes `DeclaredCostBasis::NotApplicable`; this task says the venue calculates no cost basis. | Amend/supersede the older request contract, or explicitly define boundary behavior for legacy fields. Do not silently consume, validate, store, calculate, or emit them. |
| `CONFLICT-02` | The draft [position-update spec](../../../knowledge-base/docs/specs/SPEC-trading-account-position-update-feed.md) requires cost basis on positions. DEC-0ANEJ and [DEC-0A5FN](../../../knowledge-base/docs/decisions/records/DEC-0A5FN-backtest-feed-emits-raw-economic-events.md) remove it. | Make the simulation-venue feed's no-cost-basis position contract explicit. Do not claim conformance to the older position spec without updating it. |
| `CONFLICT-03` | [DEC-07RE5](../../../knowledge-base/docs/decisions/records/DEC-07RE5-simulation-venue-orderand.md) requires per-simulated-venue orderand snapshot/recovery. DEC-0ANEJ describes a supposedly stateless demo encoding, while `sim-gw` currently uses `NullPersister`. | Decide whether the milestone implements durable orderand recovery or formally accepts a weaker temporary guarantee. Define restart behavior and collision handling either way. |
| `CONFLICT-04` | DEC-0ANEJ writes `(seconds since Jan 2026) << 31 \| (sequence number & 2^32)`. A 31-bit shift overlaps a 32-bit low component, and `& 2^32` is not a lower-32-bit mask. | Replace the prose with an exact, tested bit layout or choose another opaque representation. Do not implement the expression as written. |
| `CONFLICT-05` | DEC-0ANEJ uses producer `send_time`; the storage demo uses consumer `observe_time`. | Define both timestamps and the downstream mapping. They must not be renamed as if they were the same fact. |
| `CONFLICT-06` | DEC-0ANEJ includes withdrawals, but the proposed schema in [DEC-0ADYZ](../../../knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md) has a `deposits` table and no withdrawal table. | Add a withdrawal semantic projection or explicitly define another storage representation before end-to-end acceptance. |
| `CONFLICT-07` | `DemoOnlyFee::fee()` has no explicit asset/unit or sign convention, while storage uses signed `Int128`; current simulated fills always set `fee: None`. | Define fee unit, sign/rebate semantics, calculation policy, balance effect, and zero-fee behavior before emitting fee events. |
| `CONFLICT-08` | Orderands are scoped per simulated venue, but a deposit/withdrawal event has no instrument or venue field and the in-memory `PaperAccount` retains only an account ID. | Define how every event resolves its simulated-venue/feed partition without guessing. |

## Confirmed current implementation state

### Shared domain/feed infrastructure

- `entity-core` already defines the generic metadata traits `HasIdentity`,
  `HasTracing`, `HasFeedOrderand`, and `HasProvenance` in
  [`data_feed/traits.rs`](../../../entity-core/crates/entity-core/src/entities/data_feed/traits.rs).
  They must be reused, not recreated.
- No repository implementation was found for the event-specific DEC-0ANEJ
  traits: `Fill`, `TradingAccountPositionsUpdate`, `Deposit`, `Withdrawal`, or
  `DemoOnlyFee`; nor for `SimGwOrderand` or the simulation-feed supporting
  position types.
- `entity-core` can describe non-market feeds through `Other` event kinds and
  subjects, and already has `InternalDataFeedProvider::Simulator`. No concrete
  simulation-venue `DataFeedDefinition` was found.

### Messaging

- [`messaging/msg-schemas/proto/sim-venue`](../../../messaging/msg-schemas/proto/sim-venue)
  exists but is empty.
- Uni-GW already contains `DepositRequest`, `WithdrawalRequest`, accepted/rejected
  gateway responses, trace IDs, request time, client time, correlation ID, and
  an idempotency key in
  [`requests.proto`](../../../messaging/msg-schemas/proto/gw/uni-gw/requests.proto)
  and
  [`status_updates.proto`](../../../messaging/msg-schemas/proto/gw/uni-gw/status_updates.proto).
- The existing Uni-GW deposit request still contains the conflicting cost-basis
  fields.
- Existing `structure.account_events` has legacy `TradeEvent`, `FundsEvent`, and
  `PositionServerAccountUpdate` messages. They do not implement the DEC-0ANEJ
  metadata and event shapes and must not be mistaken for the new feed contract.
- `PositionServerTopics` has legacy trade/funds/position subjects. `SimGwTopics`
  has only request and response subjects. There is no dedicated
  simulation-venue feed subject.
- Messaging's Rust build discovers protobuf files automatically, but public Rust
  module exposure is explicit. TypeScript and Python regeneration also rewrite
  generated trees. Binding ownership must be decided before editing generation.

### `sim-gw`

- Successful supported limit orders immediately publish a gateway acceptance,
  a venue acceptance, a Uni-GW `Trade`, mutate account state, and publish a
  legacy position-server account snapshot.
- The current trade has no standalone event ID, no feed orderand, and `fee:
  None`. Its trace is present only on the gateway response, not the `Trade`
  payload.
- Spot fills mutate base and quote balances. Derivative fills mutate the
  position tracker. The produced position snapshot contains all active balances
  and derivative positions for the account.
- The current position update has a timestamp and generic `SequenceNumber`, but
  lacks the DEC-0ANEJ event ID, trace ID, `SimGwOrderand`, send time, coverage,
  amount semantics, and separate spot/derivative semantic contract.
- Current fill sequencing is derived from the ingress timestamp. There is no
  per-simulated-venue orderand state.
- `SimGwData` is serializable, but the runtime config uses `NullPersister`; the
  service does not currently persist engine snapshots.
- Uni-GW deposit and withdrawal commands are decoded and receive a structured
  `unsupported operation` rejection. Request/reply egress to the incoming NATS
  reply subject is already wired.
- The balance tracker accepts signed deltas and does not enforce the milestone
  no-negative-withdrawal policy. That validation belongs in sim-gw domain/
  application behavior.
- [`ISSUE-0001`](../../../sim-gw/docs/issues/records/ISSUE-0001-protobuf-boundary-domain-mapping.md)
  records that protobuf-generated messages currently cross into simulation
  business logic. The feed must not extend that debt.

## Required contract decisions before implementation

Each item below is a blocking design output, not an assumed implementation.

### `REQ-DEC-001` — Feed boundary and topology

Define whether there is one feed per simulated venue, one per gateway instance,
one per trading account, or one global simulation feed. Define the stable feed
partition key and how fills, fees, transfers, and account snapshots resolve it.
This is required before orderands, subjects, feed IDs, and recovery can be
correct.

### `REQ-DEC-002` — Living behavioral specification

Create or update a living `SPEC:` for the simulation-venue feed. It must assign
stable requirement IDs and define:

- event families and exact semantic fields;
- event production triggers;
- validation and failure behavior;
- identity, tracing, timestamp, ordering, and provenance rules;
- delivery, retry, deduplication, replay, and recovery guarantees;
- fee and transfer behavior;
- wire compatibility and migration;
- downstream expectations and definition of done.

DEC-0ANEJ is a proposed decision and is not a sufficient implementation spec by
itself.

### `REQ-DEC-003` — Semantic trait ownership

Choose the crate/repository that owns `Fill`,
`TradingAccountPositionsUpdate`, `DerivativePosition`, `SpotPosition`,
`Deposit`, `Withdrawal`, `DemoOnlyFee`, `SimGwOrderand`,
`PositionSetCoverage`, and `PositionAmountSemantics`.

Constraints:

- shared consumer-facing semantic contracts must not be owned only by the
  `sim-gw` infrastructure adapter;
- reuse `entity_core::entities::data_feed::{HasIdentity, HasTracing,
  HasFeedOrderand, HasProvenance}`;
- semantic contracts must not depend on protobuf, NATS, generated messages, or
  storage rows;
- the chosen owner must preserve inward dependency direction and be consumable
  by both the producer and downstream fold/storage components.

### `REQ-DEC-004` — Generated binding and conversion ownership

Choose exactly one owner for the generated `sim-venue` Rust protobuf package:

- shared generation in `messaging`; or
- service-specific generation in a dedicated wire crate with imported shared
  packages mapped to `messaging`.

Do not generate the package in both places. Regardless of generated binding
ownership, domain/message conversion logic belongs in a dedicated `*-wire`
crate, not in `messaging` and not in simulation business logic.

### `REQ-DEC-005` — Protobuf package, envelope, and compatibility

Decide:

- protobuf package and version namespace;
- one envelope with an event `oneof` versus separate messages/subjects;
- whether common metadata is in the envelope or repeated in each event;
- presence rules for proto3 message/scalar fields;
- reserved field numbers/names and compatibility policy;
- whether feed ID/revision/encoding travel in the message, NATS metadata, or are
  resolved from the subject/catalog;
- the exact Rust, TypeScript, and Python generated API surface required by
  consumers.

### `REQ-DEC-006` — NATS subject and routing contract

Define the publish subject(s), wildcard subscription shape, account/venue
routing dimensions, topic enum owner, and configuration. Do not reuse a legacy
position-server or Uni-GW response subject merely because it already exists.

### `REQ-DEC-007` — Event identity

Define how each emitted event obtains a unique `telemetry::EventId`, including:

- uniqueness scope and generator owner;
- one source action producing several distinct event IDs;
- deterministic identity across engine replay/retry;
- behavior after restart and clock rollback;
- storage idempotency and duplicate publication;
- whether a source command idempotency key participates in derivation.

A random ID regenerated on retry would defeat downstream idempotency.

### `REQ-DEC-008` — Trace propagation

Define how a required feed `TraceId` is obtained when the incoming Uni-GW
request has no trace ID. A successful fill, its fee, its position update, and
related transfer events should be correlatable without using one event ID for
multiple facts. Missing/invalid trace handling must be explicit.

### `REQ-DEC-009` — Orderand representation and state

Define an opaque `SimGwOrderand` with exact construction and comparison rules:

- feed/venue scope;
- epoch and bit widths if packed;
- same-timestamp tie breaking;
- maximum events per time unit and overflow behavior;
- clock rollback behavior;
- uniqueness and strict monotonicity;
- assignment order when one action emits fill, fee, and position events;
- snapshot serialization, restoration, and incompatibility behavior;
- replay behavior and deterministic regeneration;
- multi-venue state lookup.

Consumers must compare orderands only inside the same feed and must not decode
the representation.

### `REQ-DEC-010` — Delivery guarantee and atomicity boundary

Choose and document at-most-once, at-least-once, or another delivery model. The
design must address both partial-failure directions:

- state mutation succeeds but feed publication fails;
- publication succeeds but later processing/replay retries the mutation.

Define ordering relative to existing Uni-GW responses and legacy publications,
retry/outbox behavior, stable IDs on retries, shutdown draining, and what
recovery does with unpublished events. `EventId`-based storage deduplication
does not prevent a duplicate transfer command from mutating the balance twice.

### `REQ-DEC-011` — Time semantics

For every event define:

- `event_time`: simulated venue effective time;
- `send_time`: time sim-gw sends the feed event;
- `observe_time`: time the downstream system first observes it, if retained;
- the source used for each clock;
- whether all facts caused by one action share an `event_time`;
- precision, range, conversion, and invalid-time behavior.

For transfer commands, explicitly decide whether `client_time` becomes
`event_time`, is only provenance/input metadata, or is rejected when unsuitable.

### `REQ-DEC-012` — Deposit request cost-basis migration

Resolve the existing Uni-GW deposit fields `cost_basis` and
`cost_basis_asset_id` before implementing deposit behavior. Valid outcomes
include a versioned removal or an explicitly documented legacy-ignore policy;
this report does not select one. The simulation venue must not calculate,
update, persist, or emit cost basis.

### `REQ-DEC-013` — Fee semantics

Before implementing `DemoOnlyFee`, define:

- calculation/configuration source;
- fee asset or unambiguous inference rule;
- whether a positive value means charged or credited;
- rebate/negative-fee behavior;
- precision and rounding;
- when the fee affects account state;
- whether zero fees produce no event or a zero-valued event;
- relation to the optional fee on the existing Uni-GW `Trade`;
- order relative to the fill and position update.

### `REQ-DEC-014` — Transfer idempotency policy

The older milestone intentionally does not enforce gateway idempotency. Decide
whether ENG-1942 preserves that limitation. If duplicates can reach sim-gw, add
idempotency state keyed by the request key and define payload-conflict,
retention, snapshot/recovery, and cached-response behavior before allowing
balance mutation.

## Semantic event requirements

These are representation-neutral. The final traits may live only after
`REQ-DEC-003` is resolved.

### Common metadata (`REQ-DOM-001`)

Every event must expose:

- unique `telemetry::EventId` through `HasIdentity`;
- required `telemetry::TraceId` through `HasTracing`;
- opaque `SimGwOrderand` through `HasFeedOrderand`;
- `event_time`;
- `send_time` where required by the accepted contract.

Provenance must not be populated until `REQ-DEC-008`/the dedicated provenance
decision resolves its shape. If the field is carried on the wire for forward
compatibility, absence must be explicitly valid for this milestone.

### Fill (`REQ-DOM-002`)

A fill is emitted only for an execution that actually occurred. It contains:

- trading account ID;
- instrument/market ID;
- execution price in the market quote unit;
- strictly positive unsigned execution quantity;
- trade side;
- maker/taker liquidity role;
- common metadata.

It does not contain cost basis, PnL, volume, turnover, or aggregate position.
The source fill result must also drive the existing Uni-GW trade message so the
two outputs cannot disagree.

### Trading-account position update (`REQ-DOM-003`)

The first producer emits the venue's drop-copy account view after successful
state-changing economic events. It contains:

- trading account ID;
- `PositionSetCoverage`;
- `PositionAmountSemantics`;
- zero or more derivative positions keyed by `ContractId`, each with signed
  quantity;
- zero or more spot positions keyed by `AssetId`, each with signed quantity;
- common metadata.

It contains no cost basis. Under A-06, the first slice is a full, absolute
snapshot. The implementation must define whether flat/zero positions are
explicit or represented by absence, and produce a deterministic collection
order so equivalent state serializes predictably.

The current tracker exposes derivative `InstrumentId`, not the DEC-0ANEJ
`ContractId`; an explicit market-info-backed mapping or a contract correction is
required. The boundary must reject missing/incompatible market information
rather than substituting an ID from the wrong namespace.

### Deposit (`REQ-DOM-004`)

A deposit is emitted only after positive capital is successfully applied to a
paper account. It contains:

- trading account ID;
- asset ID;
- strictly positive quantity;
- common metadata.

It changes balance but does not create PnL or trading volume. It contains no
cost-basis or valuation fields. `DeclaredCostBasis` should not be implemented in
the venue contract merely to preserve an older sketch; if the final shared
semantic contract retains it, the only accepted milestone value is
`NotApplicable` and sim-gw performs no calculation with it.

### Withdrawal (`REQ-DOM-005`)

A withdrawal is emitted only after positive capital is successfully removed
from a paper account. It contains:

- trading account ID;
- asset ID;
- strictly positive quantity;
- common metadata.

The milestone policy rejects a withdrawal that would take the asset balance
below zero. A rejected withdrawal mutates no state and emits no withdrawal or
position event. It returns the correlated gateway rejection defined by the
command contract.

### Demo fee (`REQ-DOM-006`)

A fee event is emitted only when a fee actually occurs under the accepted demo
fee policy. It contains:

- trading account ID;
- instrument ID;
- fee amount under the decided sign/unit convention;
- common metadata.

The event is the raw charged/credited fact. It contains no derived PnL or cost
basis. Until `REQ-DEC-013` is resolved, implementing a hard-coded fee amount or
silently treating trade notional as a fee is prohibited.

### Closed-set and numeric validation (`REQ-DOM-007`)

- Reject zero or negative fill/deposit/withdraw quantities where the semantic
  contract says strictly positive.
- Preserve signed position quantities; do not convert them to unsigned values.
- Validate decimal range/scale at the wire boundary and preserve exact values.
- Reject unknown side, liquidity-role, coverage, amount-semantics, and event
  discriminants. Do not map them to a fabricated default.
- Reject missing required IDs/timestamps/oneof values before business state is
  mutated.
- Define fee sign validation only after fee semantics are accepted.

## Protobuf and wire-adapter requirements

### `REQ-WIRE-001` — Schema contents

After placement is decided, define the protobuf equivalent of the common
metadata and all five event families. The wire schema must preserve all
semantic distinctions above and must not add cost-basis fields.

Use the existing shared protobuf identifiers, decimal, timestamp, event ID, and
trace ID types when their semantics and range match. Introduce a dedicated
orderand message/value instead of reusing `common.Sequence`, whose name and
variant semantics do not express `SimGwOrderand`.

### `REQ-WIRE-002` — Presence and invalid states

Proto3 default values must not make an absent required field indistinguishable
from a valid domain value. Use message presence, `optional`, or another
specified mechanism and validate it. The event envelope must contain exactly
one supported event branch.

### `REQ-WIRE-003` — Dedicated conversion crate

Add a dedicated simulation-venue wire crate after ownership is decided. Its
dependency direction is:

```text
simulation-venue domain contract <- simulation-venue wire -> messaging
```

It must:

- expose borrowed `x_from_y`/`x_try_from_y` conversion functions;
- implement `FromWire`, `TryFromWire`, `FromDomain`, and `TryFromDomain` as
  appropriate;
- use local wrapper newtypes when generated messaging types are foreign;
- use `FieldViolationError` with stable field paths for invalid wire fields;
- keep conversions free of repository access and business policy;
- keep protobuf construction and serialization out of domain/application
  behavior.

### `REQ-WIRE-004` — Generation and exports

Update only the generation surfaces implied by the ownership decision:

- protobuf schema validation/build;
- Rust generated binding and module exposure, or service-wire build script plus
  `extern_path` configuration;
- TypeScript generation/exports if a TypeScript consumer needs the feed;
- Python generation/exports if a Python consumer needs the feed;
- serde/JSON binding generation where the owning package currently requires it;
- checked-in generated artifacts according to the owning repository rules.

Generated sources must never be hand-edited.

### `REQ-WIRE-005` — Conversion verification

Test each event for:

- valid domain-to-wire and wire-to-domain conversion;
- stable-field round trip;
- missing required metadata;
- invalid nested ID/timestamp/decimal;
- unknown enum and envelope discriminants;
- signed positions and positive raw quantities;
- no cost-basis field or calculation;
- stable `FieldViolationError.field` values;
- deterministic serialization where required for replay or fixtures.

## `sim-gw` application and runtime requirements

### `REQ-SIM-001` — Boundary refactor prerequisite

Do not add more feed behavior directly against generated protobuf objects in
`src/state/ready.rs`. Address or deliberately sequence against
`sim-gw` `ISSUE-0001`:

- NATS handler decodes and converts wire input at the boundary;
- application/domain logic accepts validated commands;
- application/domain logic returns typed outcomes/events;
- the NATS publisher adapter converts, serializes, chooses a subject, and
  produces the egress request;
- protocol-specific rejection mapping remains at the boundary.

### `REQ-SIM-002` — Event publisher port

Define a transport-neutral outbound publisher capability for an ordered batch
or sequence of simulation-venue events. The engine implementation may adapt it
to existing egress channels, but application behavior must not depend on NATS
subjects or protobuf types.

The port/outcome must make publication failure observable and must support the
delivery guarantee selected by `REQ-DEC-010`.

### `REQ-SIM-003` — Event context allocation

For one accepted source action, allocate event metadata exactly once and pass it
through the mutation/output path. It must provide:

- trace context;
- event time;
- one distinct event ID and orderand per emitted fact;
- send time at the defined publication boundary;
- feed/venue partition identity.

Do not call the clock independently in multiple builders when the events are
contractually meant to share an effective time.

### `REQ-SIM-004` — Fill integration

Refactor the successful create-order path into this logical sequence, adjusted
only by the accepted atomicity/delivery contract:

1. validate and construct one domain fill result;
2. validate account and market data;
3. apply the fill to account state;
4. apply the fee if the accepted policy produces one;
5. construct raw fill and optional fee events from the same result;
6. construct the resulting full/absolute position update;
7. allocate strictly ordered metadata;
8. publish the new feed event(s);
9. preserve required Uni-GW gateway/venue/order outputs.

Failures must not leave a gateway acceptance and raw fill publication for a
fill that was not applied. The exact commit/publish order depends on
`REQ-DEC-010`, but partial success must be detected and recoverable.

### `REQ-SIM-005` — Deposit handler

Replace the current unsupported branch only after the cost-basis and
idempotency decisions are resolved. The handler must:

- convert and validate the command at the boundary;
- verify the account exists and is paper;
- verify the allowed valuation asset policy;
- require quantity greater than zero;
- enforce the accepted idempotency policy;
- apply a positive balance delta with an order compatible with tracker state;
- emit a deposit event;
- emit the resulting full/absolute position update;
- return `DepositGatewayAccepted` on successful completion;
- return a correlated, typed/mapped rejection with no mutation or feed event on
  failure;
- perform no cost-basis work.

### `REQ-SIM-006` — Withdrawal handler

Replace the current unsupported branch only after idempotency is resolved. The
handler must:

- perform the same account/asset/quantity validation as deposit;
- load the current asset balance;
- reject absent/insufficient balance under the no-negative milestone policy;
- apply the negative balance delta exactly once;
- emit a withdrawal event;
- emit the resulting full/absolute position update;
- return `WithdrawalGatewayAccepted` on success;
- return a correlated rejection with no mutation/event on failure;
- perform no cost-basis work.

### `REQ-SIM-007` — Position projection

Build one semantic position snapshot from the post-mutation tracker state:

- use direct account, asset, and contract identifiers;
- sort positions deterministically;
- preserve signed quantities;
- distinguish spot balances from derivative positions;
- set `Full` and `Absolute` for the initial producer;
- define zero/flat inclusion consistently;
- reject missing market info needed for contract identity;
- include no cost basis.

The legacy `PositionServerAccountUpdate` may continue to be built from the same
snapshot during migration, but it is not the new feed message.

### `REQ-SIM-008` — Orderand and snapshot state

Extend `SimGwData` or another accepted inward-owned state component with the
per-feed/per-venue orderand state selected by `REQ-DEC-009`. If durable recovery
is required, replace `NullPersister`, include this state in the snapshot,
restore it before ingress is processed, and test snapshot version/error cases.

If the accepted milestone deliberately uses a stateless derivation, prove
uniqueness and strict order across same-time events and restarts; do not call it
stateless without that proof.

### `REQ-SIM-009` — Event ID/idempotency state

Add generator or deduplication state required by `REQ-DEC-007` and
`REQ-DEC-014`. Persist/recover it when deterministic replay cannot reconstruct
it. A replay of the same accepted source action must not create a second
economic mutation or unrelated event IDs.

### `REQ-SIM-010` — Configuration

Parse all new operator settings into typed configuration before component
creation. Possible settings, only when required by accepted decisions, include:

- feed subject and enablement;
- simulated-venue/feed mapping;
- fee policy/rate/asset and rounding;
- valuation asset allowlist;
- orderand epoch/layout version;
- persistence/retry/outbox limits.

Defaults, invalid values, reload behavior, and backward compatibility must be
specified. Do not hide business policy in arbitrary constants in
`ready.rs`.

### `REQ-SIM-011` — Egress lifecycle

Ensure feed publications are registered in the component/host egress type,
published through the existing egress manager or an accepted replacement,
flushed/drained on shutdown according to the delivery guarantee, and included
in engine/test harnesses. Generated multihost files must be regenerated, never
hand-edited.

## Feed catalog and downstream integration requirements

### `REQ-INT-001` — Data-feed definition

Author the canonical `DataFeedDefinition` required by
[DEC-0007](../../../knowledge-base/docs/decisions/records/DEC-0007-data-feed-definitions-source-of-truth.md):

- provider (`InternalDataFeedProvider::Simulator` unless revised);
- stable subject representing the chosen feed partition;
- event definitions for fill, fee, deposit, withdrawal, and position update;
- event-driven cadence;
- protobuf message/schema references;
- supported encoding;
- deterministic feed ID and revision ID;
- catalog-assigned revision sequence.

The current `Other` subject/event mechanisms are technically available but
using stringly typed placeholders is an ownership/design decision, not an
automatic implementation choice.

### `REQ-INT-002` — Catalog publication/discovery

Define where the feed definition is authored, how it enters feed-info, how
runtime publishers/consumers resolve its current revision, and how incompatible
schema revisions are rolled out. A hard-coded NATS subject alone is not a
complete data-feed identity.

### `REQ-INT-003` — Raw-event ingestion

The downstream gateway must:

- subscribe to the selected subject(s);
- resolve/validate feed ID, revision, and encoding;
- persist exact raw bytes before or independently of semantic folding, according
  to the storage contract;
- use event ID for idempotent storage;
- preserve the opaque source orderand;
- stamp ingestion/observe time without overwriting producer event/send time;
- reject/quarantine unknown revisions and malformed events with diagnostics;
- tolerate the selected duplicate and late-event model.

### `REQ-INT-004` — Semantic projections

Update downstream projections so every emitted event can be queried:

- fills;
- demo fees;
- deposits;
- withdrawals (currently missing from DEC-0ADYZ's proposed tables);
- position updates without cost basis.

Quantities/prices/fees must preserve mantissa/scale and signedness. Consumer
folds, not sim-gw, compute cost basis, PnL, volume, turnover, valuation, and
aggregates.

### `REQ-INT-005` — Reconciliation

Define how the consumer uses position updates as drop-copy observations against
raw fills/transfers/fees. Provenance is deferred, so the demo's reduced
reconciliation guarantee must be explicit; consumers must not infer causal
boundaries that the payload does not carry.

## Failure and observability requirements

### `REQ-OPS-001` — Failure classes

Define and test distinct outcomes for:

- malformed wire event/command;
- unsupported/unknown closed-set variant;
- non-paper or missing account;
- unsupported asset;
- non-positive quantity;
- insufficient withdrawal balance;
- duplicate/conflicting idempotency key;
- missing market/contract mapping;
- event ID/orderand exhaustion or clock error;
- state snapshot/restore error;
- conversion/encoding error;
- egress queue/send/flush failure;
- downstream unknown schema revision.

Domain violations, application orchestration failures, infrastructure failures,
and protocol rejections require layered error types and explicit mapping. Do not
log and return the same error at multiple layers.

### `REQ-OPS-002` — Structured diagnostics

Emit structured logs/metrics containing safe identifiers and, when available:

- event family;
- event ID and trace ID;
- feed ID/revision and opaque orderand display;
- account and venue/feed partition;
- command correlation/idempotency outcome;
- publication attempt/result;
- rejection/failure class;
- queue depth/retry count and last successful orderand.

Never log raw protobuf payloads indiscriminately; transfer/account messages can
contain sensitive operational data.

### `REQ-OPS-003` — Metrics and alerts

At minimum expose counters for produced events by family, validation
rejections, duplicate commands, encoding failures, publish failures/retries,
downstream decode/revision failures, and orderand/recovery failures. Add lag or
last-published-orderand visibility if operations rely on the feed for the demo.

## Verification requirements

### Contract and domain tests (`REQ-TEST-001`)

- common metadata traits are implemented for every event;
- event IDs and orderands are distinct and strictly ordered as specified;
- trace propagation/fallback behavior;
- exact event/send time semantics;
- positive fill/deposit/withdraw quantities;
- signed position quantities;
- full/absolute snapshot and zero/absence semantics;
- no cost-basis field or calculation in any simulation-venue event;
- fee sign/unit/rounding once decided;
- all closed-set variants and invalid states.

### Wire tests (`REQ-TEST-002`)

- protobuf compile/lint and generated bindings;
- all conversion tests from `REQ-WIRE-005`;
- golden or compatibility fixtures for the event envelope;
- unknown/new field tolerance where protobuf compatibility permits it;
- old reader/new writer and new reader/old writer behavior for supported rollout
  combinations;
- schema/package generated in exactly one Rust owner.

### `sim-gw` behavior tests (`REQ-TEST-003`)

Drive the in-process engine through ingress and inspect published egress:

- supported spot and derivative fills emit the correct feed fill;
- one fill result keeps Uni-GW trade and feed fill in semantic parity;
- state is updated before the resulting position snapshot is built;
- full/absolute spot and derivative snapshots have deterministic ordering;
- deposit acceptance mutates once and emits deposit then position events;
- withdrawal acceptance mutates once and emits withdrawal then position events;
- invalid/insufficient transfers reject with no state/feed mutation;
- duplicate transfer behavior matches the accepted idempotency contract;
- fee/no-fee paths match the accepted policy;
- event IDs/traces/orderands/times are correct across multi-event actions;
- publication failure and retry produce the selected delivery behavior;
- existing Uni-GW and legacy position outputs remain compatible under A-05.

Tests must assert exact egress topics and the meaningful ordering of messages,
not only their presence.

### Recovery and multi-venue tests (`REQ-TEST-004`)

- independent orderand streams for at least two feed/venue partitions;
- same-timestamp event bursts and sequence overflow boundary;
- restart/snapshot recovery and first post-restart event;
- clock rollback behavior;
- replay of already processed ingress;
- snapshot version mismatch/corruption;
- event ID and idempotency state recovery.

If the milestone explicitly excludes durable recovery, replace these with a
proof/test of the accepted weaker guarantees and document the resulting data
loss/collision window.

### End-to-end integration (`REQ-TEST-005`)

Using real NATS and the downstream ingester/storage profile:

1. publish an order that produces a fill and optional fee;
2. apply a deposit and withdrawal;
3. observe raw feed bytes persisted with feed identity/revision;
4. observe semantic fill/fee/deposit/withdrawal/position rows;
5. prove duplicate event publication is idempotent;
6. prove malformed/unknown revisions are rejected or quarantined;
7. verify the consumer derives accounting results without cost-basis input from
   sim-gw.

### Repository checks (`REQ-TEST-006`)

Run the focused tests for every changed repository, then each repository's
standard check, and finally the workspace check when dependencies are aligned.
At minimum this is expected to include messaging schema generation/checks,
wire-crate tests, `sim-gw` e2e tests, formatting/lint/type checks, and downstream
integration tests. The implementation plan must record the exact commands after
file/crate ownership is decided.

## Required documentation and recordkeeping

1. Link ENG-1942 from DEC-0ANEJ and move the decision to the accepted lifecycle
   state only after its conflicts are resolved.
2. Create/update the living simulation-venue feed spec and any affected living
   references.
3. Update or supersede the older transfer and position specifications where
   they require venue cost basis.
4. Record the selected topology, orderand, delivery/idempotency, fee, and
   ownership decisions; do not bury them in code comments.
5. Create a spec-derived execution plan with requirement-to-task traceability
   before implementation.
6. Add/update `sim-gw` design docs for the feed flow, contract boundary, state,
   and recovery model.
7. Update `sim-gw` roadmap, issue/plan indexes, relevant issue records, and work
   log as implementation progresses.
8. Document schema evolution, subject configuration, rollout/rollback, and
   operational diagnostics.

## Explicit placement TODOs

No item in this section is assumed implemented.

- **`TODO-PLACE-001` — Semantic traits:** choose the shared domain/application
  crate for event-specific traits and supporting types. Generic metadata traits
  already live in `entity-core`.
- **`TODO-PLACE-002` — Protobuf:** design files under
  `messaging/msg-schemas/proto/sim-venue/`; decide package/version and schema
  split.
- **`TODO-PLACE-003` — Rust generated bindings:** choose `messaging` or one
  dedicated service-specific wire crate; never both.
- **`TODO-PLACE-004` — Conversions:** choose/create the dedicated
  simulation-venue `*-wire` crate.
- **`TODO-PLACE-005` — Domain events and publisher port in `sim-gw`:** choose
  layer-compliant modules after the sim-gw design document is written; do not
  extend the protobuf-coupled `ready.rs` shape by default.
- **`TODO-PLACE-006` — NATS subjects/topic enum:** choose the shared owner and
  routing shape after feed topology is settled.
- **`TODO-PLACE-007` — Feed definition:** choose the canonical authoring and
  feed-info registration location.
- **`TODO-PLACE-008` — Orderand/event ID/idempotency state:** choose state owner,
  snapshot schema, and recovery path.
- **`TODO-PLACE-009` — Downstream decoder/projections:** identify the service
  that captures raw messages and owns the semantic tables in DEC-0ADYZ.

## Suggested dependency-valid work slices

These are sequencing boundaries for a future execution plan, not authority to
implement them now.

1. **Contract closure:** resolve all `REQ-DEC-*` items; accept/update the
   decision and publish the spec.
2. **Shared semantic contract:** implement event traits/types and invariants in
   the selected owner.
3. **Wire contract:** add protobuf, generated binding ownership, wire adapter,
   and conversion tests.
4. **Simulation architecture seam:** address protobuf/domain boundary debt and
   add the event publisher capability.
5. **Identity/order/recovery:** implement metadata allocation and persistence or
   the explicitly accepted demo alternative.
6. **Fill + position slice:** publish correct raw fills and post-fill
   full/absolute snapshots while preserving existing outputs.
7. **Transfer slice:** reconcile/remove legacy cost-basis input, implement
   deposit/withdrawal state transitions, idempotency, replies, and events.
8. **Fee slice:** implement only after fee semantics/configuration are accepted.
9. **Catalog + downstream slice:** register the feed, ingest raw bytes, add all
   semantic projections including withdrawals, and integrate reconciliation.
10. **Operational proof:** recovery, failure injection, compatibility, real-NATS
    end-to-end profile, rollout, and rollback.

## Definition of ready for implementation

ENG-1942 is ready to decompose into implementation tasks only when all of the
following are true:

- DEC-0ANEJ is accepted or replaced and linked to ENG-1942.
- A living simulation-venue feed spec exists with stable requirement IDs.
- Every item in `Source authority and conflicts` has an explicit resolution.
- Trait, protobuf binding, conversion, topic, feed-definition, and state
  ownership are decided.
- The wire schema contains no venue-calculated cost basis.
- Feed topology and orderand scope are unambiguous for transfers as well as
  instrument events.
- Identity, trace, time, delivery, idempotency, replay, and recovery semantics
  are testable.
- Fee unit/sign/calculation and zero-fee behavior are testable, or the fee slice
  is explicitly deferred without fabricating fee events.
- Deposit and withdrawal request migration behavior is explicit.
- The downstream owner and withdrawal storage gap are identified.
- A spec-derived execution plan maps every requirement to exact targets,
  dependencies, acceptance criteria, and verification.

## Out of scope for the simulation venue

- calculating or publishing cost basis;
- PnL, portfolio value, volume, turnover, or performance aggregates;
- accounting-method selection or double-entry journals;
- order-lifecycle and market-data feeds beyond the existing gateway behavior;
- venue-native account management;
- consumer normalization or cross-feed ordering;
- invented provenance;
- production fee taxonomy beyond the explicitly demo-scoped fee contract.

## Source trail

- [DEC-0ANEJ: Simulation Venue Feed](../../../knowledge-base/docs/decisions/records/DEC-0ANEJ-simulation-venue-feed.md)
- [DEC-0ADYZ: Strategy Deployment Feed Storage Demo](../../../knowledge-base/docs/decisions/records/DEC-0ADYZ-strategy-deployment-feed-storage-demo.md)
- [DEC-09S6G: Strategy Performance Feed](../../../knowledge-base/docs/decisions/records/DEC-09S6G-strategy-performance-feed.md)
- [DEC-07RD2: Feed Orderand](../../../knowledge-base/docs/decisions/records/DEC-07RD2-feed-orderand.md)
- [DEC-07RE5: Simulation Venue Orderand](../../../knowledge-base/docs/decisions/records/DEC-07RE5-simulation-venue-orderand.md)
- [DEC-07XKF: Paper Trading Account Deposit/Withdrawal](../../../knowledge-base/docs/decisions/records/DEC-07XKF-paper-trading-account-deposit-withdrawal.md)
- [SPEC: Trading Account Deposit/Withdrawal Application Server](../../../knowledge-base/docs/specs/SPEC-trading-account-deposit-withdrawal-application-server.md)
- [DEC-08WN1: Sim GW NATS Request/Reply Egress](../../../knowledge-base/docs/decisions/records/DEC-08WN1-sim-gw-nats-request-reply-egress.md)
- [DEC-08VKD: Trading Account Position Update Feed](../../../knowledge-base/docs/decisions/records/DEC-08VKD-trading-account-position-update-feed.md)
- [SPEC: Trading Account Position Update Feed](../../../knowledge-base/docs/specs/SPEC-trading-account-position-update-feed.md)
- [DEC-0A5FN: Backtest Feed Emits Raw Economic Events](../../../knowledge-base/docs/decisions/records/DEC-0A5FN-backtest-feed-emits-raw-economic-events.md)
- [`sim-gw` architecture](../../../sim-gw/ARCHITECTURE.md)
- [`sim-gw` runtime handler](../../../sim-gw/src/state/ready.rs)
- [`sim-gw` protobuf-boundary issue](../../../sim-gw/docs/issues/records/ISSUE-0001-protobuf-boundary-domain-mapping.md)
- [Existing Uni-GW requests](../../../messaging/msg-schemas/proto/gw/uni-gw/requests.proto)
- [Existing Uni-GW status updates](../../../messaging/msg-schemas/proto/gw/uni-gw/status_updates.proto)
- [Legacy account events](../../../messaging/msg-schemas/proto/structure/account_events.proto)
- [Shared data-feed metadata traits](../../../entity-core/crates/entity-core/src/entities/data_feed/traits.rs)
