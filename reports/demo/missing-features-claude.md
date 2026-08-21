# Founder-Led Demo — Missing Backend Capabilities

**Date:** 2026-08-17
**Scope:** Trading services + Application Server backend only. Client/UI work is out of scope by
request, except where a backend contract is the reason a view cannot be built.
**Source of truth for the journey:** [REF:founder-led-demo](../../../knowledge-base/docs/references/founder-led-demo.md)
**Additional requirement folded in:** add a **CME venue** with market data from **Databento**
(see [brainstorm/prompts/demo/shit-we-need.md](../../prompts/demo/shit-we-need.md)).

Evidence legend used throughout:

- **[V]** verified by reading code in this workspace (file:line cited)
- **[D]** documented only — a knowledge-base record describes it, no implementation found
- **[I]** inference drawn from [V] and [D] facts

---

## 1. Verdict

The demo narrative is *"diagnose a bad trade by replaying the exact graph evaluation that caused
it, correct it, retest under identical assumptions, promote to paper."* Backend support for that
narrative breaks down at four independent points, and each is a **missing contract**, not a
missing wire-up:

1. **There are no trades.** The backtest simulator computes fills and then discards them; the
   result artifact contains position snapshots only. "Select the conspicuous losing trade" has no
   data source. **[V]**
2. **There is no state machine.** The runtime does not have states, transitions, or transition
   conditions. `evaluate_state_machine` is a stateless decision tree over memory slots,
   re-evaluated from scratch every tick, and the selected state is a local variable that is never
   stored. "State before and after", "each evaluated transition condition and its result" have no
   runtime counterpart. **[V]**
3. **There is no tick trace.** The only per-node telemetry path in the codebase does not compile
   (`g_info!` no longer exists in `ingress-egress`), is off by default in both codegen and config,
   emits a formatted string rather than a record, and drops the collector entirely on error ticks.
   Target positions are dispatched to NATS but never recorded. **[V]**
4. **There is no deployment.** `StrategyDeployment` is an infra status mirror created *after*
   Cloud Run exists; it carries no strategy, revision, accounts, arguments, or `Live | Paper` mode.
   There is no public deployment API, and `sim-gw` rejects deposits, so a paper account cannot be
   funded through the product. **[V]**

On top of that, **CME is not representable at all**: `InstrumentType` is `{SPOT, PERP}`, `Venue`
is a closed 8-variant crypto enum, and there is no expiry, settlement type, session calendar, or
margin anywhere in the domain. Databento exists only as an out-of-workspace prototype. **[V]**

**The honest reclassification** of the demo's own state table
([founder-led-demo.md:382-390](../../../knowledge-base/docs/references/founder-led-demo.md)):

| Interaction | Doc says | Actually is | Why |
|---|---|---|---|
| Manual graph/state/action/memory editing | functional | **functional** (server-opaque) | Working copy is stored as raw bytes; server never parses it **[V]** |
| Client-side validation + revision save | functional | **functional** | `DslCompiler.validateStratAndArgs`, GCS spec upload, version bump in one tx **[V]** |
| Backtest creation + current result view | functional | **partially functional** | Runs and returns statistics; no fills, no PnL, no trade count, no run context **[V]** |
| AI scaffold + strategy-aware correction | vision | **vision** | Zero AI/chat/LLM code in `packages/api` **[V]** |
| Tick Navigator replay + causal diagnosis | precomputed or vision | **vision** (precomputed for the demo) | Producer for ~7 of 8 required inputs does not exist **[V]** |
| Two backtest results side by side | functional composition | **blocked** | Cannot prove settings equality; `args` never returned by the API **[V]** |
| Paper deployment review and start | simulated or vision | **vision** | No deployment entity/API; `sim-gw` cannot fund an account **[V]** |
| **CME venue + Databento data** | *(not in the doc)* | **vision** | No futures instrument type, no CME venue, no integration code **[V]** |

Nothing changes the fact that the demo *can* be presented — but every proof moment past beat 6
currently rests on prepared data, and the knowledge base already says so
([ISS-099MC](../../../knowledge-base/docs/issues/records/ISS-099MC-tick-navigator-uses-precomputed-trace-data.md)).
This report is about what would make those moments real.

---

## 2. Beat-by-beat capability matrix

| # | Beat | Backend today | Missing |
|---|---|---|---|
| 1 | Express the idea to the assistant | — | No chat/conversation/agent endpoint or table anywhere in `packages/api` **[V]** |
| 2 | Generate the strategy scaffold | — | No strategy-authoring tool surface; only decided direction is [DEC-07VAZ](../../../knowledge-base/docs/decisions/records/DEC-07VAZ-web-client-ai-agent.md) (`proposed`) **[D]** |
| 3 | Edit manually on the canvas | `strategy-spec-gui:upload/download` (`routes.ts:1149,1181`) | Server stores opaque bytes; no graph-level working copy, no node-group storage, no lock/merge **[V]** |
| 4 | Validate + save immutable `v1` | `POST .../revisions` validates + canonicalizes + uploads spec (`strategies-service.ts:868,1965`) | No standalone `:validate` route (must create a revision to validate); immutability is convention, not a DB constraint; node implementations and runtime are not pinned to the revision (ISS-09QHF, ISS-09QHJ) **[V]/[D]** |
| 5 | Configure + run the backtest | `POST .../backtests`; time range, execution delay, starting balance, slippage bps | **Fees, per-account/per-asset balances, and Strategy Variables cannot be supplied** (ISS-09FBY) **[V]** |
| 6 | Establish promise (headline metrics) | `total_return`, `max_drawdown`, `sharpe_ratio`, `annualized_volatility`, `high_watermark`, equity curve | **Absolute PnL and trade count do not exist**; results ship as a raw SQLite blob, no JSON metrics endpoint **[V]** |
| 7 | Reveal the problem (select losing trade) | — | **No fill/trade record is produced at any layer** **[V]** |
| 8 | Investigate trade → Tick Navigator | — | No trade→target→transition→tick correlation; three near-miss keys, none agreed **[V]** |
| 9 | Replay ticks | — | No ordered tick sequence artifact; telemetry path does not compile **[V]** |
| 10 | Identify the cause | — | No state, no transitions, no transition-condition results, no recorded targets **[V]** |
| 11 | Correct with AI | — | No AI backend, and **no contract at all** — `client-views.md` explicitly renders only a `CorrectionBoundaryNotice` **[D]** |
| 12 | Save `v2` | Same path as beat 4 — works | Canonical node IDs are content hashes that include parent hashes, so **node identity is unstable across revisions** — a node-level `v1`↔`v2` diff is not computable from the DSL **[V]** |
| 13 | Retest with identical settings, compare | Two revisions × same args produce two backtests, both retrievable | `args` are never serialized to the client, so **settings equality cannot be shown or disclosed**; re-running an identical config returns `EntityExists` (409) **[V]** |
| 14 | Promote to paper | Paper trading accounts, `strategies:start`, Cloud Run deploy | No deployment entity/API/mode; `sim-gw` rejects deposits; deployed target-exec is Drift-only **[V]** |

---

## 3. Gap analysis by area

### 3.1 Backtest results — no trades, no PnL, no run context

**The single largest gap.** The simulator computes an executed order (`exec_simulator.rs:266`),
folds it into balances and positions, and writes only the post-trade snapshot
(`btest_controller/egress.rs:270`). Realized PnL is computed
(`exec_simulator/positions.rs:99,113`) and settled into a balance without ever being attributed to
a fill. **[V]**

Consequences, all of them demo-visible:

| Required | Status |
|---|---|
| Individual trades/fills with id, ts, price, qty, realized PnL | **absent** — the artifact has no fill table at all **[V]** |
| Trade count | **absent** (trivially derivable once fills exist) **[V]** |
| Absolute PnL | **absent** — only `total_return` (a ratio) and the portfolio-value series **[V]** |
| Fees | **not modeled anywhere in the simulator** — `grep -i fee` over both backtest runtimes is empty. Confirmed by [ISS-09K80](../../../knowledge-base/docs/issues/records/ISS-09K80-backtest-results-accounting.md) **[V]** |
| Traded volume, slippage cost | absent (ISS-09K80 closing criteria) **[D]** |
| Run context in the artifact | SQLite `metadata` contains **only** `version = "2026-02-02"` **[V]** |
| Run context in the API | `representationFromDomain` (`backtest-http.ts:399`) omits `args` and `artifacts` entirely **[V]** |
| Per-account / per-asset starting balances | one scalar in a synthetic USD asset for all accounts (`exec_simulator.rs:82-88`) **[V]** |
| Latency model | **incorrect** — response-only delay conflated with Solana block sequencing (`exec_simulator.rs:280-284`); documented as wrong in [backtest.md:340-375] **[V]** |
| Derivative unrealized PnL in portfolio value | Python path includes spot + cash only (NOTE-0955V) **[D]** |
| Cash-flow-aware return | [ISS-099NW](../../../knowledge-base/docs/issues/records/ISS-099NW-portfolio-return-and-value-do-not-account-for-cash-flows.md) — deposits/withdrawals/funding/fees not classified **[D]** |

**Structural issue behind this: there are two post-processors and neither is finished.**

- **Python** `backtest-utils/python/btest-statistics/` is on the live path, matches the client's
  SQL, and computes the five statistics above. It has no fills and a sampling-sensitive Sharpe
  (`pct_change` + average-interval annualization, `backtest_statistics.py:93-110`). **[V]**
- **Rust** `backtest-post-processor` has the *right* schema (`fill_events` with `trigger_seq_num`,
  `portfolio_values.unrealized_pnl`, log-return Sharpe with Kahan-Neumaier summation) but is **not
  on the live path**, and its schema is incompatible with the client's queries. Its input is an
  append-log that nothing in production produces. **[V]**
- The newer `dsl-runtime/crates/dsl-backtest-runtime` feed writer exists but
  `build_definition()` is `todo!()` (`feed_writer.rs:164`), and the production template still
  depends on the **old** `dsl-btest-runtime` (`structure-strat-template-core/Cargo.toml:41`). **[V]**

[NOTE-0955V](../../../knowledge-base/docs/notes/records/NOTE-0955V-backtest-post-processor-assessment.md)
frames the Python-vs-Rust choice; **nothing has been decided**. This decision gates beats 6, 7 and 13.

### 3.2 Tick Navigator — the long pole

Of the eight inputs the walkthrough requires, the runtime can produce **roughly one**, and only
through a path that does not build.

| Required input | Status |
|---|---|
| Typed per-node values | `LogValue{Decimal,Integer,Bool,Timestamp,Unit}` + `EmittedNodeLog` exist (`dsl-runtime-nodes/src/logging.rs:11-34`) — **but** emitted via `Display` as a multi-line string (`logging.rs:159-224`) into `g_info!` **[V]** |
| The path compiles | **No.** `ingress-egress/src/lib.rs:1-9` no longer exports `g_info!`; codegen at `graph_handlers.rs:674` calls it. The debuggable variant cannot build. **[V]** |
| Enabled by default | **No** — two switches, both off: build-time `debuggable` and runtime `debug_logging_policy.enabled`. The checked-in generated strategy is the non-debuggable variant. **[V]** |
| Error ticks | **Lost** — `}?;` at `graph_handlers.rs:670` returns before `extract_collector()`. The most diagnostic tick is blank. **[V]** |
| Ordered tick sequence for a run | **Absent.** Nothing enumerates "source events that caused ≥1 graph path to evaluate"; non-trigger topics return `Ok(None)` and log nothing. **[V]** |
| State before/after, transitions, condition results | **Do not exist as runtime concepts.** `decision_program.rs:125-135` computes `selected_state` as a local from a nested `if` tree over bare memory-slot booleans; [strategy-runtime.md:96-98] confirms this is intentional. **[V]** |
| Emitted target positions | **Never recorded.** Dispatched to `target_executor.request`, and the dispatched stream is *lossy*: suppressed during warmup and when within `target_position_tolerance_bps` (`actions.rs:104-116`). **[V]** |
| Fill → target → transition → tick correlation | **Absent.** Three near-miss keys: `engine_ctx.sn` (tick ordinal, only in the dead collector), `block_seq` (venue sequence, not unique per evaluation), `trigger_seq_num` (in the feed contract, **no producer sets it**). **[V]** |
| Node identity stable vs the saved revision | Canonical IDs are blake3 hashes **including parent hashes** (`canonical_ids/finalization.rs:38-52`) — stable within a revision, deliberately unstable across revisions. **[V]** |
| Graph layout | Persisted, but **client-side only**, in `StrategySpecGuiSnapshot`; **no stored map from GUI entity ID to canonical node ID** exists, so telemetry keyed by canonical ID cannot be painted onto the saved canvas. **[V]** |
| Persistence schema | ClickHouse has only `event_logs` and `trading_account_events`. Node values would land as a `description` string in a `Map(String,String)`-shaped table. No typed telemetry table exists. **[V]** |

[DEC-096S8](../../../knowledge-base/docs/decisions/records/DEC-096S8-dsl-graph-node-telemetry.md)
(`proposed`) designs the replacement — per-subgraph typed state records, a written-bit set,
`caps::LOGGING` const-generic handlers, node-id-bearing `RuntimeError`, per-revision `LoggingPolicy`.
Two things it does **not** solve:

- It logs **slot values**, not evaluated transition conditions or state — the demo requirement
  ("show each evaluated transition condition and its result") still has no owner.
- Its whole model is *selective* logging (schedule window + emit trigger), while the demo requires
  **every tick from first to last** of a whole backtest
  ([founder-led-demo.md:242-248]). Full-run capture volume/retention is unaddressed. **[V]**

One mitigating fact: generated graph bodies are **straight-line** — every node in a triggered
subgraph evaluates unconditionally into a `tmp_<canon_id>` local. So "which nodes evaluated" is
derivable at *subgraph* granularity without per-node bookkeeping, which is likely enough for the
canonical scenario. **[I]**

**The canonical scenario itself is affected.** The demo describes states `Flat`/`Long` and a
`Flat -> Long` transition. In the implementation, a "state" is a decision-tree leaf and a
"transition condition" is an `If` node over a memory slot. `v2`'s "momentum above threshold for
three consecutive observations" needs typed memory slots and bounded iteration —
[ISS-098AM](../../../knowledge-base/docs/issues/records/ISS-098AM-strategy-spec-missing-required-data-and-control-flow.md)
records exactly those as missing from the Strategy Spec. **This should be validated against the
DSL before the scenario is locked.** **[V]/[D]**

### 3.3 Application Server — the contract holes

The 57 routes in `routes.ts` cover auth, strategies, revisions, backtests, instruments, assets,
trading accounts, transfer intents, price history, portfolio, and internal infra callbacks. **[V]**

Absent entirely: **AI/chat**, **validation-only**, **trades/fills**, **tick replay**, **backtest
comparison**, **public deployment resource**, **deployment mode**. **[V]**

Specific fixes that are small and unblock visible beats:

| Fix | Where | Unblocks |
|---|---|---|
| Return `args` on the backtest representation | `backtest-http.ts:399` | Beat 13 settings-equality disclosure |
| Add a JSON statistics/trades endpoint (stop shipping a raw SQLite blob) | `routes.ts:1321` | Beats 6, 7 |
| Allow re-running an identical config (nonce/attempt in the id, or explicit force) | `backtests-service.ts:295-302` | Demo re-takes; currently a 409 |
| Accept Strategy Variables on backtest **and** deployment creation | `backtest-http.ts:44`, ISS-09FBY | Beats 5, 13, 14 |
| Add fees + per-account balances to `BacktestArgs` | `strategy-core/rust/src/entities/backtest.rs:38` | Beat 5 credibility |
| Validate requested range against feed availability at create time | ISS-07AFG, `backtests-service.ts:157` | Beat 13 — v1 and v2 can silently see different data |

Also worth knowing before the demo: the backtest **failure** status update is commented out
(`workflows-service.ts:483`, `// todo: update the backtest status`), and workflows still run
through Convex while the rest of the domain has moved to Postgres — a split-brain source for the
backtest lifecycle. **[V]**

### 3.4 Controlled retest — currently unprovable

The walkthrough requires holding time range, balances, fees, slippage, latency, simulator
assumptions and every unchanged Strategy Variable equal, and **disclosing anything that cannot be
held equal**. Today:

- The only evidence that two runs used the same settings is the content-addressed `BacktestId`,
  which hashes `(strategy, revision, start, stop, execution_delay, starting_balance, slippage_bps)` —
  an *indirect* proof, and it hashes the revision in, so `v1` and `v2` ids differ by construction. **[V]**
- Two server-wide knobs are **not** in the hash and not surfaced: `swap_slippage_bps` and
  `target_position_tolerance_bps` (`strategies-provision.ts:299-300`). **[V]**
- Strategy Variables are **compiled into the revision's image**, not supplied at run time, so
  "every Strategy Variable not intentionally changed" is not even an expressible concept. **[V]**
- Warmup content depends on warehouse file availability probed at runtime, with no create-time
  coverage validation (ISS-07AFG) — a `v1`/`v2` pair can be silently unequal. **[V]/[D]**

### 3.5 Paper deployment

| Blocker | Evidence |
|---|---|
| **`sim-gw` rejects deposit and withdrawal** with `UNSUPPORTED_OPERATION` — paper accounts cannot be funded through the product | `sim-gw/src/state/ready.rs:622-649`. The app-server half is *done* (`transfer-intents-service.ts:248-257`) and the NATS reply-inbox transport from DEC-08WN1 is *done* (`sim-gw/src/component.rs:117`). Only the handler is missing. **[V]** |
| **No deployment aggregate** — `strategy_deployments` is `{id, times, service, status, error}`; the row is created *after* Cloud Run exists, with the id hashed from the observed service name | `app-db/src/schema.ts:381-388`, `strategy-deployments-service.ts:103-125` **[V]** |
| **No `Live \| Paper` mode** anywhere in the domain | `strategy_deployment.ts:166-180`; listed as an open decision in NOTE-09412 **[V]** |
| **No public deployment API** — start is strategy+revision scoped and rejects a second provisioned revision | `openapi.json` (absence), `business-rules.ts:32-47` **[V]** |
| **Name collisions** — Cloud Run name and runtime-config path derive from `(user, strategy, revision)`, so a second run of `v2` overwrites the first | `strategy_deployment.ts:270-291`, `strategies-provision.ts:232-253` **[V]** |
| **Deployed target-exec is Drift-only by config**, with a stale `prefetch_strategy` key the binary no longer reads | `infra/infra/services/target-exec.ts:49-51,59-63` **[V]** |
| **Strategy registration race** — target-exec seeds strategies at boot and thereafter only on a `StrategyAttached` mutation; `target_executor.register_new_strategy` is consumed but **nothing publishes it** | `init_state.rs:112-118`, `common.rs:83-95` **[V]/[I]** |
| **No deployment feed** — target positions never emitted, fills not stored, logs not deployment-scoped, no live price source | NOTE-093V8: *"The target positions are not even emitted, so someone has to send them and someone has to store them???"* **[D]** |
| Accounts attach to the **strategy**, not the deployment | `schema.ts:195`, ISS-08ZTF **[V]** |
| HL **spot** is unusable (adapter forces swap mode, HL spec rejects it); **perps work** | [strategy-runtime.md:426-444] **[D]** |

Good news: `(PaperAccount, Venue::Hyperliquid)` **is** explicitly wired in the target executor
(`ready_state.rs:1699-1727`), positions do flow sim-gw → event-gw → ClickHouse → `/api/v0/portfolio/*`,
and revision status does flip to `Running`. The paper path is closer than the deployment model is. **[V]**

### 3.6 CME venue + Databento

This is **additive net-new work**, not a gap in an existing feature. Nothing about CME is
representable today.

**Domain blockers [V]:**

- `InstrumentType { SPOT = 0, PERP = 1 }` (`market-info-core/rust/src/entities/instrument.rs:34-40`).
  **There is no futures instrument type.** The TS mirror is `{None:0, Spot:1, Perp:2}`.
- `Venue` is a **closed enum, 8 crypto variants** (`venue.rs:126-136`), with **10 registration
  sites**, including a hand-written `Hash` impl that exists specifically to keep `InstrumentId`
  byte-stable as the enum grows (`venue.rs:167-182`). Variants must be **appended**, never reordered.
- The **TS `Venue` mirror is already out of sync** — 3 variants vs Rust's 8, different numbering,
  extra `None` sentinel (`venue.ts:47-52`). This is a latent bug independent of CME.
- `MarketInfo` is a closed `{Spot, Perp}` family with a spot/perp-only `dispatch`
  (`market_info.rs:98-111,451-454`). CME needs a third `Future` arm, rippling to **every** dispatch
  call site — including `sim-gw/src/state/ready.rs:321`.
- Missing outright, grep-verified across `market-info`, `market-info-core`, `trade`, `trade_v2`,
  `strats_v2`: **expiry / delivery month / first-notice / last-trade date**, **settlement type**
  (cash vs physical), **roll / continuous contract**, **session calendar / trading hours / holidays**,
  **initial and maintenance margin**, **price limits**.
- `QuoteUnit` has only `Asset { asset_id }`; the index-point variant is **explicitly deferred**
  in [market-info.md:44-48]. `ContractId` is an opaque `u64` with no fields — the contract entity
  described in `contract.md` does not exist in code.
- `PerpMarketTrait::funding_asset()` is mandatory — meaningless for a dated future.

**What already exists and helps [V]:** `settlement_qty_per_quote_unit()`
(`market_info.rs:159-163`) whose doc comment is literally *"$50 per index point"* for the CME
E-mini; `Fiat::USFed`; `min_px_inc`/`min_qty_inc`/`listing_status`; and
[DEC-07D6D](../../../knowledge-base/docs/decisions/records/DEC-07D6D-market-info-quote-unit.md)
which states the quote-unit change exists precisely so CME market info can be represented.

**Databento status [V]:** `prototypes/databento-md/` is a standalone crate with its own
`[workspace]`, **not** a member of the root `Cargo.toml`, writing to stdout only — no NATS, no
domain types. In production code, `MarketDataVendor::Databento` exists as a **label with no
behavior**.

[DEC-08T3R](../../../knowledge-base/docs/decisions/records/DEC-08T3R-databento-integration-architecture.md)
is `proposed` and **9 of its 10 areas are marked "not decided"**, including *Domain Venue Support*,
*Historical Backtest Replay*, *Historical Backfill*, and *DBN Consumer Integration*. The NATS topic
scheme is "deliberately deferred". **[D]**

**The decision that gates everything else:** DEC-08T3R specifies publishing provider-native
`DBNMdUpdate` (raw DBN v3 bytes, rkyv `FeedEnvelope`), which is **incompatible with every existing
consumer** — the warehouse persister, the `dsl-runtime` historical reader, and the price resolver
all speak protobuf `structure.Book`/`structure.Trade` on `md.instruments.{id}.*`. Three mutually
exclusive options, none decided:

1. Normalize DBN → `structure.Book` **in the md-server** (contradicts DEC-08T3R C-04/C-06, but
   requires **zero** changes to the persister and backtest reader — warehouse paths are already
   venue-agnostic because the venue is inside the `instrument_id` hash).
2. Normalize **in the persister** (keeps DEC-08T3R intact; persister gains a DBN decoder).
3. **New DBN-native dataset type** + new `TickData` arm + `build_tick_data_payload` support + a DBN
   book builder in `dsl-runtime`.

Option 1 is by far the cheapest path to a working backtest and is the recommendation below. **[I]**

**Execution-side blockers for a session-based venue [V]:**

- **`sim-gw` has a contract-multiplier bug**: `fill_quote_delta` computes `qty * price` with no
  multiplier (`sim-gw/src/state/ready.rs:460-462`). This is a **correctness bug for every contract
  with `settlement_qty_per_quote_unit ≠ 1` — i.e. every CME future.**
- No trading-session gate, no halt/auction handling, no RTH-vs-ETH, no daily settlement anywhere.
  `MarketStatusEventKind` exists **only** as a feed-content descriptor with no runtime consumer.
- No expiry/auto-roll/final-settlement lifecycle; no margin model.
- `sim-gw` accounts in USDC-shaped home currency; no CME `HomeCurrencyTrait` impl (fiat USD).
- No real CME order gateway exists and Databento does not provide one — live CME execution needs a
  separate broker/FIX integration and is **out of scope for a paper demo**.

**And a data blocker that is already an open issue:**
[ISS-099M9](../../../knowledge-base/docs/issues/records/ISS-099M9-demo-replays-historical-databento-data-as-live.md)
— the Databento starter plan does not supply venue or sequence numbers, so a Feed Orderand cannot
be constructed, which is why the demo plan is to replay the previous day's history as if live. The
CME orderand shape is documented as `{year, week, sequence_number}` (CME resets sequence numbers
weekly); **no Rust type exists for it.** **[D]**

---

## 4. Cross-cutting blockers

These block multiple beats at once and should be sequenced first.

| # | Blocker | Blocks |
|---|---|---|
| X1 | **No fill/trade record produced by the simulator** | Beats 6, 7, 8, 13 |
| X2 | **Node telemetry path does not compile** (`g_info!` removed from `ingress-egress`) | Beats 9, 10 — prerequisite to all telemetry work, and to DEC-096S8 itself |
| X3 | **No agreed tick identity** — `engine_ctx.sn` vs `block_seq` vs `trigger_seq_num` | Beats 8, 9, 10; also the deployment feed |
| X4 | **Strategy Variables are compiled into the image, not run-time inputs** (ISS-09FBY) | Beats 5, 13, 14 |
| X5 | **No deployment aggregate / no `Live \| Paper` mode** (ISS-0002, NOTE-09412) | Beat 14, and any per-deployment feed |
| X6 | **Post-processor fork unresolved** (Python on-path vs Rust off-path, incompatible schemas) | Beats 6, 7, 13 — every metrics decision waits on this |
| X7 | **`Venue` closed enum + no futures `InstrumentType`** | All CME work |
| X8 | **Node identity unstable across revisions** (content hashes include parents) | Beat 12's "reviewable diff" at node granularity |

---

## 5. Recommended sequencing

Ordered by *unblocking power per unit of work*, not by demo order.

### Phase A — make the backtest tell the truth (unblocks beats 5-7, 13)

1. **Emit fills.** Add a `FillEvent`-shaped variant to `SimExecReport` and write it from
   `exec_simulator.rs:266` instead of discarding it. Carry `trigger_seq_num` from the tick that
   produced the target. *(This is also the cheapest way to establish X3 — pick the key here and
   make everything else follow.)*
2. **Extend the on-path post-processor** with `fills`, `trade_count`, and absolute PnL rows; stamp
   the full run context into SQLite `metadata`.
3. **Return `args` from the API** (`backtest-http.ts:399`) and add a JSON statistics/trades endpoint.
4. **Accept Strategy Variables + fees on backtest creation** (ISS-09FBY); include them in the
   `BacktestId` hash and in the recorded run context.
5. **Allow identical re-runs** (nonce or force flag) so the demo can be re-taken.

Decide X6 (Python vs Rust post-processor) before step 2 — doing step 2 in Python and then switching
to Rust is the main waste risk here.

### Phase B — make the deployment real (unblocks beat 14)

6. **Implement deposit/withdrawal in `sim-gw`** (`ready.rs:622-649`) against the already-working
   reply-inbox path. Small, self-contained, and the only thing standing between paper accounts and
   funding.
7. **Give `strategy_deployments` a real aggregate**: `strategyId`, `revisionId`, `accounts`,
   `effectiveArgs`, `mode: Live | Paper`, `supportingBacktestId`. Allocate the id **before** the
   workflow and thread it into the Cloud Run name, the runtime-config object path, and `engine_id`.
8. **Expose `POST /api/v0/strategy-deployments`** doing validation + attachment + workflow start in
   one transaction.
9. **Reconfigure the deployed target-exec for Hyperliquid perps** (`infra/infra/services/target-exec.ts`),
   and **publish `target_executor.register_new_strategy`** at deployment start to remove the
   attachment race.

### Phase C — make the diagnosis real (beats 8-10) — the long pole

10. **Restore a compiling telemetry path** (X2) — migrate `g_info!` → `logger2` per DEC-096S8's
    stated prerequisite. Nothing else in this phase can start first.
11. **Emit target positions as records** (pre-tolerance, pre-warmup-suppression), keyed by the tick
    identity chosen in Phase A step 1.
12. **Record decision-program evaluation**: selected state, previous state, and each branch
    condition's boolean result. This is **net-new runtime concept work** and is not covered by
    DEC-096S8 — it needs its own decision record.
13. **Persist typed node values as records, not strings**, with a schema that supports whole-run
    capture. Resolve DEC-096S8's selective-logging model against the demo's every-tick requirement.
14. **Persist a GUI-entity-ID ↔ canonical-node-ID map with the revision**, so telemetry can be
    painted onto the saved canvas.

For the demo itself, ISS-099MC's precomputed-trace approach remains the honest fallback. Phase C is
a product capability, not a demo prerequisite — **but it should be labelled as precomputed in the
runbook, not presented as live replay.**

### Phase D — CME + Databento

15. **Decide the venue granularity first** — CME vs CME Group vs per-DCM (CBOT/NYMEX/COMEX).
    `glossary.md` insists CME ≠ CME Group; `shit-we-need.md:31` records the question as open. This
    decision is cheap now and expensive later, because `Venue` variants can only be appended and
    the `Hash` impl guarantees `InstrumentId` byte stability.
16. **Append `Venue::Cme` across all 10 registration sites**, add `InstrumentType::FUTURE = 2`, and
    **re-sync the TS `Venue` mirror** (currently a latent bug).
17. **Author a futures market-info DEC** (expiry, settlement type, contract multiplier, tick value,
    session calendar reference, margin) and add the `FutureMarketInfo` family + `MarketInfo::Future`
    arm + third `dispatch` closure.
18. **Resolve the DBN payload fork** (recommend option 1: publish `structure.Book`/`structure.Trade`
    on the existing `md.instruments.{id}.*` subjects, optionally mirroring raw DBN on a parallel
    subject). If option 1 is taken, `live_md_data_persister` and the backtest reader need **zero**
    changes.
19. **Promote `prototypes/databento-md` to a `dbn-md-server`** on the `coin-api-md-server` scaffold
    (runtime config traits, health-check producer, multihost `build.rs`, NoopRecorder/NullPersister),
    and add it to the root workspace.
20. **Fix the `sim-gw` multiplier bug** (`ready.rs:460-462`) — required before any CME contract can
    be simulated correctly.
21. **Add session/calendar gating** to `sim-gw` and session-aware gap handling to the backtest clock,
    so an overnight CME close is not read as a stall.

---

## 6. Decisions needed from a human

These are forks where the code cannot tell us the answer, and each one gates work above.

1. **Post-processor:** Python (on-path, thin, matches the client) or Rust (correct math, has fills,
   off-path, incompatible schema)? — gates Phase A.
2. **Tick identity:** which of `engine_ctx.sn` / `block_seq` / `trigger_seq_num` becomes *the* join
   key across fills, targets, and node telemetry? — gates Phases A and C.
3. **Demo scenario venue:** the canonical scenario is Hyperliquid BTC perp. Does adding CME change
   the demo scenario, or is CME a separate second story? Note HL **spot** is broken and HL **perps**
   work, so the current scenario is on the working path.
4. **CME venue granularity:** CME vs CME Group vs per-DCM.
5. **DBN payload:** provider-native `DBNMdUpdate` (per DEC-08T3R) vs normalized `structure.Book`
   (per every existing consumer).
6. **Full-run telemetry volume:** the demo needs every tick of a whole backtest; DEC-096S8 is built
   around selective logging. Which requirement gives?
7. **Which beats are honestly precomputed** in the first build. The demo doc requires this
   classification and the current table is optimistic on beats 6, 13 and 14.

Also worth noting: **every demo-relevant DEC is `proposed`**, `DEC-093YP-demo-app-v0` is an
**empty template** with unfilled placeholder prose, and **there is no execution plan for the demo**
in `knowledge-base/docs/execution-plans/`. The demo has a narrative and scattered proposals, but no
accepted architecture decision to build against.

---

## 7. Evidence index

Knowledge-base records referenced (all `proposed`/`open` unless noted):

| Record | Relevance |
|---|---|
| REF:founder-led-demo | The journey; owns the 14 beats and the demo-state classification |
| REF:client-views | Tick Navigator / Strategy Performance / Deployment view contracts — all "planned — not built" |
| DEC-096S8 | DSL graph node telemetry — the designed telemetry source |
| DEC-09S6G | Strategy Performance feed — PnL model, `DataFeedOrderand{feed_id, sn}`; provenance link explicitly unsettled |
| DEC-09GKC | Backtest view + DuckDB artifact schema |
| DEC-07VAZ | Web client AI agent — only decided path to beats 1-2 and 11 |
| DEC-08T3R | Databento integration — 9 of 10 areas "not decided" |
| DEC-07D6D | Market-info quote unit — CME E-mini is the driving example |
| DEC-08K41 | Backtest lifecycle initialization and warmup |
| DEC-09DTK | Target executor capital management — explicitly out of demo scope |
| ISS-099MC | Tick Navigator uses precomputed trace data |
| ISS-099M9 | Demo replays historical Databento data as live |
| ISS-09FBY | App server must accept strategy variables |
| ISS-098AM | Strategy Spec missing required data and control flow (memory, bounded loops) |
| ISS-09K80 | Backtest results accounting (fees, volume, slippage cost) |
| ISS-07AFG | Backtest feed availability validation |
| ISS-099NW | Portfolio return/value ignore cash flows |
| ISS-0002 / ISS-08ZTF | Provisioned-revision entity / deployment-owned account attachment |
| ISS-09QHF / ISS-09QHJ | DSL nodes and runtime not pinned to a revision |
| NOTE-09412 | Introduce strategy deployment — 8 open decisions incl. `Live \| Paper` |
| NOTE-093V8 | Demo app v0.0 — "the target positions are not even emitted" |
| NOTE-0955V | Backtest post-processor assessment — the Python/Rust fork |
| NOTE-09J2D | Backtest order execution trace |

Method: the walkthrough was read in full, then six parallel exploration agents swept the
knowledge base, `structure-web/packages/api` + `app-db`, the DSL compiler/runtime and strategy
template, the backtest pipeline and simulator, market-info/domain/messaging for venue and
instrument modelling, and the deployment/paper-trading path. Claims marked **[V]** were read in
this workspace at the cited location.
