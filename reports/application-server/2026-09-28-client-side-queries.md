# Client-side ClickHouse queries and how to move them to the application server

Date: 2026-09-28
Scope: `stxr-client-app` (desktop client), `application-server/crates/application-server-core`, `structure-web/packages/api`
Related knowledge base records: ISS-099M8 (Demo Client Queries ClickHouse Directly, open), ISS-0A41N (ClickHouse accepts any source address, open), NOTE-08ZHD (Application Server Core), DEC-0BEKM (Realtime Gateway Authorization Boundary, proposed), DEC-0BBPJ (Client Subscription Architecture, proposed)

Paths in this report are relative to the workspace root. Client paths under `stxr-client-app/src/vs/platform/` are shortened to `platform/...`.

## 1. Summary

- The client sends **8 SQL statements** to ClickHouse, all from the Electron main process:
  - **6 statements from the deployment stack.** They feed the deployment editor, the portfolio pane, live valuation and the agent platform.
  - **2 statements from the log explorer.** They feed the Log Explorer editor, the deployment Logs tab and the agent platform.
- **9 tables are involved:**
  - `account_position_aggregate`
  - `fills`, `demo_fees`, `deposits`, `withdrawals`
  - `event_logs`, read by 3 of the 8 statements
- **Nothing else in the client talks to ClickHouse.** There are no other databases or cloud stores.
- **Two other shared secrets ship with the build** and block distribution just as much:
  - the Databento API key, used for prices;
  - the bundled `demo-user` Solana keypair, so every install signs in as the same user.
- **The ClickHouse password is copied into the app bundle.**
  - The macOS build copies the operator's own `~/.structure/config.json` into the app (`stxr-client-app/build/gulpfile.vscode.ts:433-435`).
  - On first launch the app installs it to `~/.structure/config.json`.
  - The local config leaves `clickhouse.username` unset, so it falls back to `default`.
  - Anyone holding an installed copy can run any SQL that user is allowed to run, against every tenant.
- **Per-user scoping is only a `WHERE` clause the client writes.** Three of the queries have gaps even under that model (section 4).
- **None of the query logic is hard to port.** Each statement is a read keyed by a set of trading accounts or by one owner. The results are converted into semantic objects: canonical ids, scaled decimals, cursors.
- **The valuation math on top of the results should stay in the client for now.** It depends on Databento prices that the client fetches itself.
- **The server side is less ready than it looks for option B (Rust).**
  - `application-server-core` has no ingress or egress yet: both host enums are empty and `drain_egress` is `todo!()`.
  - The Postgres, ClickHouse and HTTP egress consumers in `structure-web` are real and working. They are driven by `ImmediateRuntime` from TS repositories, not by an engine.
- **Recommendation (section 9):** define the contracts once in the shared codec, and have the handler resolve the caller's scope to account ids before any ClickHouse read. Implement the first handlers on the TS side, which already has every piece they need. Move a handler into Rust when there is Rust logic to run on its results, such as server-side valuation. A mixed option that removes the Postgres concern from Rust is described in 9.3.

## 2. How the client reaches ClickHouse today

```
Renderer (editors, portfolio pane, agent platform)
  -> IPC proxy channels "stxrDeployment" / "stxrPortfolio" / "stxrLogs"
  -> Electron main services (StxrDeploymentMainService, StxrLogsMainService, StxrPortfolioMainService)
  -> ClickHouseStxrDeploymentDataProvider  (platform/stxrDeployment/node/clickhouseStxrDeploymentDataProvider.ts)
     ClickHouseStxrLogsAdapter             (platform/stxrLogs/node/stxrLogsAdapter.ts)
  -> POST <clickhouse.url>/?database=..&param_<name>=..   body = SQL text, FORMAT JSON
     headers X-ClickHouse-User / X-ClickHouse-Key
```

| Aspect | Detail |
|---|---|
| **HTTP client** | `globalThis.fetch`; no `@clickhouse/client`. |
| **ClickHouse settings** | `output_format_json_quote_64bit_integers=1`, `prefer_column_name_to_alias=1`. |
| **Value binding** | All values are bound as ClickHouse `{name:Type}` parameters. The one exception is described under L1/L2 in section 3.2. |
| **Config** | `platform/stxrConfig/node/stxrConfiguration.ts:153-176`, read from `~/.structure/config.json`. `database` and `username` default to `default`. There are no environment variable overrides for ClickHouse. |
| **Timeout and retries** | 15 s timeout, no retries. |
| **Errors** | On a non-2xx response, the deployment adapter throws with the raw ClickHouse error body (`clickhouseStxrDeploymentDataProvider.ts:269-272`). That text can reach the renderer and the agent platform. |
| **Caching** | No cache of raw rows. Downstream there are snapshots per deployment, a cached `origin` per deployment, and performance series stores. The stores hold valued points, up to 16,000 per store, and drop them after 5 min idle. |

Where the ids used in the queries come from:

| Input | Source |
|---|---|
| Trading account ids | Application server REST: `listCatalog`, `getAccounts` in `platform/stxrDeployment/node/stxrDeploymentControlAdapter.ts`. A deployment's account set is every account attached to its strategy (`stxrDeploymentService.ts:773-795`). |
| Strategy id, revision id, revision `createTime` | Same REST adapter. |
| Deployment id | **Made up by the client**: `dep_` + an FNV hash of `(strategyId, revisionId)` (`platform/stxrDeployment/node/stxrDeploymentIdProvider.ts:21-29`). It is never sent to ClickHouse and has no server counterpart (client ISSUE-0014). |
| Owner id for logs | `user.getMe` on the application server, converted from the `usr_` id to UInt64 (`stxrLogsMainService.ts:78-93`, `stxrLogsAdapter.ts:391-415`). |
| Valuation asset id | Config `valuation.assetId`. |

## 3. Query catalog

### 3.1 Deployment stack (`clickhouseStxrDeploymentDataProvider.ts`)

The port is `StxrDeploymentDataSource` (`platform/stxrDeployment/node/stxrDeploymentDataSource.ts`).

**D1. Latest positions**

| | |
|---|---|
| Adapter / port | `readLatestPositions` (`:228`) / `readLatestAccountSet`, `readLatest` |
| Tables | `account_position_aggregate` |
| SQL shape | For each `(trading_account_id, subject_kind, subject_id)`, `argMax` by `(effective_time, frontier_orderand)` of: price, quantity, realized PnL, fees, volume, turnover. Filtered by `trading_account_id IN {accountIds}`. |
| Input | account ids |
| Output | `StxrDeploymentLatestPosition[]`: position + `effectiveTimeNanos` |
| Cadence | Every 2 s for each watched account set, plus on snapshot reads |
| Notes | No time bound, so every poll re-aggregates the full history of the accounts. |

**D2. Economic events**

| | |
|---|---|
| Adapter / port | `listEconomicEvents` (`:139`) / `listEconomicEvents`, plus the event half of `readLatestAccountSet` |
| Tables | `fills`, `demo_fees`, `deposits`, `withdrawals` (combined with `UNION ALL`) |
| SQL shape | `event_time` in `[start, end]`, keyset cursor `(event_time, event_id)`, descending, `LIMIT limit+1` |
| Input | account ids, `{start, end, limit ≤ 250, cursor?}` |
| Output | `StxrDeploymentEconomicEventPage` |
| Cadence | On activity table paging; also every 2 s as the poll variant (start at 1970, newest 100) |
| Notes | No `FINAL`, so rows can come back twice; the client removes duplicates by `eventId`. `instrumentId` comes back as a raw UInt64 while asset ids are canonical. The poll variant sorts all history to get the newest 100. |

**D3. Deployment start times**

|                |                                                                                                                                                                                                                            |
|----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Adapter / port | `readStartTimes` (`:237`) / `readStartTimes`, part of `readLatest`                                                                                                                                                         |
| Tables         | `event_logs`                                                                                                                                                                                                               |
| SQL shape      | `count`, `min` and `max` of `event_time` over status-changed events. Filters: `properties['value.strategy_id']` matches, the revision id or version matches, status is `running`, and `event_time >= createTime`.          |
| Input          | strategy id, revision id, `createTime`                                                                                                                                                                                     |
| Output         | `{firstStartedAt, startedAt}` or nulls                                                                                                                                                                                     |
| Cadence        | Every 2 s for each watching deployment. Also runs from `listDeployments` enrichment until a value is cached.                                                                                                               |
| Notes          | **No owner predicate.** It cannot use the table's sort key `(subject_parent_type, subject_parent_id, ...)`, so only the day partition limits the scan. This is the root of client ISSUE-0002 (start-time query times out). |

**D4. Net valuation-asset contributions up to `from`**

| | |
|---|---|
| Adapter / port | `readContributions` (`:179`) / `readContributions` |
| Tables | `deposits FINAL`, `withdrawals FINAL` |
| SQL shape | Sum of signed quantity of the valuation asset with `event_time <= from`, grouped by scale |
| Input | account ids, `from`, valuation asset id |
| Output | exact decimal string |
| Cadence | Per performance window gap, on `origin`, and on live NAV changes |

**D5. Transfers**

| | |
|---|---|
| Adapter / port | `readContributions` (second statement, run in parallel with D4) |
| Tables | `deposits FINAL`, `withdrawals FINAL` |
| SQL shape | Every transfer with `event_time <= to` and (a non-valuation asset, or `event_time > from`). Ordered, **no LIMIT**. |
| Input | account ids, `from`, `to`, valuation asset id |
| Output | `transfers[]` |
| Cadence | Same as D4 |
| Notes | Unbounded: returns every non-valuation-asset transfer since the account began. |

**D6. Position window**

| | |
|---|---|
| Adapter / port | `readPositionWindow` (`:166`) / `readPositionWindow` |
| Tables | `account_position_aggregate` |
| SQL shape | A seed (`argMax` state at `from`) combined with `UNION ALL` with every raw row in `(from, to]`. **No LIMIT**, no `FINAL`. |
| Input | account ids, `from`, `to` |
| Output | `StxrDeploymentPositionWindow {state, transitions}` |
| Cadence | Per chart window or pan gap, per cursor inspect, and per live bar repair |
| Notes | The transition half grows with the window length and account activity. |

`(stxrDeploymentService.ts)` The deployment service turns these into higher-level calls:

| Service call | Queries |
|---|---|
| `getPerformance` / `getPerformanceAt` / `getAccountPerformance` | D6 + D4 + D5 |
| `readLatest` | D1 + D2 + D3 |
| `listEconomicEvents` | D2 |

### 3.2 Log explorer (`platform/stxrLogs/node/stxrLogsAdapter.ts`)

Both statements select every display column from `event_logs`. They are always scoped by `subject_parent_type = 1 AND subject_parent_id = {ownerId}` and take up to 8 structured filter clauses. Each clause has:
- a field from a closed set: `tags`, `subject`, `event`, `trace_id`, `event_id`, `span_id`, `severity`;
- an operator from the set `= ~= > >= < <=`;
- a value, always bound as a parameter.

**L1. Log page (`listLogs`)**

| | |
|---|---|
| Serves | `IStxrLogsService.listLogs`. Callers: the Log Explorer (run, stream, load more), the deployment Logs tab, and the agent tool `platform.logs.list`. |
| SQL shape | Owner + clauses + time range `[start, end]` + optional keyset cursor on `(event_time, event_id, trace_id, span_id)`, `ORDER BY ... asc/desc`, `LIMIT limit+1` |
| Input | `{timeRange (relative or absolute), clauses[≤8], limit 1..250, cursor?, order?}` |
| Output | `{entries, cursor}` |
| Cadence | Per action. The Log Explorer's "Stream Logs" re-runs the whole page every 2 s. Agent code can loop without limit. |

**L2. Log tail (`listLogsNewer`)**

| | |
|---|---|
| Serves | `acquireLogTail` / `onDidAppendLogs`. Only the deployment Logs tab uses it, while it follows the live edge. |
| SQL shape | Owner + clauses + optional keyset `> after`, **no time bound**, `ORDER BY DESC LIMIT 251`. The results are reversed to ascending order. |
| Input | lease id, clauses, `after?` key |
| Output | `{entries, truncated}`, pushed through an event every 2 s |
| Cadence | Every 2 s per held lease |
| Notes | With `after` empty it sorts all of the owner's matching history. The cursor is on `event_time`, so rows that land late (event-gw flushes in batches, and Pub/Sub can be late) are skipped for good. `ingestion_time` / `ingestion_orderand` exist and would make a correct tail cursor. |

### 3.3 Tables, writers and schema notes

- **Writer:** every table above is written by `event-gw`. DDL: `event-gw/crates/db/clickhouse/schema.sql`; shared copy: `timeseries-db/clickhouse/schema.sql`.
- **`account_position_aggregate`:** `ReplacingMergeTree(frontier_orderand)`, ordered by `(trading_account_id, subject_kind, subject_id, effective_time)`. The account filter uses the primary key.
- **`fills`, `demo_fees`, `deposits`, `withdrawals`:** keyed by `trading_account_id` and have **no owner column**. Ownership can only be derived from Postgres, where `users_trading_accounts_connections.trading_account_id` is unique, so each account has exactly one owner.
- **`event_logs`:**
  - ordered by `(subject_parent_type, subject_parent_id, source_type, severity, subject_children, event_time)` and partitioned by day;
  - has no TTL, no skip index and no row policy;
  - receives rows from three writer paths: Pub/Sub `EventLog` envelopes, strategy deployment runtime events, and trading account domain events projected into log rows.

## 4. Security findings that shape the contracts

In order of impact:

1. **Shared credential in the bundle** (`build/gulpfile.vscode.ts:433-435`, `scripts/release-internal-demo-macos.sh:63,71-80,208-212`, `docs/internal-demo-release-process.md:86-91,144-148`).
   - The ClickHouse URL and password ship in every macOS build.
   - With them, anyone can read every tenant's fills, transfers, positions and logs, including System-scoped infrastructure log rows.
   - Whether the `default` user is read-only cannot be seen from the repo. ISS-0A41N notes the service accepts any source address.
   - **Rotating the password is required once the client stops needing it.**
2. **Account-scoped queries trust account ids from the renderer.**
   - `getAccountPerformance` and `acquireLiveValuation({scope: {kind: 'accounts'}})` accept any account ids over IPC. They only check the format (`stxrDeploymentService.ts:613-615,1214-1222`).
   - Deployment-scoped calls take ids from the REST API, so they are only as scoped as that API is.
3. **D3 has no owner filter.** It reads status events for any `strategyId`. The schema comment on `event_logs` says ownership must always be enforced (`schema.sql:421-422`).
4. **SQL injection through the severity operator in L1/L2.**
   - `validateClause` restricts operators for every field except `severity` (`stxrLogsAdapter.ts:302`).
   - For severity, the operator string is pasted into the SQL text (`stxrLogsAdapter.ts:245`).
   - `ProxyChannel` forwards whatever the renderer sends, so an operator such as `= 0 OR 1=1 OR severity =` removes the owner filter.
   - The agent platform does check operators against an allowlist (`platform/stxrAgent/common/stxrAgentPlatformLogs.ts:111-112`). A compromised renderer or DevTools can still reach the channel.
   - Moving the query server-side with a closed operator enum in the codec fixes this by construction.
5. **The client shows more log rows than the server allows.** L1/L2 return every `source_type`. The existing server endpoint `GET /api/v0/logs` allows only `Webserver` and `Strategy`, with the comment "do not leak internal infra details" (`structure-web/packages/api/src/logs/logs-service.ts:16-17,46`).
6. **Unsigned cursors.** The client log cursor is base64url JSON. The server version signs its cursor (`logs-repository.ts:683-725`).

Other shared secrets that ship with the build. They are not ClickHouse, but they block distribution the same way:

| Secret | Where | Use |
|---|---|---|
| Databento API key | `marketData.databento.apiKey`, passed to the client-core WASM `PriceEngine` (`platform/stxrPrice/electron-main/stxrPriceMainService.ts:58-65,280-283`) | All prices, charts and valuation. The client connects directly to `hist.databento.com` and to `<dataset>.lsg.databento.com:13000`. Accepted for the internal demo only (client `SPEC-client-price-service.md` D-11). |
| `demo-user` / `devnet` Solana keypairs | `platform/stxrAuth/node/assets/*.json`, **committed to git** and bundled | SIWS sign-in. Every install signs in as the same wallet, so per-user scoping on the server does not separate users until this changes. |

Not a concern:
- **Market info:** bundled `client/market-info.rkyv`, local only.
- **Backtest DuckDB queries:** local read-only files. Today this is a hard-coded developer path in `stxr-client-app/src/vs/code/electron-main/app.ts:1224`, which will fail on a user machine. The intended source is the application server download.
- **Local chDB worker:** no remote access.

## 5. Logic that runs on the query results

| Logic | Where today | Where it belongs |
|---|---|---|
| Id conversion (Crockford Base32 to UInt64 and back), scaled-integer checks, timestamp normalisation, splitting the window into state and transitions, exact sums per scale, paging cursor with `limit+1` | client adapter | **Server**, as part of the codec and handler. Responses carry canonical ids, exact decimals and opaque signed cursors. |
| Resolving a deployment's account set (strategy to attached accounts) and the `dep_` id | `stxrDeploymentService.ts:760-851`, `stxrDeploymentIdProvider.ts` | **Server.** The handler resolves and authorizes the scope itself. |
| Start time derivation (first and latest `running` event, fallback to `updateTime`) | `stxrDeploymentService.ts:883-931` | **Server.** Better still, store `firstStartedAt` / `startedAt` on the deployment row, which removes D3. |
| Poll gating, dormancy, lifecycle probe | `stxrDeploymentDataSource.ts`, `stxrLiveValuationHub.ts` | **Server push, later.** The port is already shaped for it: "Polling and a future WebSocket source both deliver the same batches" (`stxrDeploymentDataSource.ts:129-132`). |
| Snapshot merge (newest 250 events deduplicated, latest position per key) | `stxrDeploymentService.ts:916-950,1039-1076` | **Client** view state. |
| Valuation: contributions valued at each transfer's price, replaying transitions, NAV change detection, `valuePoints` via client-core WASM, `origin`, series stores, live hub | `performance/*`, `stxrLiveValuationHub.ts` | **Client for now.** It needs the prices the client gets from Databento. It moves server-side only together with prices. This is where Rust would pay off, since NOTE-08ZHD wants to reuse the Rust portfolio trackers. |

## 6. Proposed service contracts

Each contract names a scope, not raw account ids. The handler resolves the scope against the caller's identity before touching ClickHouse. The contracts are written as semantic requests and responses. The codec (protobuf or FlatBuffers, whichever the handler work settles on) owns the wire form.

```
Scope      = Deployment(deployment_id) | TradingAccounts(account_ids[]) | AllOwnedAccounts(environment)
TimeWindow = { from: Timestamp, to: Timestamp }
```

| Service | Request | Response | Replaces | Postgres needs | ClickHouse |
|---|---|---|---|---|---|
| `DeploymentPositions.latest` | scope | positions + `effective_time` per key | D1 | scope to owned account ids | D1 |
| `DeploymentPositions.window` | scope, window | `{state, transitions}` (needs a row limit or a chunked stream) | D6 | same | D6 |
| `EconomicEvents.list` | scope, window, limit, cursor | page of fills, fees, deposits and withdrawals with canonical ids | D2 | same | D2 |
| `Contributions.read` | scope, window, valuation asset | net valuation-asset amount at `from` + transfers | D4, D5 | same | D4, D5 |
| `Deployments.startTimes` | deployment id | `{first_started_at, started_at}` | D3 | deployment to strategy and revision, ownership | D3 with an owner predicate, or none if stored in Postgres |
| `Logs.page` | time range, clauses (closed enums), limit, order, cursor | entries + signed cursor | L1 | none beyond the caller id | L1 with owner predicate and allowed source types |
| `Logs.tail` | clauses, after key | entries, truncated | L2 | same | L2, cursor on `ingestion_orderand` |

Contract decisions this forces, needed whichever language implements it:

- **Deployment identity.**
  - The client-made `dep_` id has no server counterpart.
  - `strategy_deployments.id` in Postgres is a 16-byte hash with no strategy, revision or user columns.
  - ClickHouse uses a `UInt64` `strategy_deployment_id`. NOTE-09412, ISS-0AGTK and ISS-08ZTF track this.
  - **Until it is settled, a deployment scope has to be `(strategy_id, revision_id)`.**
- **Unbounded reads.** D5, D6 and the empty-cursor L2 need a limit, a chunked response or a server-side aggregate before a shared server runs them for every client.
- **Polling cost.** D1 and the D2 poll variant re-scan full history every 2 s for each client. Moving them server-side unchanged moves the load onto shared infrastructure. A bounded "changed since" query, or push from the event pipeline, should replace them. This affects the design more than the choice of language does.
- **Log filter grammar.**
  - The client uses structured clauses; the existing `/api/v0/logs` uses a free-text filter parsed on the server.
  - Pick one. Structured clauses with closed enums fit a codec contract and remove the injection class.

## 7. What exists on the server side

### 7.1 application-server-core (Rust, WASM)

| Part | State |
|---|---|
| Build | `wasm-bindgen` + `wasm-pack --target web`, loaded by structure-web at `packages/api/src/app/init.ts:15-48` |
| Host enums | `ApplicationServerHostIngress {}` and `ApplicationServerHostEgress {}` are empty (`src/generated/engine/ApplicationServerHost.rs:3,11`). `ApplicationServerComponent` has no subscriptions. |
| Moving data out | `drain_egress` is `todo!("take the shared buffer and use the zero-copy format")` (`src/wasm.rs:57-59`) |
| Moving data in | No method accepts ingress messages |
| What it does today | Market info lookups (instrument and asset supported) and `FeedEncoder` (JSON domain event to validated protobuf). Values cross as JSON via `serde_wasm_bindgen`, with u64 as strings. |
| Postgres | Not visible to Rust at all |

The `on_feed_msg` handler pattern exists in `event-gw` and `sim-gw`. For example:
1. `event-gw/crates/event-gw/src/handler.rs:111-136` receives the message.
2. `FeedCodecs::consume` decodes it.
3. The typed handler (`FillHandler`) works on the semantic `Fill` trait.
4. The state logic emits a `ClickHouseInsertRequest` egress.
5. `clickhouse_writer.rs` performs the insert and returns the response as ingress with a `CorrelationId`.

Egress kinds that exist in Rust: ClickHouse insert (event-gw only), HTTP, NATS, Pub/Sub, QUIC, alerts, timers, DuckDB. **There is no Rust Postgres egress and no Rust ClickHouse query egress.**

### 7.2 structure-web (TS)

- **Wiring:** `packages/api/src/run.ts:221-245` creates:
  - `NodePgEgressConsumer`
  - `ClickhouseEgressConsumer` (`@clickhouse/client`, `JSONEachRow`)
  - `HttpClientEgressConsumer`
  - all behind `ImmediateRuntime`, with the comment `// todo: should be an engine runtime`.
- **Dispatch:** `makeRuntimeHandler` (`run.ts:496-542`) switches on the message kind: `stxr.pg_client.*`, `stxr.clickhouse_client.query`, `stxr.http_client.*`.
- **`txs` map:** holds pinned Postgres transaction clients (`app-db/client/node-pg-egress-consumer.ts:35-58`). It is not request correlation; correlation is `IPC.Message.correlation_id`.
- **Execution:** `ImmediateRuntime.execute` calls the consumer in the same async call. Requests and responses are plain JS objects validated with zod, with no serialization.
- **Engine-shaped entry points exist but are unused:** each consumer's `handleMsg` / `initialize`, `EngineRuntime` in `runtime/ts`, and `ts-core` `Engine` / `EgressManager`.
- **Existing server-side ClickHouse reads:**
  - `GET /api/v0/logs`: user-scoped, allowed source types, signed cursor. Time bounds are `timestamp` clauses in the filter expression. It lacks ascending order and a tail. The client's generated SDK already has the operation (`Logs.listLogs`).
  - `GET /api/v0/positions`: internal, API-key only, reads `position_updates`, not `account_position_aggregate`.
- **Shared row schemas:** `timeseries-db/src/schema.ts` (zod) and `timeseries-db/src/schema.rs` (`clickhouse::Row`).
- **Ownership in Postgres (`packages/app-db/src/schema.ts`):**
  - Tables: `users_trading_accounts_connections`, `user_strategies_connections`, `strategies_trading_accounts_connections`.
  - Repository checks: `TradingAccountRepository.getUserTradingAccount`, `StrategyRepository.getByUser`.
  - There are no org, group or role tables; authorization means "the user owns the row".

### 7.3 Transport to the client

- **Only HTTP REST exists today:** the hey-api SDK from `application-server-client/ts`, with a Bearer ID token.
- **Two non-HTTP routes exist but carry nothing:**
  - the structure-web websocket route map (`packages/api/src/app/ws-server.ts`, registered empty at `run.ts:442`);
  - realtime-gateway `ClientRequest{route, payload}`, whose `RequestDispatcherRegistry` has no routes.
- **Transport is out of scope for this task**, but both options depend on it. DEC-0BEKM proposes realtime-gateway as the single public authorization boundary.

## 8. Option A (TS services) vs option B (Rust services)

| Need | A: TS handlers in structure-web | B: Rust handlers in application-server-core |
|---|---|---|
| ClickHouse query path | Exists (`ClickhouseClient` → runtime → `ClickhouseEgressConsumer`) | Missing: egress and ingress variants, a working `drain_egress`, an ingress entry point in WASM, and a TS loop that sends drained requests to the consumers and returns their responses |
| Postgres ownership check | Exists as repository calls | Missing: a Postgres egress contract. SQL is built by Drizzle in TS today, so Rust would either write its own SQL or ask TS for named lookups |
| Row decoding | zod `jsonTable` rows exist | `clickhouse::Row` structs exist, but they expect RowBinary. Rows come back as JSONEachRow JS objects, so they would be decoded in JS and then converted again to cross into WASM |
| Request shape per call | One async function | A state machine per request: request in → Postgres egress → response in → ClickHouse egress → response in → reply out. Four WASM boundary crossings per request |
| Serialization cost | None inside the process | JSON through `serde_wasm_bindgen` on every crossing, since the zero-copy buffer is not implemented |
| Codec and handler structure | Can follow the same shape: the codec decodes the request, and the handler works with semantic objects and calls repositories through the runtime | Native fit with the `on_feed_msg` pattern |
| Reuse for later server-side valuation | None; the valuation code is Rust (client-core) | High: the same host could run the valuation and portfolio trackers next to the queries (NOTE-08ZHD) |
| Missing in both | Transport to the client, a deployment identity link, bounded or push versions of the polled queries | Same |

## 9. Recommendation

### 9.1 Contracts first, in the shared codec

Define the requests and responses from section 6 in the codec the handler work uses, not as TS types or Rust structs. That keeps the choice of language per handler open. Fix these at the contract level:
- the scope type, resolved on the server;
- closed enums for log fields and operators;
- signed opaque cursors;
- canonical ids;
- row limits on every response.

### 9.2 First handlers on the TS side

- The eight statements are thin reads with an ownership check. The only non-trivial work is converting ids and decimals, and that becomes codec work.
- Every piece the TS side needs is already running: Postgres ownership repositories, a ClickHouse egress consumer, zod row schemas, and a user-scoped logs repository to extend.
- Structure the TS handler like the Rust one: the codec decodes the request, and the handler takes a semantic request plus the caller's actor, resolves the scope and calls repositories through `rt.execute`. Porting it later is then a change of language, not of design.

### 9.3 A mixed option if the handlers must be Rust now

- TS authorizes and resolves the scope to owned account ids before calling into the engine. The Rust request then carries a resolved account set, not a user.
- This removes Postgres from Rust entirely. Rust still needs a ClickHouse query egress and the WASM ingress and egress plumbing.
- To avoid decoding rows twice, the ClickHouse egress could return `RowBinary` bytes for Rust to decode with the existing `clickhouse::Row` structs.

### 9.4 When to move into Rust

When the server takes over valuation. That needs server-side prices, which also removes the shipped Databento key. At that point the engine plumbing pays for itself: the positions, transfers and prices that feed valuation all flow through the same host, and push-based updates replace the 2 s polls.

### 9.5 Needed whichever option is chosen

- Stop bundling `~/.structure/config.json` into the build. Then rotate the ClickHouse password, create per-service read-only users, and close the IP allowlist (ISS-0A41N).
- Replace the shared `demo-user` keypair with per-user sign-in. Without it, server-side scoping still sees one user.
- Store deployment start times on the deployment (removes D3), and settle the deployment id link.

## 10. Open questions

1. Which ClickHouse user and grants does the shipped demo config use? The config file is not committed.
2. Is `/api/v0/logs` meant to become the single log contract? If so, the structured-clause versus free-text filter choice has to be made before the codec contract is written.
3. Should the portfolio's `AllOwnedAccounts` scope include accounts not attached to any strategy? The client queries these as "unallocated" today (`stxrPortfolioMainService.ts:120-133`).
4. Which rows do strategy revision status events carry in `subject_parent_*`? This decides whether D3 can take an owner predicate or has to move to Postgres. Not checked.
5. Will the transport be realtime-gateway (DEC-0BEKM) or the structure-web websocket? This decides where the caller's identity comes from when the handler runs.
