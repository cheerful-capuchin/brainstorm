# Backtest Output: Where It Is Produced and Written

Date: 2026-09-22
Scope: context for an agent changing what a backtest emits (the "backtest feed").
Related:
- [Backtest Historical Replay walkthrough](2026-09-20-hist-replay.md) (the ingress side)
- [Bucket Structure](decisions/2026-09-20-hist-replay-bucket-structure.md),
  [Replay Ingress](decisions/2026-09-20-hist-replay-ingress.md),
  [Warmup removal](decisions/2026-09-20-warmup.md), [Testing](decisions/2026-09-20-testing.md)

State of the tree: the Databento replay (`DbnFileStream`, route driven planning, no backtest
warmup) landed on 2026-09-22, uncommitted. `just check` and `just e2e-backtest` in
`structure-strat-template-core` are green.

## The one sentence version

A backtest today has **no feed**. Its only output is a JSONL file of simulated account snapshots,
written by `BTestControllerEgress` to the `outfile` path in the config, plus a `BacktestSummary`
value returned in process. Nothing is published on NATS, and the `DataFeedSubject::Backtest`
variant that exists in `data-feed-core` has no feed definition and no publisher.

## Data flow of one fill

Paths are relative to the workspace root. `core` = `structure-strat-template-core/src`,
`btest-rt` = `dsl-runtime/crates/dsl-backtest-runtime/src`.

```
DbnFileStream::peek_next / pop                   core/hist_replay/dbn_file_stream.rs:173
└─ engine ingress: StratIngressMsg::HistTickData
   └─ StratComponentHost::on_hist_tick_data     core/component.rs:428
      ├─ on_feed_subject → strategy runs → Option<BTestAction>
      └─ fill_backtest_action                   core/component.rs:477
         ├─ Some(action):
         │  ├─ ExecSimulatorState::process_btest_action   core/state/exec_simulator.rs
         │  │  └─ ExecSimulator::on_btest_action          btest-rt/exec_simulator.rs:351
         │  │     → SimExecReport::SimAccountSnapshot     (the only report shape, built at :370)
         │  ├─ egress StratEgressMsg::SimExecReport       core/state/strat_logic/btest_state.rs (send)
         │  └─ egress StratEgressMsg::BTestProcessResult::TickProcessed   btest_state.rs:163
         └─ None: ack the replayer directly (no egress)

BTestControllerEgress (one consumer, own thread)  btest-rt/btest_controller/egress.rs
├─ handle_sim_exec_report                        :378
│  ├─ send ExecReportMsg::Report to SimExecReporter, await its ack
│  └─ write_action_to_file → one JSONL line      :272
└─ handle_btest_process_result                   :243
   ├─ TickProcessed        → set replayer_ack_notify
   └─ AllStreamsExhausted  → flush_and_close_file, signal reporter, ack   :333

SimExecReporter (a HistDataStream inside the replayer, priority 10_000)
└─ re-injects the report at T + execution_delay as StratIngressMsg::SimExecReport
   └─ StratBacktestState::on_sim_exec_report     core/state/strat_logic/btest_state.rs:501
      └─ position update through the strategy → next BTestAction or TickProcessed
```

The loop closes at the last step: a fill can produce another action, which produces another
report, until a tick ends with only `TickProcessed`.

## Files, by role

### The writer (what a "backtest feed" change most likely replaces or extends)

`dsl-runtime/crates/dsl-backtest-runtime/src/btest_controller/egress.rs`

| Item | Line | What it does |
|---|---|---|
| `SimReport<'a>` | 73 | The serialized line: `#[serde(flatten)] SimAccountSnapshot` + `instrument_metadata` map |
| `BTestControllerEgressConfig<M>` | 80 | Config: `sim_sender`, `replayer_ack_notify`, `backtest_config`, `outfile`, `strategy_id`, `strategy_rev`, `mkt_info_repo`, `initial_snapshot` |
| `initialize` | 144 | Creates the parent dir, truncates `outfile`, writes the t=0 record (the funded accounts) |
| `handle_btest_process_result` | 243 | `TickProcessed` → ack replayer; `AllStreamsExhausted` → flush, close, tell the reporter; legacy `BTestAction` → re-send to ingress |
| `write_action_to_file` | 272 | One `SimReport` per `SimExecReport`, `serde_json::to_writer`, flush every 100 |
| `on_all_streams_exhausted` | 333 | End of run: `flush_and_close_file`, signal reporter exhaustion, ack |
| `handle_sim_exec_report` | 378 | Sends the report to `SimExecReporter` (awaits its ack), then writes the line |
| `collect_instrument_metadata` | 414 | Venue + symbol per instrument from `mkt_info_repo`, computed once and cached |

This is a `dsl-runtime` crate: it is a separate git repository consumed as a git dependency and
patched to the local path in the workspace `.cargo/config.toml`. A change here needs a rev bump in
`structure-strat-template-core/Cargo.toml` when it is published.

### The report types

`dsl-runtime/src/backtest.rs`

- `BTestProcessResult` (line 33): `TickProcessed`, `AllStreamsExhausted`, `BTestAction`.
- `SimExecReport` (line 188): one variant, `SimAccountSnapshot`. The doc comment says it "will be
  extended with execution details (filled quantity, price, etc.)". It has not been.
- `SimAccountSnapshot` (line 207): `account_snapshots: Arc<[(AccountId, AccountSnapshotEntry)]>`,
  `execution_ts_ns`, `block_seq`.
- `AccountSnapshotEntry` (line 214): `positions: Arc<[(InstrumentId, Position)]>`,
  `balances: Arc<[(AssetId, Balance)]>`.

The JSON shape the e2e test reads is therefore
`{ account_snapshots: [[account_id, { positions: [[instrument_id, position]], balances: [...] }]], execution_ts_ns, block_seq, instrument_metadata: {...} }`.

### The producer of reports

- `dsl-runtime/crates/dsl-backtest-runtime/src/exec_simulator.rs`: `ExecSimulator::on_btest_action`
  (line 351) fills against mid ± slippage at `current_ts + execution_delay` and builds the
  `SimAccountSnapshot` (line 370). Line 121 builds the funded starting snapshot.
- `structure-strat-template-core/src/state/exec_simulator.rs`: `ExecSimulatorState::funded` (line
  54) applies the starting balances as deposits; `process_btest_action` wraps the simulator for the
  component.

### The strategy side that sends and consumes them

`structure-strat-template-core/src/`

- `component.rs`: `StratEgressMsg` (line 141) has `BTestProcessResult` and `SimExecReport`
  variants with the `MaybeBTestProcessResult` / `MaybeSimExecReport` trait impls (lines 145–160)
  that let the generic egress controller find them. `fill_backtest_action` (line 477) is where a
  fill becomes an egress message.
- `state/strat_logic/btest_state.rs`: `send_tick_processed_msg` (line 163),
  `send_all_streams_exhausted_msg` (line 150), `on_sim_exec_report` (line 501, `_internal` at 398) which folds the
  snapshot back into the strategy, and `from_warmup` (line 83) which seeds
  `mkt_data_stream_statuses` from the feed routes (this is what ends the run).
- `lib.rs`: `run_backtest` (line 795) builds the egress manager with exactly one consumer,
  `BTestControllerEgressConfig` (line 896). There is no NATS publisher in the backtest regime.
  The `Regime::Backtest` arm of `run` (line 193) installs a stdout only logger, so runtime events
  do not leave the process either. `BacktestSummary` is assembled at the end (line 1046).
- `backtest.rs`: `BacktestSummary` (line 84): `backtest_id`, `completion`, `feed_ticks` per
  subject, `sim_exec_reports` count. `ReplayStats::note` (line 126) is where the mux counts
  ingress messages; it is the only in process accounting of what was replayed.

### The feed vocabulary that exists but is unused

- `data-feed-core/rust/crates/data-feed-core/src/subject.rs:18`: `DataFeedSubject::Backtest(StrategyBacktestSubject)`.
- `strategy-core/rust/src/entities/backtest/subject.rs:10`: `StrategyBacktestSubject`.
- `data-feed-definitions/rust/crates/data-feed-definitions/src/demo/`: feed definitions for
  `databento_mbo_feed`, `sim_venue_feed`, `strategy_deployment_feed`, `target_position`,
  `trading_account_feed`, `trading_account_events_feed`. **No backtest feed.** A backtest feed
  would be a new definition here plus a generated codec crate under `rust/crates/codecs/`, in the
  same shape as the sim venue or trading account feeds. See `dev-docs` on messaging wire
  conversion and the `messaging-wire-conversion` skill before adding one.
- The live deployment feeds (`strategy_deployment_feed`, target positions, runtime events) are
  published through `NatsPublisherWithCtxConfig` in `run_strategy_live` only.

### The sim venue feed is the closest existing analogue

`SIM_VENUE_FEED` (`data-feed-definitions/.../demo/sim_venue_feed.rs`, codec
`data-feed-codec-protobuf-279de42a6d1dd30b7f689dc8033cb6a0`) is consumed by the strategy in both
regimes, keyed by `DataFeedSubject::TradingAccount`, and `FeedRoutes::for_strategy`
(`structure-strat-template-core/src/feed.rs:78`) registers one route per backtest account. In a
backtest it is never actually decoded: the simulator's report reaches the strategy as
`StratIngressMsg::SimExecReport`, not as a feed payload. If the goal is "the backtest publishes
what a live deployment would publish", the account snapshot ↔ sim venue feed mapping is the seam.

### Downstream consumers of the outfile

- `structure-strat-template-core/strats/flip-positions/tests/backtest_e2e.rs`: `read_fills` parses
  each line after the first and asserts `execution_ts_ns` and the sign of `positions[0][1]`.
  Any change to the line shape breaks this test; update it deliberately.
- `structure-web/packages/api/src/backtests/backtests-service.ts`: launches the strategy as a
  Cloud Run job with `--outfile=<results bucket>/target-positions.jsonl` (line 1451) and then a
  statistics job that reads it and writes `statistics.jsonl` and a sqlite file (lines 1540–1556).
  Note: this still passes the **old CLI flags** (`--warehouse-dir`, `--start-ts`, ...). The
  strategy binary only accepts `--config` and `--regime` since the config rework; the web launch
  path is not migrated. File names are constants in `backtests-repository.ts` (lines 232, 276).
- The statistics job's source is not in this workspace; it is the other reader of the JSONL shape.

## Invariants to keep

1. **One replayer ack per ingress message.** `handle_sim_exec_report` awaits the reporter's ack
   before writing; `TickProcessed` and `AllStreamsExhausted` set `replayer_ack_notify`. Writing
   more, or to another sink, must not add a second ack or skip one, or the sync replayer stalls.
2. **The report goes to the reporter before it is written.** Order in `handle_sim_exec_report` is
   reporter first, file second, so a write failure never loses a fill from the simulation.
3. **The t=0 record is the funded state**, produced by `ExecSimulatorState::funded` in `lib.rs`
   and handed in as `initial_snapshot`. The component funds its own simulator the same way; the
   two must agree.
4. **`AllStreamsExhausted` closes the file.** It is the only close; an interrupted run (SIGINT →
   `ShutdownRequest`) relies on `BufWriter` drop and may lose up to 99 unflushed lines.
5. **The egress consumer runs on its own thread** with a `RefCell<Option<BufWriter<File>>>`; it is
   not shared. A NATS publisher would be a second `EgressConsumer` added in `run_backtest`, or a
   second sink inside this one.

## Things an agent should decide before editing

- Whether the output stays a file, becomes a feed on NATS, or both. Cloud Run jobs have no NATS
  today in the backtest regime (`run_backtest` builds no publisher), so a feed needs the NATS URL
  wired in and a shutdown path that drains it.
- Whether to extend `SimExecReport` with execution details (the type's own doc says so) or to
  emit a separate record type. The former changes every `match` on the enum in `exec_simulator.rs`
  and `btest_state.rs`; both files list the sites.
- How `structure-web` and the statistics job learn about a new shape; the file names and the
  first line contract are hard coded on that side.

## How to verify

```
cd structure-strat-template-core
just check                 # unit + integration, includes the slice e2e (4 tests)
just e2e-backtest          # full LFS days, ~18 s
```

The outfile of the slice run lands in
`<workspace>/target/tmp/backtest_e2e/slices/out.jsonl` (`CARGO_TARGET_TMPDIR`) (first line is the t=0 baseline).
