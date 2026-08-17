# Founder-led demo backend gap analysis

Date: 2026-08-17  
Scope: trading and Application Server backend only; client behavior and presentation are excluded.

## Executive conclusion

The current backend cannot run the founder-led demo end to end, and adding CME data from Databento is not a small venue-enum extension.

The backend already has useful foundations: immutable validated strategy revisions, historical-backtest orchestration, aggregate result artifacts, paper-account records, strategy start/stop, operational logs, and a standalone Databento decoder/replay prototype. Those pieces do not yet form the proof chain promised by the walkthrough: idea → editable strategy → immutable revisions → reproducible backtest → losing trade → causal tick replay → controlled correction → comparable retest → evidence-bound paper deployment.

There are five P0 blockers:

1. **The CME scenario is not defined.** The canonical walkthrough still specifies Hyperliquid, BTC perpetual, and a BTC momentum fixture. “CME venue” does not name a CME Group exchange, product, dated contract, session, schema, interval, or expected losing trade.
2. **CME futures are not representable.** The venue, instrument, wire, market-info, quote-unit, simulator, and execution models support crypto spot/perpetual concepts, not dated futures and their contract economics.
3. **Databento is not connected to production consumers.** The repository contains a standalone prototype and a proposed decision, but no deployed ingestion service, durable definition mapping, NATS publication, historical warehouse bridge, or runtime/backtest consumer.
4. **The demo evidence model is missing.** Current results do not expose typed trades/fills, complete run provenance, or the target → transition → evaluation tick correlation needed by Tick Navigator and a controlled retest.
5. **Paper promotion is neither modeled nor paper-safe.** There is no promotion/deployment aggregate binding a reviewed revision to its supporting backtest and exact settings. The existing start flow gathers every confirmed account attached to the strategy and does not enforce a paper-only destination.

The shortest credible demo path is deterministic **historical Databento replay** through the existing normalized market-data and Arrow/backtest path, with real minimal futures contract economics, a precomputed causal trace artifact, and an explicitly simulated paper deployment. It must be labeled as historical replay and simulation. It must not be presented as live CME market data or live exchange execution.

Live Databento support is a separate production milestone: the proposed architecture requires identity bootstrapping, ordering, reconnect/checkpoint behavior, gap recovery, bounded backpressure, observability, and production consumers before it proves a live path.

## Sources and authority

This analysis uses the walkthrough as the demo contract and distinguishes living references from proposed decisions, raw notes, and open issues:

- [Founder-led demo walkthrough](../../../knowledge-base/docs/references/founder-led-demo.md) — canonical journey, scenario, evidence requirements, and honest feature classification.
- [Platform topology](../../../knowledge-base/docs/references/platform-topology.md) — service and boundary terminology.
- [Market info reference](../../../knowledge-base/docs/references/market-info.md) — current market-info scope and unresolved futures/index-point semantics.
- [DEC-08T3R: Databento integration architecture](../../../knowledge-base/docs/decisions/records/DEC-08T3R-databento-integration-architecture.md) — **proposed**, not implemented; deliberately leaves domain venues, consumers, and historical replay/backfill undecided.
- [ISS-099M9: demo replays historical Databento as live](../../../knowledge-base/docs/issues/records/ISS-099M9-demo-replays-historical-databento-data-as-live.md) — historical replay does not prove live identity, ordering, reconnect, or gap recovery.
- [ISS-099MC: Tick Navigator trace is precomputed](../../../knowledge-base/docs/issues/records/ISS-099MC-tick-navigator-trace-is-precomputed.md) — current trace limitation.
- [ISS-09K80: backtest results omit execution-cost evidence](../../../knowledge-base/docs/issues/records/ISS-09K80-backtest-results-omit-execution-cost-evidence.md) — missing volume, fees, and slippage evidence.
- [ISS-09FBY: variables are bound at revision creation](../../../knowledge-base/docs/issues/records/ISS-09FBY-strategy-variables-are-bound-at-revision-creation.md) — revision/deployment configuration mismatch.
- [ISS-08ZTF: accounts are attached to strategies](../../../knowledge-base/docs/issues/records/ISS-08ZTF-trading-accounts-are-attached-to-strategies-instead-of-deployments.md) — deployment ownership mismatch.
- [DEC-09S6G: strategy performance feed](../../../knowledge-base/docs/decisions/records/DEC-09S6G-strategy-performance-feed.md) — proposed feed contract that explicitly diverges from current living specifications.

Official Databento constraints used here:

- [`GLBX.MDP3` covers CME, CBOT, NYMEX, and COMEX futures/options](https://databento.com/docs/knowledge-base/datasets).
- [Databento symbology and identity conventions](https://databento.com/docs/standards-and-conventions/symbology).
- [Parent symbols such as `ES.FUT` resolve to dated instruments](https://databento.com/docs/examples/symbology/parent-symbology).
- [Live subscription/symbology behavior](https://databento.com/docs/api-reference-live/basics/symbology).

## Decisions required before implementation

These are product/domain decisions, not implementation details that code should guess.

### 1. What does “CME venue” mean?

`GLBX.MDP3` covers four CME Group designated contract markets. A single `CME` discriminant would collapse exchange/publisher identity for instruments listed on CME, CBOT, NYMEX, and COMEX.

Choose one of:

- exchange-level canonical venues (`CME`, `CBOT`, `NYMEX`, `COMEX`), preserving Databento publisher mapping;
- a deliberately documented group/execution-venue abstraction, with the listing exchange retained separately;
- a first-demo product actually listed on CME, with other exchanges explicitly out of scope.

The first option is the least ambiguous long-term model. For the fastest demo, select one product and its true listing exchange, then append only the required stable venue discriminant without claiming all of `GLBX.MDP3` is “CME.”

### 2. What exact contract and fixture are canonical?

Freeze all of the following:

- product and size, for example ES versus MES;
- dated contract/delivery month, plus the rule used to resolve a parent/continuous symbol;
- Databento dataset, publisher, schema, and symbol type;
- UTC interval, exchange session/time zone, and relevant market-status transitions;
- strategy parameters, starting balance, fees, slippage, latency, fill model, and valuation currency;
- the expected losing trade, evaluation tick, causal branch, correction, and improved retest outcome.

The current prototype’s “latest lookback” cannot guarantee this scripted path.

### 3. Is the demo claim historical or live?

Recommendation: make the first CME demo deterministic historical replay. The walkthrough should say so explicitly.

Live Databento should only be claimed after the live service and its operational guarantees exist. A rehearsed historical stream may look live in time, but it does not validate reconnect, definition churn, ordering gaps, or recovery.

### 4. Which performance-feed contract is authoritative?

The proposed strategy-performance decision introduces source events, targets, orders, fills, positions, PnL, portfolio, volume, and provenance, while noting conflicts with existing living specs. Reconcile that authority conflict before implementing a durable public contract. Do not create a demo-only incompatible event schema that later has to be migrated.

## What the backend can do today

| Capability | Current state | Important limitation |
|---|---|---|
| Create and manage strategies | Implemented | Accounts are owned/attached at strategy scope, not deployment scope. |
| Create immutable revisions | Implemented with gaps | Full spec and already-bound arguments are validated and stored; no parent/base revision, accepted proposal, diff, validation artifact, or working-copy hash. |
| Store canvas working-copy bytes | Partial | Opaque GUI bytes are separate from the executable strategy spec; the server cannot prove they are synchronized. |
| Start an explicit revision | Partial | No deployment configuration or supporting evidence; all confirmed attached accounts are selected. |
| Create/list/get backtests | Implemented with gaps | Run context omits fees, feed/data version, simulator version, rich balances, and completeness attestation. |
| Produce aggregate backtest artifacts | Partial | Results, portfolio, positions, statistics, and market data exist; typed trades/fills and causal traces do not. |
| Download backtest results | Partial | Public API returns an opaque SQLite artifact and omits retrievable run arguments/provenance in its representation. |
| Create a paper account | Partial | It is immediately confirmed, has no CME-specific setup, and is not a deployment destination aggregate. |
| Internal deployment status updates | Partial | There is no public create/review/promote deployment lifecycle and the stored deployment entity lacks the required associations. |
| Operational logs | Implemented | Newest-first operational logs are not immutable, ordered per-backtest evaluation traces. |
| Databento domain vendor | Implemented | Correctly modeled as a data vendor, separate from venue. |
| Decode/replay Databento data | Prototype only | Standalone, process-local, no production publication, persistence, recovery, consumers, or automated proof. |

Key Application Server surfaces are in [routes.ts](../../../structure-web/packages/api/src/app/routes.ts). Strategy revision creation parses and binds full arguments in [strategies-service.ts](../../../structure-web/packages/api/src/strategies/strategies-service.ts); backtest creation and fixed historical-data job configuration live in [backtests-service.ts](../../../structure-web/packages/api/src/backtests/backtests-service.ts); deployment callbacks are internal-only in [strategy-deployments-service.ts](../../../structure-web/packages/api/src/strategy-deployments/strategy-deployments-service.ts).

## Missing backend capabilities

### A. Canonical CME futures domain

#### A1. Venue taxonomy and stable codecs

The TypeScript venue set is `None`, `Drift`, and `Hyperliquid` in [venue.ts](../../../market-info-core/ts/src/entities/venue/venue.ts). The Rust set has additional crypto venues but no CME-family venue in [venue.rs](../../../market-info-core/rust/src/entities/venue.rs). Their numeric identities already disagree despite TypeScript documentation saying they must remain synchronized. The protobuf and wire conversions also omit CME.

Required work:

- decide the canonical venue taxonomy;
- append stable discriminants in Rust, TypeScript, protobuf, wire conversions, database/API serialization, and tests;
- migrate or explicitly reconcile the existing Rust/TypeScript numeric mismatch;
- retain Databento as `MarketDataVendor::Databento`, not as the execution/listing venue;
- preserve dataset and publisher provenance alongside canonical venue identity.

This is an append-only compatibility change. Reusing or renumbering existing values risks corrupting stored and wire identities.

#### A2. Dated-future identity and contract terms

Instrument types support only spot/perpetual in [instrument.ts](../../../market-info-core/ts/src/entities/instrument/instrument.ts) and [instrument.rs](../../../market-info-core/rust/src/entities/instrument.rs). `InstrumentId` is derived only from symbol, type, and venue. `ContractId` is opaque. Quote units only represent an asset. That cannot express a dated exchange-traded future or index-point pricing.

Required minimum model:

- `Future` instrument kind;
- durable product and dated-contract identity;
- expiry/delivery month and listing lifecycle;
- parent/continuous-to-dated-contract relationship;
- contract multiplier and settlement quantity;
- minimum price increment and quantity increment;
- quote/settlement/valuation units and currency;
- trading session/calendar and market status;
- definition version/effective interval and Databento mapping provenance.

Without these terms, position sizing, tick rounding, notional, PnL, fees, and contract selection are wrong even if market prices decode correctly.

#### A3. Market-info service and API

Static market info currently covers Drift/Hyperliquid implementations. The Application Server instrument response exposes only ID, symbol, type, and venue and rejects non-spot/perpetual wire values.

Required work:

- persist/query point-in-time Databento definitions and symbol mappings;
- expose the rich contract terms used by runtime, simulator, accounting, and run review;
- add CME/futures codecs to the Application Server repository and HTTP contracts;
- define behavior for definition add/modify/delete and contract expiry;
- add a CME-capable history source or explicitly exclude the existing crypto-only Pyth price-history endpoint from the demo.

### B. Databento ingestion, identity, and historical replay

#### B1. Production ingestion boundary

The code in [prototypes/databento-md](../../../prototypes/databento-md) proves decoding, MBP-1/status replay, and transient point-in-time definitions. It writes owned DBN records to a process-local channel/stdout path. Its documented limitations include one dataset/process, no persistence or cache, no continuous definition processing, no symbol-resolution service, no reconnect/checkpoint/deduplication/gap repair, no throughput guarantee, and no automated tests/benchmarks.

Required work:

- implement the proposed `dbn-md-server` or another accepted production adapter;
- configure dataset, schemas, symbols, start/stop, and definition bootstrap explicitly;
- add secrets/entitlement and cost controls;
- publish canonical identity, order, event type, provenance, and provider-native payload where required;
- define bounded backpressure and failure behavior;
- add reconnect, checkpoint, deduplication, gap detection/repair, health, metrics, and deployment configuration;
- build deterministic fixture and integration tests.

#### B2. Canonical identity mapping

Databento instrument IDs and symbols cannot be used naked as Structure canonical IDs. Definition and mapping records must connect:

`dataset + publisher + Databento instrument ID + definition version/leg`

to:

`canonical venue + product + dated contract + canonical instrument/contract IDs`.

The mapping must be time-aware and stored with every replay/run provenance record. Parent or continuous symbols must be resolved to the actual dated contract used by the fixture.

#### B3. Bridge into existing runtime and warehouse

The proposed architecture uses provider-native DBN envelopes, while current strategy topics, the market-data persister, Arrow warehouse, historical reader, and DSL nodes expect normalized protobuf topics such as Book L1 and crypto-specific trade variants.

Choose one bridge:

1. normalize DBN MBP-1/trade/status into the existing protobuf topics and Arrow warehouse; or
2. teach the persister, warehouse, historical runtime, live runtime, and nodes to consume the provider-native DBN envelope.

For the demo, option 1 is the smaller path and reuses current backtest machinery. It still must preserve the original DBN identity, sequence/order, receive/event timestamps, publisher, schema, definition cut, and completeness information. Market-status/session events must not be discarded.

### C. Futures-correct trading and simulation

#### C1. Historical/backtest execution

The current execution simulator resolves Drift/Hyperliquid only, treats any non-spot instrument as a perpetual, uses synthetic USD settlement, and computes PnL from price delta × quantity without a contract multiplier. Positions omit futures multiplier economics, and market-data handling ignores session/status behavior.

Required work:

- resolve the new CME contract through rich market info;
- apply multiplier-aware notional, realized/unrealized PnL, valuation, and balance changes;
- round prices and quantities to contract increments;
- model documented fees, slippage, latency, and fill assumptions;
- handle session/status boundaries and expiry behavior needed by the fixture;
- bind the exact data interval and definition version to the run;
- add golden calculations for fills, fees, positions, and PnL.

Margin and clearing can remain explicitly simplified for a first simulated demo, but the simplification must be represented in the simulator/run assumptions. Multiplier, tick size, fees, and contract identity cannot be omitted without making the before/after result misleading.

#### C2. Paper simulation and durable trade state

Paper execution is currently Hyperliquid-specific. `sim-gw` immediately fills at requested price, does not consume market data, emits no notional or fee, and applies perpetual-style quantity deltas without futures cost basis/PnL/multiplier. Its trade updates do not form a demonstrated durable path into account/position history.

Required work:

- make paper venue/trade specifications generic enough for the selected CME contract;
- feed the simulator contract terms and either market-derived prices or a clearly documented deterministic fill model;
- emit non-null notional, fees, fill price, cost basis, and provenance;
- route fills/trades durably into position/account history;
- expose targets, fills, positions, portfolio, metrics, and logs for the deployment;
- prove idempotency and replay behavior around order/fill events.

### D. Reproducible backtests and performance evidence

#### D1. Complete run context

The `Backtest.Args` model currently stores start/stop, execution delay, one starting balance, and slippage. It omits:

- feed vendor/dataset/publisher/schema/symbol and data-version/definition cut;
- data completeness/gaps and fixture checksum;
- fee schedule and fee-model version;
- simulator/runtime/compiler/DSL-node revisions;
- execution/fill assumptions and relevant latency settings;
- per-account/per-asset starting balances and valuation currency;
- effective strategy-variable values separate from immutable declarations;
- session/time-zone/calendar and contract-resolution rule.

Persist an immutable `RunContext` and expose it through the public API. The result must refer to the same context, not merely keep internal artifact paths. Existing open issues about unpinned runtime and DSL-node revisions must be resolved for reproducibility.

#### D2. Typed performance and trade APIs

Today, clients can download an opaque SQLite result blob. The demo backend needs queryable, versioned contracts for:

- portfolio/equity and PnL series;
- statistics with calculation/version metadata;
- target positions, orders, fills, and reconstructed trades;
- positions and balances;
- traded volume, fees, slippage cost, and other execution costs;
- logs/runtime events;
- completeness and terminal status.

Every item needs stable identity, timestamp/order, source, backtest ID, revision ID, and run-context ID. The backend must be able to answer “which losing trade?” without reverse engineering an aggregate file on the client.

#### D3. Causal trace for Tick Navigator

There is no production trace entity, artifact, repository, or route. Node mappings used for compilation are insufficient.

Persist an ordered per-backtest evaluation trace containing at least:

- evaluation tick ID and source-event order/provenance;
- stable node IDs and revision/graph mapping;
- evaluated/not-evaluated node set;
- input values and predicate outcomes;
- state/memory before and after;
- produced target/transition and linked order/fill/trade IDs;
- synchronized strategy-log references;
- trace schema/version and completeness.

The core lookup must be bidirectional:

`trade/fill → target → state transition → evaluation tick/source event`

and

`evaluation tick → evaluated nodes → target/order/fill/trade`.

A precomputed fixture artifact is acceptable for the demo only if the walkthrough retains its “precomputed/simulated” classification. It must still use stable IDs and the same public contract intended for a runtime-produced trace.

#### D4. Controlled retest attestation

Creating two unrelated backtests is not enough to prove that only the intended strategy change explains the result.

Add a clone/retest operation that:

- selects the new immutable revision;
- copies the original run context and effective variables;
- rejects or explicitly records every changed setting;
- persists the base backtest and comparison relationship;
- reports an equality/difference attestation;
- links the original losing trade/tick to the corresponding causal outcome in the retest where possible.

### E. Application Server authoring, revision, and deployment contracts

#### E1. Strategy authoring/proposal aggregate

No public AI/conversation route or strategy-aware WebSocket contract exists. The canvas working copy is opaque bytes, while revision creation accepts a complete spec and already-bound arguments. The backend cannot record or verify an AI proposal, a manual edit, or the transition from working copy to immutable revision.

Needed for the walkthrough’s backend contract:

- authenticated conversation/session ownership;
- mutable strategy-spec working copy with optimistic concurrency;
- server-side validation/diagnostic endpoint;
- proposal with base revision/working-copy hash, changed and unchanged entity sets, and canvas/spec diff;
- accept/reject record and idempotency;
- immutable revision lineage, accepted proposal ID, change summary, and validation artifact;
- atomic association of saved executable spec and canvas layout.

AI model execution itself may remain a separate service, but the Application Server must own the durable, authorized product contract.

#### E2. Separate variable declarations from effective deployment values

Strategy revision arguments are currently bound during revision creation. The desired lifecycle needs immutable variable declarations at revision scope and explicit effective values at backtest/deployment scope. Otherwise the system cannot truthfully claim that a retest or paper deployment used an exact variable snapshot without creating another revision.

#### E3. Deployment/promotion aggregate and paper-only safety

The current deployment entity is infrastructure status, not a logical deployment. The public route set has no create/list/get/promote lifecycle. Account attachment and strategy start are separate operations.

Add an authenticated, idempotent promotion operation that binds:

- strategy and exact immutable revision;
- supporting backtest/comparison evidence;
- exact effective variables;
- explicit account/destination set;
- `paper` execution mode and simulator version/settings;
- contract/feed configuration;
- requested-by/approved-at audit metadata;
- workflow/deployment correlation and lifecycle state.

It must reject every non-paper destination. The existing generic `start` behavior must not be used to imply paper safety because it gathers all confirmed strategy-attached accounts. Moving account ownership to deployment scope is the safer domain design.

#### E4. Orchestration reliability

Backtest workflow failure handling contains an explicit TODO that can leave status stale. Strategy start and backtest creation call a remote workflow service while a local database transaction is open, so a remote workflow may survive a later local commit failure.

Required work:

- terminal failure/status handling for every workflow path;
- idempotent commands and callbacks;
- an outbox or equivalent recoverable orchestration boundary;
- correlation IDs linking strategy, revision, backtest/deployment, workflow, service, artifacts, and logs;
- end-to-end authorization checks for new authoring, trace, comparison, and promotion resources.

## Backend journey coverage

| Walkthrough beat | Backend status | Missing for a credible demo |
|---|---|---|
| Interpret idea and scaffold strategy | Missing | Durable conversation/proposal contract and AI orchestration. |
| Show editable canvas/working copy | Partial | Executable-spec working copy, concurrency, and spec/canvas synchronization. |
| Manual edit | Partial | Server-observable edit/validation state. |
| Save immutable `v1` | Partial | Lineage, accepted change, validation artifact, canvas association, variable declaration split. |
| Run historical backtest | Partial | CME data bridge, futures economics, complete run context, coverage validation. |
| Review performance | Partial | Typed performance/trade/cost/completeness APIs. |
| Select losing trade | Missing | Stable trade/fill identity and query/correlation API. |
| Tick Navigator replay | Missing/precomputed only | Ordered causal trace artifact and APIs. |
| Ask AI for correction | Missing | Base-revision proposal/diff/accept contract. |
| Save linked `v2` | Partial | Explicit parent/base and accepted-diff lineage. |
| Controlled retest | Partial | Clone-run context, equality/difference attestation, comparison relation. |
| Compare before/after | Missing as a composed contract | Comparable typed results plus trace at the original failure. |
| Promote to paper | Partial and unsafe if composed today | Evidence-bound deployment aggregate and paper-only account enforcement. |
| Observe paper strategy | Partial | CME simulator economics and durable target/fill/position/performance/log feed. |

## Recommended delivery sequence

### P0 — Freeze the claim and make one deterministic CME backtest truthful

1. Update the canonical scenario: exchange, product, dated contract, dataset/publisher/schema, interval, session, assumptions, expected losing trade, correction, and result.
2. Decide venue taxonomy and reconcile stable Rust/TypeScript/protobuf discriminants.
3. Add the minimum real futures contract/market-info model and point-in-time Databento mapping.
4. Convert a pinned Databento historical fixture into normalized market-data/status events and the existing Arrow path, preserving provenance and completeness.
5. Make backtest fills, fees, positions, and PnL futures-correct for the selected contract.
6. Extend immutable run context and expose typed statistics/trades/fills/costs.
7. Produce a golden fixture test that deterministically reproduces the intended losing trade.

### P1 — Complete the demo proof chain

1. Persist the causal evaluation trace and expose trade/tick lookup APIs.
2. Add revision lineage and proposal/diff/accept records sufficient for the scripted correction.
3. Add controlled-retest cloning and setting-equality attestation.
4. Add a paper-only promotion aggregate bound to the reviewed revision and backtest evidence.
5. Make the simulator generic for the selected CME contract and persist credible fills/positions/performance.
6. Add one end-to-end backend fixture: `v1` loss → trace → accepted change → `v2` retest → paper-only promotion.

### P2 — Production live Databento/CME path

1. Accept and implement the live Databento architecture, including definition bootstrap and consumer contracts.
2. Add entitlement/secrets/cost controls, reconnect/checkpoint/deduplication/gap repair, bounded backpressure, health, and metrics.
3. Integrate live definitions and data into market-info, runtime, persistence, and historical recovery.
4. Expand product/session/expiry/roll/margin support beyond the single demo contract.
5. Prove live identity, ordering, recovery, and completeness with integration and failure tests.

## Demo-only compromises versus production claims

The following are acceptable only when disclosed in the walkthrough and UI copy:

| Compromise | Acceptable first-demo label | Must not claim |
|---|---|---|
| Pinned historical Databento fixture replayed with pacing | Historical replay | Live Databento/CME connectivity |
| Precomputed causal trace from the golden fixture | Precomputed trace | General runtime causal introspection |
| Simplified but multiplier/tick/fee-correct fill model | Simulated execution | Exchange matching or realistic queue position |
| Paper-only simulated deployment | Paper simulation | Live CME order routing |
| Static definition snapshot for one dated contract | Fixture-scoped market info | Continuous contract lifecycle support |

These labels preserve the walkthrough’s existing honesty rule and keep the implementation useful: each demo artifact should use a versioned contract that production services can later generate, rather than a client-only fake.

## Backend definition of done for the first CME demo

The first deterministic CME demo is backend-ready when all of the following are true:

- the scenario names one canonical listed contract and immutable fixture interval;
- the canonical venue and futures types round-trip through Rust, TypeScript, protobuf, storage, and Application Server APIs without renumbering existing identities;
- point-in-time Databento definitions resolve every fixture event to the same canonical contract;
- historical events carry dataset, publisher, schema, timestamps/order, definition cut, checksum, and completeness;
- the backtest simulator applies multiplier, tick size, fees, slippage, and declared fill/latency assumptions;
- the public run record exposes the exact immutable run context;
- performance APIs expose portfolio, statistics, targets, orders, fills/trades, positions, fees, slippage costs, logs/events, completeness, and terminal status;
- the scripted losing trade has a stable identity and resolves to its target, transition, evaluation tick, node values, and logs;
- `v2` is linked to its accepted change from `v1`;
- the retest proves unchanged settings or discloses every difference;
- paper promotion is one auditable operation, uses only explicit paper destinations, and binds the exact reviewed revision, run evidence, variables, and simulator configuration;
- paper fills and resulting positions/performance are durably queryable;
- an automated end-to-end backend test covers the whole evidence chain;
- the demo explicitly labels historical replay, precomputed trace, simplified simulation, and paper execution wherever those compromises remain.

Until these conditions hold, the backend can support a partial scripted prototype, but not the walkthrough’s promised inspectable and causally credible trading lifecycle.
