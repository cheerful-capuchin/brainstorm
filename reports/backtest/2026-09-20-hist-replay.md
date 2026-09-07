# Backtest Historical Replay — Call Stack Walkthrough

Date: 2026-09-20
Scope: `structure-strat-template-core` backtest regime, from `src/lib.rs` down to the
warehouse readers and the simulated-fill feedback loop.
Context: current replay reads Apache Arrow files (`dsl-runtime/src/hist_data.rs`); the
upcoming integration will read Databento historical data instead, and the Arrow files go away.

---

## Overview

The backtest is a **two-phase historical replay** driving a single-threaded engine, with a
feedback loop that injects simulated fills back into the same ingress channel.

Six things run concurrently:

| Component | Thread/task | Role |
|---|---|---|
| Warmup replayer | own OS thread + current-thread tokio runtime | replays `[start_ts − lookback, start_ts)` to prime the DAG |
| Backtest replayer | own OS thread + current-thread tokio runtime | replays `[start_ts, stop_ts)` and owns the simulated-fill stream |
| Ingress mux | one OS thread (`backtest-ingress-mux`) | drains warmup then backtest channels into the engine ingress, emits `ReplayComplete` per phase |
| Engine | one OS thread | drains ingress, dispatches to the component, increments `sn` |
| Egress manager | own thread | routes strategy egress (NATS / `BTestProcessResult` / `SimExecReport`) |
| `SimExecReporter` | tokio task inside the **backtest replayer** runtime | a `HistDataStream` that re-injects exec reports at `T + execution_delay` |

The replay is file-driven: topics come from `StratTopicManager`, resolved to hourly `.arrow`
objects in a warehouse dir; each object becomes an `ArrowFileProvider` stream; the replayer
k-way-merges streams by `DslSeqNum` and pushes `StratIngressMsg::HistTickData` into ingress.

The execution loop (documented at `structure-strat-template-core/src/state.rs:17`) is:

```
HistTickData → logic (DAG) → BTestAction
   → simulator fills → SimExecReport (queued in reporter at T+delay)
   → reporter re-injects SimExecReport as ingress
   → logic applies position update → next BTestAction or TickProcessed
   → egress acks the replayer → next tick
```

Invariant: exactly one replayer ack per ingress message.

---

## Phase 0 — startup and wiring

```
run()                                       structure-strat-template-core/src/lib.rs:309
└─ run_strategy_backtest(args)              lib.rs:1011
   ├─ load_and_validate_config              lib.rs:400
   ├─ BTestConfig { start, stop, delay,     lib.rs:1025
   │               starting_balance, slippage }
   ├─ BacktestId::compute                   lib.rs:1042
   ├─ prepare_backtest_component_params     lib.rs:512
   │  ├─ build_for_backtest                 config.rs:164
   │  │  ├─ StratTopicManager::from_strat_params_and_symbolic_topics   config.rs:182
   │  │  ├─ append_account_topics_for_backtest                         config.rs:194
   │  │  └─ FeedRoutes::for_strategy        config.rs:196  (feed topics + sim-venue accounts)
   │  ├─ build_strat_data                   generated/mod.rs:21
   │  └─ calculate_lookback_window_ns       generated/mod.rs:31  (max node warmup period)
   ├─ setup_backtest_historical_replayers   lib.rs:593 (call site lib.rs:1128)
   │  ├─ create_backtest_hist_replayer      helpers.rs:287
   │  └─ create_warmup_hist_replayer_backtest helpers.rs:161
   ├─ egress ManagerBuilder … BTestControllerEgressConfig   lib.rs:1144 / lib.rs:1176
   ├─ spawn backtest-ingress-mux            lib.rs:1196
   ├─ build_backtest_engine_params          lib.rs:1287
   ├─ start_engine                          lib.rs:1304
   └─ start_backtest_components             lib.rs:724 (call site lib.rs:1325)
      └─ replayer.start(None,None,None)     ingress-egress/src/hist_data.rs:363
```

The two replayers differ in one constructor argument:

- warmup: `StreamingHistDataReplayer::new(sender, ctl, None)` → `sync_mode = false` → runs
  `run_async` (batch replay, no ack).
- backtest: `…::new(sender, ctl, Some(replayer_ack_notify))` → `sync_mode = true` → runs
  `run_sync` (one tick per ack).

The backtest replayer also gets `SimExecReporter` as an extra stream (`helpers.rs:398-409`,
priority `10000`).

---

## Phase 1 — which files get replayed

```
topic_manager.topics()                          dsl_runtime/src/topics.rs:404
   (keys of relevant_topics: "md.instruments.<instrument_id>.<book|funding|trade|
    spot_rate_record|oracle_price>" + account position-update subjects)
for topic in topics:
  get_relevant_topic_tick_type(topic)           topics.rs:158
  get_topic_priority(topic)                     topics.rs:191   (table at topics.rs:198)
  warehouse::get_btest_hist_data_files(...)     dsl-runtime/src/hist_data/warehouse.rs:12
    └─ resolve_file_paths(topic, start, stop, 3600s)   hist-data-common/src/warehouse_utils.rs:195
       └─ resolve_file_path(topic, window_start, window_end)  warehouse_utils.rs:121
            → "<dataset>/live_md_server/<instrument_id>/YYYY/MM/DD/
               <start>_<end>.arrow"
  venue_for_topic(mkt_info_repo, topic)         helpers.rs:47
  probe_existing_paths(paths, warehouse, venue) helpers.rs:66
     primary path, else legacy "<venue>/…" via legacy_relative_path  warehouse_utils.rs:269
  ArrowFileProvider::<StratIngressMsg>::new(    dsl-runtime/src/hist_data.rs:206
      name, tick_type, subject = topic,
      base_folder = warehouse_dir, file_names, priority, min_ts, max_ts)
  hist_replayer.add_stream(...)
```

Time bounds:

- warmup: `min_ts = start_ts − lookback`, `max_ts = start_ts` (`helpers.rs:247-257`).
- backtest: `min_ts = start_ts`, `max_ts = stop_ts` (`helpers.rs:369-379`).

Notes:

- File-name planning assumes **hour-aligned `.arrow` objects** and a topic string parseable as
  `MdServerTopics`. Account topics fail that parse and are silently skipped (`Err(_) => continue`).
- `ArrowFileProvider` pre-scans directories to build an existence set (`hist_data.rs:293`), then a
  background thread prefetches batches in 4 MB chunks (`hist_data.rs:360`).
- Row extraction reads only **column 0 = `timestamp_ns: UInt64`** and **column 2 = `payload:
  Binary`** (`hist_data.rs:616`). Column 1 (`subject`) is ignored; the stream's constructor
  `subject` is copied onto every `HistTickData` (`hist_data.rs:649`). Payloads stay encoded; the
  strategy decodes them later.
- Per-row ordering key is `DslSeqNum { ts_nanos, block_seq }`, with `block_seq =
  SequenceNumber::Generic { sn: timestamp_ns }` for feed payloads (`hist_data.rs:661`).

---

## Phase 2 — warmup replay

```
replayer.run()                                  ingress-egress/src/hist_data.rs:999
├─ prime_streams                                hist_data.rs:501   (peek every stream)
├─ process_priming_results                      hist_data.rs:526
└─ run_async                                    hist_data.rs:1053  (warmup: sync_mode=false)
   loop:
   ├─ check_waiting_streams                     hist_data.rs:596
   ├─ heap.pop() → process_heap_item            hist_data.rs:855
   │  └─ ArrowFileProvider::peek_next/pop        dsl-runtime/src/hist_data.rs:762 / :852
   │       (skip ts < min_ts; Exhausted at ts >= max_ts)
   └─ sender.send(IngressMsg::ComponentMsg{ HistTickData, mode=Replay })
└─ send_completion_message                     hist_data.rs:833  (replayer's own ReplayComplete)
```

The mux thread drains that channel and forwards it to the engine, **dropping the replayer's own
`ReplayComplete`** and sending the authoritative one after the channel closes (`lib.rs:1221-1248`),
because the engine panics on duplicate `ReplayComplete`.

Engine path per tick:

```
engine.run_event_loop                          engine/src/engine.rs:164
└─ process_component_msg                       engine.rs:187
   └─ StratComponentHost::process_msg          component.rs:320
      └─ on_hist_tick_data                     component.rs:458
         └─ on_feed_subject                    component.rs:433
            ├─ feed_routes.resolve(subject)    component.rs:440  → UnknownFeedSubject if missing
            └─ on_feed_msg → FeedCodecs::consume  component.rs:396 / feed.rs:167
               └─ StrategyHandler::handle_mbp1_book_update  handler.rs:251
                  └─ dispatch_instrument_tick → dispatch        handler.rs:105 / :122
                     └─ StratLogicState::Warmup arm              handler.rs:140
                        └─ handle_tick_data_common (folds trackers, drops actions)
```

Warmup transition:

```
ReplayComplete (mux) → engine.process_engine_msg              engine.rs:235
└─ StratEngineState::handle_engine_msg                        state.rs:58
   └─ StratLogicState::handle_engine_msg                      strat_logic.rs:128
      └─ ExpectedReplayCompletion::WarmupReplay               strat_logic.rs:148
         ├─ warmup.on_exit
         └─ StratBacktestState::from_warmup                   btest_state.rs:86
            + apply_starting_positions, seed stream statuses
            → state = Backtest; expected = BacktestReplay
```

---

## Phase 3 — main replay and the simulated-fill loop

Mux phase 2 forwards backtest ticks (`lib.rs:1256`). Per market tick, in the backtest state:

```
on_hist_tick_data                                    component.rs:458
├─ backtest.note_tick                                btest_state.rs:246
└─ on_feed_subject → on_feed_msg                     component.rs:433 / :396
   └─ dispatch → StratLogicState::Backtest arm       handler.rs:217
      └─ handle_tick_data_common → dispatch_tick_result_internal
                                                     btest_state.rs:389 → Option<BTestAction>
└─ fill_backtest_action                                component.rs:507
   ├─ Some(action):
   │  ├─ sim.process_btest_action(action, current_ts) exec_simulator.rs:84
   │  │  └─ ExecSimulator::on_btest_action            dsl-backtest-runtime/src/exec_simulator.rs:277
   │  │       execution_ts = current_ts + execution_delay; fills vs mid ± slippage
   │  ├─ send SimExecReport → egress                   btest_state.rs:152
   │  └─ send BTestProcessResult::TickProcessed → egress  btest_state.rs:187
   └─ None: direct ack via replayer_ack_notify         component.rs:544
```

Egress manager handling:

```
BTestControllerEgress::handle_msg                     egress.rs:189
├─ SimExecReport → handle_sim_exec_report             egress.rs:375
│  ├─ send ExecReportMsg::Report to SimExecReporter (await ack)
│  └─ write JSONL snapshot (flush every 100)          egress.rs:269
└─ BTestProcessResult → handle_btest_process_result   egress.rs:240
   ├─ TickProcessed → send_replayer_ack (AtomicBool)  egress.rs:371
   ├─ BTestAction   → re-send to ingress (legacy path)
   └─ AllStreamsExhausted → flush/close, signal reporter, ack  egress.rs:330
```

`SimExecReporter` sits inside the backtest replayer's merge:

```
ReporterInner::run                                    sim_reporter.rs:204
   receives Report → push into VecDeque, ack
   receives StreamExhausted → is_exhausted=true
SimExecReporter::peek_next                             sim_reporter.rs:123
   DataReady(seq=(exec_ts, block_seq after delay), ts) or DataNotReady/Exhausted
```

Backtest `run_sync` (`ingress-egress/src/hist_data.rs:1127`) is the heart of the synchronization.
Each loop:

1. optimistic peek of the just-consumed stream + waiting streams,
2. `wait_for_sync_ack` (`hist_data.rs:807`) — spin 1024 iterations then `yield_now`, until egress
   sets the ack flag,
3. re-check waiting streams (this is where the reporter's newly buffered exec report enters the
   heap),
4. pop the earliest heap entry and send it to the engine.

So the exec report is dispatched to the engine *between* the market tick and the next market tick,
at its `T + delay` position:

```
run_sync → process_heap_item → SimExecReport ingress    hist_data.rs:855
└─ engine → component.dispatch_by_route                  component.rs:622 (LogicOnly)
   └─ StratBacktestState::on_sim_exec_report             btest_state.rs:525
      ├─ process_all_account_snapshots (position update through DAG)  btest_state.rs:274
      └─ dispatch_tick_result → next BTestAction or TickProcessed ack  btest_state.rs:334
```

That closes the loop: market tick produces action → delayed report re-enters as a position update →
possibly another action → … until a tick resolves with only `TickProcessed`, which acks the
replayer.

---

## Phase 4 — end of replay and shutdown

```
Arrow provider exhausted (ts >= max_ts) → PeekResult::Exhausted
└─ mark_stream_exhausted → StreamStatusUpdate{Exhausted} ingress   hist_data.rs:713
   └─ StratBacktestState::on_stream_status_update                  btest_state.rs:555
      └─ all_streams_exhausted → send_all_streams_exhausted_msg    btest_state.rs:174
         └─ egress.on_all_streams_exhausted → flush/close, signal reporter, ack  egress.rs:330
            → replayer loop ends → send_completion_message → channel drops
               → mux exits main loop → final ReplayComplete          lib.rs:1279
                  → StratLogicState BacktestReplay arm              strat_logic.rs:196
                     → send shutdown (ingress + control + egress)
                        → engine graceful stop → run_signal_loop exits
                           → shutdown_backtest (watchdog joins, hard timeout)  lib.rs:784
```

The JSONL `--outfile` gets the t=0 baseline snapshot at egress `initialize` (`egress.rs:168`), plus
one record per exec report, and the account-map sidecar is written before boot (`lib.rs:1080`).

---

## Where the Arrow dependency sits (the Databento seam)

Everything file-specific is behind **one trait implementation** and one planning layer:

1. **Provider** — `dsl-runtime/src/hist_data.rs:160` `ArrowFileProvider<T>:
   HistDataStream<DslHistTypeConfig<T>>`. It is the only reader. A Databento historical provider
   implements the same `peek_next`/`pop`/`priority`/`stream_name` surface and can be dropped into
   `hist_replayer.add_stream(...)`.
2. **Planning** — `warehouse::get_btest_hist_data_files` / `get_warmup_hist_data_files` +
   `resolve_file_paths` + `probe_existing_paths` + `venue_for_topic`. This is Arrow-layout- and
   topic-string-specific (hour-aligned filenames, `MdServerTopics` parsing, legacy `<venue>/`
   probing). Databento is request-based (start/stop, symbols, schema), so this layer's shape
   changes, not just its implementation.
3. **The `(subject, payload)` contract** — what `ArrowFileProvider::new` receives as `subject`, and
   what the payload bytes are. `HistTickData.subject` is resolved through `FeedRoutes`
   (`component.rs:440`) and decoded by `FeedCodecs` (`feed.rs:167`), whose market-data arm is the
   **Databento MBP-1 FlatBuffers** codec expecting a `DbnMdUpdate` envelope (resolved instrument id
   + raw DBN record). This is the single most important thing to align.
4. **`min_ts`/`max_ts` semantics** — inclusive lower, exclusive upper (`ts >= max_ts ⇒ Exhausted`),
   reused for both warmup and main phase.
5. **Priority** — `topic → TickDataType → priority` (`topics.rs:198`) orders ties in the merge heap.
   Databento schemas must map onto this.
6. **Not data-source-specific** — `SimExecReporter`, the ack handshake, the egress controller, and
   the state machine are independent of where historical data comes from and stay as-is.

### Open questions / things to confirm

- The replayer streams are built with `subject = <StratTopicManager topic>` (`md.instruments.<id>.
  <kind>`, e.g. `helpers.rs:248`), while `FeedRoutes` is keyed by `feed_topic(&DataFeedRef)`
  (`feeds.fkind_*.fsubj_*…`, `feed.rs:59-79`). Those two naming schemes don't intersect today.
- The strategy declares funding/oracle/spot/book/trade topics, while the Databento feed definition
  (`DATABENTO_MBO_FEED`) only covers MBP-1 book+trade. What supplies funding/oracle/spot in the new
  integration?
- Whether the current mismatch reflects a known in-progress migration state (this was not verified
  by running a backtest).

---

## Databento schemas: MBO, MBP-1, Trades

Question this section answers: can we derive MBP-1 from MBO, and trades from MBO or MBP-1, so we
can store everything in one file instead of one file per schema?

### Library capability: none

`databento` (0.54/0.60 in the local registry) is a client only — historical (`get_range`), live, and
reference — and re-exports `dbn` (`databento-0.60.0/src/lib.rs:29`). Neither crate ships a book
builder or a schema converter.

The only conversions in `dbn` are byte-level:
- `dbn-0.68.0/src/record/conv.rs` — `transmute_record`, `str_to_c_chars`, `ts_to_dt` (raw struct
  casting, not schema transformation).
- `dbn-0.68.0/src/metadata.rs:169` `Metadata::merge` — merges metadata only; it does not synthesize
  records.

Building MBP from MBO is a Databento tutorial you implement yourself. The MBP-10 page says so
directly: *"It is possible to construct MBP-10 yourself from MBO data... Learn how to construct a
limit order book from MBO data from our limit order book construction tutorial."*

### Derivation facts (from Databento docs)

- **MBO** is the L3 superset: *"every order book event across every price level, keyed by its order
  ID... includes all trades, fills, adds, cancels, modifies (or replaces), book clear events"*.
- **Trades**: *"provides every trade event. This is a subset of MBO."* Record rtype is `MBP_0`
  (0), `action` is always `T`, and it carries `depth` (the book level of the trade).
- **MBP-1**: *"provides every order book event that updates the top price level... This includes
  every trade and changes to book depth."*
- **MBP-10**: *"every order book event across the top ten price levels... This includes every
  trade."*

Derivation direction (Databento FAQ *"MBP-1 vs. TBBO vs. BBO schemas"*):

> You can always use MBP-1 and derive the other two schemas.
> - You can derive the TBBO schema by removing any event from the MBP-1 schema that does not have an
>   `action` of `T`, for trades.

TBBO is trade-space (all trades + BBO before the trade), so this confirms **MBP-1 contains every
trade event**, not just top-of-book trades. Therefore:

| From → To | Possible? | How |
|---|---|---|
| MBO → MBP-1 | yes, but manual | maintain a book keyed by `order_id`, aggregate by price |
| MBO → trades | yes | filter `action == T` (also map `F` fill; venues differ) |
| MBP-1 → trades | yes | filter `action == T` |
| trades → MBP-1 | no | trades carry no book state |
| MBP-1 → MBO | no | no order ids, no queue position |

Caveat: reproducing Databento's exact MBP normalization (order counts, two-sided BBO updates where
`side` becomes `N`, venue-specific quirks, synthetic daily snapshot) is non-trivial. Request the
schema you want rather than deriving it.

### One file or one file per schema?

- **API:** `get_range` takes a single `schema`; one request → one schema. Batch jobs likewise.
- **DBN format:** the file header carries one `schema: Option<Schema>`
  (`dbn-0.68.0/src/metadata.rs:38-41`). A DBN stream is single-schema in practice.
- **Mixed files** are technically constructible — `Metadata::merge` sets `schema = None` for
  multi-schema merges, and `RecordRefEnum`/`RecordEnum` can decode mixed rtypes — but the API will
  not produce one, and every reader must dispatch on rtype.

So a file per schema is not required. Store the superset schema that covers the events you need:

| Option | Book | All trades | Note |
|---|---|---|---|
| `trades` | no | yes (rtype 0) | too narrow |
| `mbp-1` | yes (L1) | yes | matches the platform's live contract |
| `mbp-10` | yes (L10) | yes | only if depth needed; changes the pinned 88-byte record |
| `mbo` | yes (L3) | yes | superset, largest; only if queue position needed |

### The platform already commits to MBP-1 as the single schema

This is the decisive point: the existing DBN codec accepts exactly one record type and derives
trades from it by action.

```
data-feed-definitions/rust/crates/codecs/data-feed-codec-dbn-0c63c4bb575d62b5f4552458559baf0d/src/codec.rs
  :18-20    rtypes: only MBP_1 (0x01) is supported
  :109-116  any other rtype -> Rejection::UnknownMessage { tag }
  :135-146  action == Trade -> TradeHandler; otherwise Mbp1BookUpdateHandler
  :136-140  Side::None trades are dropped ([ISS-0B7E5])
```

And the live path subscribes `Schema::Mbp1`
(`databento-mkt-data/rust/crates/databento-mkt-data-server/src/infrastructure/adapters/databento_live_market_data.rs:23`).

Conclusion for the historical provider: emit **one MBP-1 stream per instrument per window**, and
derive trades by filtering `action == T` exactly as the codec does. No file per schema, and MBO is
not needed unless queue position or deeper book is required later.

### Caveats

- **`ts_out` is live-only.** In the `databento` crate it exists only on the live builder
  (`databento-0.60.0/src/live.rs:86`); historical `get_range` has no such parameter, so historical
  records have `ts_out` undefined. The codec requires it — `require_timestamp("ts_out", ...)`
  (`messages.rs:99-101`) and the layout is pinned to `WithTsOut<Mbp1Msg>` (88 bytes). The historical
  provider must synthesize `ts_out` (for example from `ts_recv`) when wrapping records into the
  `DbnMdUpdate` envelope, or the codec contract must be relaxed.
- **Trade depth.** MBP-1 trade messages carry `depth`; the codec ignores it and routes on action
  alone. If deep-book trades ever need distinguishing, the field is present.
- **Ordering.** The feed orders by the DBN `sequence` (`messages.rs:123`), which maps onto the
  replay's `block_seq`/priority ordering. Confirm `sequence` is monotonic per instrument across a
  historical range before relying on it for the merge.
