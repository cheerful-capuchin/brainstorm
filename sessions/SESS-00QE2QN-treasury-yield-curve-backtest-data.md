---
create_time: 2026-10-12T11:26:45Z
title: "Treasury futures data since 2010 for the yield curve backtest"
summary: "Yield curve backtest: OHLCV-1m since 2010-06-06 for ZT, ZF, ZN, ZB, UB, TN, ES, GC, CL, ZC, ZS. Download job already resolves CME ids per day by contract (security id reuse safe). Measured Treasuries ohlcv-1m: $0, 1.67 GB, 29.9M bars. Gap: Sep 2026 Treasury contracts missing on marked days 2026-08-01..09-21. Decided: done per contract (object exists) instead of day markers (D1); 11 products (D2); separate backfill Cloud Run job with ohlcv-1m + product filter, deployed via Pulumi (D3); local driver program run by the agent (D4). Backfill finished 2026-10-13 02:20 UTC and verified against the bucket (1,059 contracts, 0 missing days). Client 401bb1d ships the new archive."
related_sessions:
  - SESS-00PYCE2
  - SESS-00PXT2F
---

# SESS-00QE2QN: Treasury futures data since 2010 for the yield curve backtest

## Context (user, 2026-10-12)

- Goal: backtest the yield curve strategy on Treasury futures from 2010.
  Products ZT, ZF, ZN, ZB, UB, TN. Data: OHLCV-1m bars.
- To download market data into the bucket, the security definitions and
  market info must exist in the market-info repo (`market-info/assets`).
- Earlier the same day (separate conversation, uncommitted): market-info
  `cme-market-info-gen` gained `cme-databento-backfill`, which writes the
  expired contracts from Databento definitions (dataset starts 2010-06-06).
  TN before 2016 is a different product (TNX0); user said skip it.
- Prompt: `prompts/yeild-curve-strategy/2026-10-12-mkt-info.md`.

## Q1: does the download job resolve our instrument id from the CME security id?

User asked to double check, because CME reuses security ids across
contracts and products. Answer: no, it does not. Findings in
`databento-mkt-data/rust/crates/databento-mkt-data-download-job` (main,
bc63735) and `databento-cme-globex`:

- `core/resolve.rs` `resolve_day`: per UTC day `D`, request A asks
  Databento for the definitions of the wanted markets' venue symbols over
  `[D, D+1)`; request B asks for the ids A found, same day. Records are
  folded in receive order into a fresh `ContractTable` per day.
- `ContractTable::apply` binds an id to a market by
  `DefinedContract { venue, product_code (Databento asset), maturity }`,
  not by symbol and not by id. Decade twins (ZNZ0 = 2010 and 2020) are
  distinct contracts.
- market-info's `security_id` on `WantedMarket` is only compared to
  Databento's id to log `download_job.resolve.market_info_stale`; the
  record's id is used.
- The day is rejected (no marker, retried next run) when an id names a
  second contract within the day (`InstrumentIdRemapped`), when one
  contract has two ids, when Databento's expiration is not market-info's
  trading termination, or when an outright future of a requested symbol is
  no wanted market's contract.
- `core/batch.rs` `job_request` submits the union of ids over a day range
  (stype_in instrument_id, split per symbol+day). `core/transfer.rs` reads
  each file's DBN header (one id, one UTC day) and looks up `(id, day)` in
  per day tables (`FileTargets::lookup`). A file whose id names another
  contract that day is `not_wanted` and dropped. Objects are named by our
  `InstrumentId`.
- `fill_empty.rs` re-runs `resolve_day` on the stored marker (request A
  only) to get the day's ids; only days that already passed resolution have
  markers.
- `ohlcv-1m` is in `KNOWN_SCHEMAS` and accepted by the config.

One place assumes unique ids: `bin/costs.rs` `costs grid` bails on
"duplicate CME security id" across the whole archive. With 16 years of
Treasury contracts in market-info that check may fire. `costs backfill`
(quotes by venue symbol over the range) has no such check and is the one
to use for the size and cost estimate. Not changed; user not asked yet.

No code changes in this session so far.

## Q2: how to download OHLCV-1m for 16 years and 10 product codes

User now says 10 product codes (the other 4 not named yet). Findings, no
decisions yet:

- Measured: Databento for the 240 Treasury venue symbols in market-info
  (368 contracts, decade twins share a symbol), ohlcv-1m, 2010-06-06 to
  2026-10-12: cost $0 on our plan, billable 1,674,020,152 bytes
  uncompressed, 29,893,217 bars. Stored files are zstd, so smaller.
- Bucket (`stxr-prop-asia-historical-data-qmdzj/data/databento/GLBX.MDP3`):
  ohlcv-1m markers only for 2026-08-01..2026-10-10 (71 days).
- Gap found: the September 2026 contracts (ZTU6, ZFU6, ZNU6, ZBU6, UBU6,
  TNU6) are new in the uncommitted backfill; ZNU6 has no objects at all,
  yet 2026-08-01..2026-09-21 are marked in every schema, so the job never
  downloads them. Needs `--overwrite=always` over those days (or deleting
  those markers).
- Production config (infra `download-job.ts`) selects every CME Group
  future by venue + instrument type (no product filter) and downloads 6
  schemas. A 2010.. run on it would fetch MBP-1, ohlcv-1s etc. for every
  backfilled contract, and every other market back to its activation (NG
  from 2013). Proposed: an optional product code filter in
  `mkt_info_query` plus a second, ohlcv-1m only config object in Pulumi,
  passed with `gcloud run jobs execute --update-env-vars=CONFIG_PATH=...`.
- Consequence to tell the user: markers are per (day, schema), so a subset
  run's markers mean "done for the selected markets"; other markets added
  later for those days need `--overwrite=always`.
- Batch request = union of a task's ids over its whole block; with id
  reuse, a long block requests unrelated instruments that reuse an id
  (generated, then dropped as not_wanted). Keep blocks to about a week per
  task (infra doc); JOB_REUSE_LOOKBACK is 30 days, so rerun within that.
- market-info archive reaches the job through infra
  `config.marketInfo.revision` (githubFileAsset of assets/market-info.rkyv);
  the backfill must be merged and the pin bumped first.

## Q3: product scoped "done", a new backfill job, no manual executions

User asked whether "done" can be product specific and how that affects the
current job. User approved deploying a new job with a config that has the
product code filter. User does not want to run `gcloud run jobs execute` by
hand: an agent or a program should drive it and report "done" at the end.

Analysis given (no decision yet):

- Product scoped markers would not fix the ZNU6 case: ZN days were already
  marked through ZNZ6, so a contract added late to a known product is
  still skipped.
- Proposed instead: done per (market, schema, day) = its object exists.
  Since DEC-0BPWJ R6 every market listed on a marked day gets an object
  (data or header only), and uploads commit only after the SHA-256/CRC32C
  check, so an object existing means that market's day is complete.
  Planning lists each listed market's objects
  (`ObjectListing::for_instrument_days`, as fill-empty-days does).
- Effects on the scheduled job: ~1,000 listings per run instead of 6
  (about 180 CME futures listed in a 7 day window x 6 schemas); markers
  stop deciding anything; days marked before R6 and late contracts are
  filled by the job itself, so fill-empty-days is no longer needed; a batch
  asks only for the missing markets' ids; the single writer rule goes away
  (create-only uploads), so a backfill job and the scheduled job can share
  days; overdue alert text unchanged; DEC-0BPWJ R4/R6 need a revision (KB
  not edited).
- The strategy replay reads only the per instrument objects, not markers
  (`hist_replay.rs` maps Definition to None).
- Driver options: a local program that runs `gcloud run jobs execute
  --wait` per range block with the job's `--wait`, reruns until nothing is
  left, prints done (agent runs it in the background); or a Cloud
  Scheduler on the backfill job plus a "range complete" log line alerted
  to Discord.

## Decisions (user, 2026-10-12)

- D1. "Done" is per contract: a (market, schema, day) is done when its
  object exists. Chosen over product scoped markers because it also covers
  contracts added late to a product already downloaded (the ZNU6 case).
  Day markers no longer decide what to download.
- D2. Products for the backfill: ZT, ZF, ZN, ZB, UB, TN, ES, GC, CL, ZC,
  ZS (11 codes; the earlier "10" was approximate). Schema: ohlcv-1m.
  Range: from 2010-06-06 (Databento GLBX.MDP3 start). TN before 2016 stays
  skipped (different product, see Context).
- D3. A separate backfill Cloud Run job, deployed by the agent through
  Pulumi, with its own config: ohlcv-1m only and a product code filter in
  `mkt_info_query`. The scheduled job keeps its config.
- D4. Driver: a local program the agent runs in the background. It runs
  the backfill job per block of days, reruns until nothing is missing, and
  reports "done". Rejected: Cloud Scheduler plus a Discord "range complete"
  alert; user prefers the local program run by the agent.

## Implementation (2026-10-12, in progress)

User answers: do not push market-info (user is not finished with it; the
`.cargo/config.toml` patches build the job against the local market-info);
fix the job, write the driver, commit, open a PR; do not build the image
yet (so no deploy yet).

- databento-mkt-data branch: product filter `mkt_info_query.product_codes`,
  per contract planning, markers and fill-empty-days removed (subagent).
- Driver: `bin/backfill.rs` in the download job crate, `just backfill
  <start> <end> <project>`. One execution over the whole range per attempt
  (tasks = ceil(days / 31), each task `--wait`), polls `gcloud run jobs
  executions describe`, done when every task succeeded and logged
  `download_job.dataset.done outcome=nothing_to_do|no_days_owned`;
  otherwise prints `[ERROR]` lines and reruns, at most 5 executions.
  2010-06-06..2026-10-12 = 5,972 days = 193 tasks.
- infra branch `databento-backfill-job`: `infra/services/databento/
  backfill-job.ts`, job `databento-backfill-job`, same image pin, service
  account and shared market-info archive as the download job, config with
  the 11 product codes and `schemas: [ohlcv-1m]`, no scheduler, no alerts,
  maxRetries 1. Not deployed. Deploy order later: market-info merged and
  `market_info:revision` bumped, job image built from the merged code and
  pinned, then `pulumi up`, then `just backfill`.

## PRs (2026-10-12)

- stxr-prop/databento-mkt-data#6 (branch `per-contract-done-backfill`,
  6282881): done per object, markers and fill-empty-days removed,
  `product_codes`, `backfill` program + `just backfill`. `just check`
  passes (65 job tests, 3 backfill tests).
- stxr-prop/infra#32 (branch `databento-backfill-job`, 51253b4): backfill
  job + config, download-job.ts comments. Typecheck, lint, fmt pass.
- Hazard: the image on main has no `deny_unknown_fields`, so it would
  ignore `product_codes` and download ohlcv-1m for every CME future. The
  backfill job must not run before the image from #6 is pinned.
- Untested: `gcloud run jobs execute --format=json` returning the execution
  (driver reads `metadata.name`); describe and logging reads were checked
  against a real execution.
- Remaining, in order: user finishes and merges market-info; bump
  `market_info:revision`; merge #6, build and pin the job image (also moves
  the scheduled job to done per object); merge infra#32 and `pulumi up`;
  agent runs `just backfill 2010-06-06 2026-10-12 stxr-prop` in the
  background and reports done. DEC-0BPWJ needs a revision (KB not edited).

## D5: product codes are a selection (user, 2026-10-12)

User: the product codes in the query should follow the strategy logging
policy idea (an enum of all / none / included / excluded); an optional list
is too binary. Done: `ProductSelection { All, None, Only, AllExcept }` in
the job's plan module; config `mkt_info_query.product_codes` is required and
written like the logging policy's `Selection`: `all`, `none`,
`{ only: [..] }`, `{ all_except: [..] }`. Invalid code fails the parse;
empty list or duplicate is a validation error. Non-futures have no product
code: only `all` and `all_except` select them.
- databento-mkt-data#6: 394fc95. `just check` passes.
- infra#32: 7f918f0; scheduled job config `product_codes: all`, backfill
  `{ only: [..] }`. The new image refuses a config without the key, so the
  image pin and infra#32 must go out together.
- market-info: user merged #28 (16716b6, "CME market info history: expired
  futures and trading schedules since 2010") with all 11 products. Next:
  bump `market_info:revision` to it, then the image and deploy steps.

## market-info revision bump (user asked, 2026-10-12)

User: update the market info revision myself; wants the end to end change
in 2 PRs (databento-mkt-data#6 and infra#32).
- infra#32 ead1c3a: production `market_info:revision` 480d1b5 -> 16716b6.
  Archive: 707 -> 1,721 markets (1,179 futures); no archive type changed,
  0 instrument ids changed or removed; schedule ids of existing markets
  changed (regenerated schedules).
- sim-gw and event-gw `markets_max` 1024 -> 4096: they size each kind's
  store from it and refuse to start when the archive holds more of a kind
  (1,179 futures). Other consumers (strategy runtime, target executor,
  dsl-runtime) size from the archive; mkt-data-server and the download
  jobs already 4096.
- Dev stack pin left alone (it was already on another revision).
- Still not in a PR: the job image digest pin; needs an image built from
  #6 (user said not to build yet).

## D6: no waiting for Databento (user, 2026-10-12)

User: tasks should not wait for Databento; schedule the batch jobs, rerun
about 15 minutes later and download what is ready. Waiting wastes Cloud Run
CPU and money. Done:
- databento-mkt-data#6 6eb3346: `backfill` runs rounds without `--wait`
  (one execution per round, sleep 15 min locally between rounds); done when
  every task logs nothing_to_do/no_days_owned; gives up after `--hours-max`
  48 or `--stalled-rounds-max` 4 rounds with failed tasks and no task newly
  done. Batch jobs are reused by the job's covering-job lookup (30 days).
- infra#32 2f5349a: backfill task timeout 6h -> 1h, comments updated.
- User merged databento-mkt-data#6 at 16:39 UTC (de6ac00) with 6282881 and
  394fc95 only; the no-wait commit came after the merge. Reopened as
  databento-mkt-data#7 (branch `backfill-no-wait`, a67eba4).
- 2026-10-12 16:50 UTC: #7 re-signed (85f9274) and merged on user request
  (78bcba5). databento-mkt-data main now has the whole job change.
- 2026-10-12: user merged infra#32 (be34402). Image built with `just bake
  databento-mkt-data-download-job` from databento-mkt-data 78bcba5 (label
  checked): sha256:6e7bdf6bc3438d3d49b7b6d54fcbad468facfe3d5ff76c34cfccc378a8bc7b39,
  pinned in infra main 8034c94 (signed, pushed directly per user). Local
  `repos` was on dec-0bzbc branch (only docs/tests differ from main) and
  messaging's msg-schemas at its upstream main. Not deployed yet: next
  `pulumi preview`/`up`, then `just backfill 2010-06-06 2026-10-12 stxr-prop`.

## Backfill run (2026-10-12)

- Deploy verified: both jobs on image 6e7bdf6b, configs as written, archive
  md5 = market-info 16716b6, event-gw/target-exec/sim-gw loaded 1,721
  markets (sim-gw rollout overlap lost no state).
- Driver fixes found by the real run: `--args=` must be one token (3542e99
  on main); one job run accepts at most MAX_WINDOW_DAY_COUNT 3,660 days, so
  the driver splits into windows (databento-mkt-data#8, branch
  `backfill-windows`, run from the branch, not merged yet).
- Running: windows [2010-06-06, 2020-06-11) 118 tasks and
  [2020-06-11, 2026-10-12) 75 tasks; 1,059 markets selected; ~146-161
  contracts listed per day. Log /tmp/backfill/run.log.

## Expiration corrections (2026-10-12)

- Round 1 rejected 400+ days: CME corrected ZNZ1/UBZ1 (and ZBZ1, ZNM2)
  expirations by a day weeks after listing; market-info kept the first
  Databento definition; the job rejected whole days on any mismatch.
- User: (1) fix market-info, commit, sign, push to main. Done: market-info
  67e95a8 (pushed) takes every fact from a contract's last complete
  definition; 13 files changed: the 4 terminations, plus activations /
  security ids of contracts withdrawn and relisted (ZN/ZF/ZT Dec 2016, ZS
  May 2013), corrected activations (UB Jun 2011, GC Sep 2011, the latter
  uncertain), ZT 2019 ticks 1/128 -> 1/256. Instrument ids unchanged.
  Infra pin bumped on main f46097c (not deployed).
- User: (2) expiration difference is a warning with a specific event that
  alerts in Google, and it must be obvious in code which events are
  alerted (a table/tag, not a comment). Done in databento-mkt-data#9
  (`AlertedEvent` enum; download_job.failed_permanently replaces
  `failed retryability=permanent`; live server keeps publishing) and
  infra#33 (`ALERTED_EVENTS` table, one policy per entry).
- User asked to export the table for infra; started (uncommitted on #9
  branch): `alerted-events.json` + `just alerted-events` + golden test, and
  a pinned GitHub read in infra planned. Then user asked whether the file
  can be generated from every log event at compile time (logger2 macros
  know the format strings). Open question, see answer.
- User: file name `program-events.json`, JSON unless something clearly
  better. Asked how to record in wasm: `inventory` 0.3.25 supports all wasm
  targets via constructors (docs.rs); `linkme` 0.3.37 lists no wasm. User
  asked for a separate design agent: goal = every event emitted through the
  logger collected into a structured human + machine readable file, to
  inspect emitted events and build on it (alerts first). Design agent
  started (read only), report pending. The uncommitted alerted-events.json
  export on the #9 branch is on hold.
- Design done: `reports/logger2/2026-10-12-program-events-design.md`.
  Recommends a linkme registry behind a dev-only `program-events` logger2
  feature (native only; inventory >= 0.3.24 fallback), event = leading
  dotted snake_case name, `log_alert!` + doc comment + `#[alert(..)]` as
  the alert marker and metadata, golden-test generated
  `program-events.json`, infra reads it at the image's source revision and
  builds policies with an anchored textPayload regex. 9 decisions open.

## D7: program events (user, 2026-10-12)

- User: notification rate is infrastructure specific and does not belong in
  code (no `#[alert(..)]`); accepted the other design recommendations
  (linkme registry, dev-only feature, native only; event identity; doc
  comment required on log_alert!/log_emergency!; anchored textPayload
  filter; policy names from event + aliases; duplicates allowed unless
  alerted; production revision for all stages; #9/#33 superseded by the
  full implementation, user redeploys once).
- Two agents started: logger2 `program-events` branch + download job
  migration on `expiration-differs-alert`; infra on `databento-alerted-events`
  (program-events.ts, githubFileContent, revision next to the digest,
  notification rate overrides table in infra, aliases).
- Round 1 also rejected GCX1 (Nov 2021): Databento 17:30 UTC vs market-info
  18:30 UTC (day after Thanksgiving early close); covered by the warning.
- Implemented: logger2#13 (branch `program-events`, 2aa6491; linkme
  0.3.37 spike passed on macOS + Linux; doc comment required on
  log_alert!/log_emergency!, no #[alert]; `in_cfg_test` dropped because
  main.rs is cfg(test) in the binary's test build); databento-mkt-data#9
  updated (d16145f: three log_alert! sites, AlertedEvent deleted,
  program-events.json with 72 events incl. linked crates; file goes stale
  when linked crates' log lines change); infra#33 (ede85f0:
  program-events.ts, githubFileContent, DATABENTO_MKT_DATA_DOWNLOAD_JOB_RELEASE
  {digest, revision}, ALERT_DEPLOYMENTS rates/notes/aliases, bun tests).
  Merge order: logger2#13, then databento#9, infra#33.
- Coverage snapshot shared 18:40 UTC (mid backfill, ~2% days complete).
  Found: ES Mar 2027 / ZB Dec 2026 entered market-info ~2026-10-09/10;
  old marker job never fetched earlier days; other products (NQ, SR3, ...)
  likely have the same gap before ~2026-10-09 (outside backfill scope).

## Batch job reuse bug (2026-10-12 ~19:30 UTC)

- Round 2 downloaded nothing: Databento's `batch.list_jobs` now returns only
  id/state/ts_received (full details deprecated since databento 0.60), and
  the job fetches `get_job_details` for only the newest JOBS_DETAILED_MAX =
  100 jobs. One round submitted 193 jobs, so round 1's finished jobs fell
  out of the window and every round resubmitted (never converges).
- Workaround (no image change): stopped the driver, cancelled round 2
  (c9nd5, vftt4), restarted with `--days-per-task 93` -> 65 tasks (39 + 26
  over two windows), fewer than 100 jobs per round. Driver runs from
  `backfill-windows` (#8) with origin/main merged (744307c, pushed).
- User merged databento-mkt-data#9 (ae9d3cc). Redeploy (image 0372fb9d)
  not done yet at 19:20 (round 2 still ran 6e7bdf6b).
- Proper fix to propose: remember the submitted job id per task range (e.g.
  a small object in the bucket) and look it up with get_job_details, with
  the newest-100 listing as fallback.
- 2026-10-12 ~19:25 UTC: user redeployed infra. Verified: both jobs on
  image 0372fb9d (amd64 c93413a3), archive md5 = market-info 67e95a8, three
  alert policies from program-events.json (overdue 86400s,
  expiration_differs 86400s, failed_permanently 3600s, anchored [ALERT]
  filters) plus the no-runs policy. Round 1 of the 65 task run
  (rr4b7, g8n4t, created 19:27) runs the new image.

## Backfill result (2026-10-13)

- Driver (`--days-per-task 93`, 65 tasks in 2 windows) finished in 3 rounds:
  round 1 rr4b7/g8n4t 19:27, round 2 htswn/6nrpc 21:17, round 3 9jl7d/wcn49
  00:19 UTC. Round 3: all 65 tasks logged `download_job.dataset.done
  outcome=nothing_to_do`; driver printed `done: every day of [2010-06-06,
  2026-10-12) is downloaded` at 02:20 UTC. Rounds 1 and 2 had no failed tasks.
- Verified against the bucket, not just the driver: listed every
  `ohlcv-1m` object (20 min with `gcloud storage ls -l`), compared with each
  contract's [max(activation, 2010-06-06), min(termination, 2026-10-11)]
  from the market-info RON files of the 11 products. 1,059 contracts, every
  contract has every UTC day, 0 missing. 892,458 objects, 1.41 GB; ~60% are
  62 byte header-only files (no trades that day). Last data day is
  2026-10-11 except ZC/ZS 2026-10-09 (grains do not trade on UTC weekends).

| Product | Contracts | Expected days | Days with bars |
| --- | --- | --- | --- |
| CL | 206 | 403,884 | 105,763 |
| GC | 197 | 115,727 | 51,565 |
| ZS | 122 | 116,999 | 50,991 |
| ZC | 87 | 86,183 | 49,115 |
| ES | 67 | 39,291 | 17,290 |
| ZT ZF ZN ZB UB | 67 each | 17,945..21,921 | 7,819..10,793 |
| TN (from 2016) | 45 | 11,875 | 4,990 |

- Warnings: `download_job.resolve.activation_differs` 157x CLZ9 (Dec 2019
  contract: market-info 2010-11-19, Databento 2010-11-22) and 1x ESM0 (Jun
  2020). Data downloaded anyway. Round 2 logged ~1,574 `[ALERT]
  download_job.overdue` lines for historical days; they do not notify,
  because the alert policies filter on the scheduled job's name only.
- Execution history: 5 failed executions before 19:27 (bhlhq, n98qj, xm6zm,
  c9nd5, vftt4) are the driver bugs and the cancelled resubmitting round.
- `gcloud` tokens expire; non-interactive agents cannot reauthenticate, the
  user has to run `gcloud auth login`.

## Knowledge base and client release (2026-10-13)

- User asked to write the decisions into the knowledge base: DEC-0BPWJ
  revision 2026-10-12 (done per object, product selection, backfill job and
  driver, expiration warning, newest-100 batch job limit as an open item),
  REF:databento-market-data update, and a new decision for program events
  (D7). knowledge-base branch `dec-0bpwj-per-contract-backfill` (8722d01,
  signed, not pushed): DEC-0BPWJ R14-R19 (revision 2026-10-12), new
  DEC-0CHAM (program events and alert policies), REF:databento-market-data,
  REF:platform-topology, DEC-0CG61 note (market-info uses each contract's
  last complete definition since 67e95a8). `just catalog` and `just check`
  pass.
- Found by checking code: `download_job.resolve.expiration_differs` is
  logged at `[ALERT]` level, not warning; the production image is built from
  the PR #9 branch commit d16145f, not the merge ae9d3cc; the driver default
  is 31 days per task (93 passed by hand); infra `download-job.ts` header
  still says alerts reach Discord through alert-service (notify-gw replaced
  it); ISS-0C7D9 still says the job waits for Databento.
- Client: copied market-info 67e95a8 `market-info.rkyv` (629,224 bytes, md5
  8aa4c168...) into client-core. `just generate-databento-price-sources`
  failed with `duplicate Databento reference GLBX.MDP3/GCM1`: decade twins
  share a raw symbol. Fix: the generator keeps, per symbol, the contract with
  the latest trading termination (Databento resolves a raw symbol to the
  newest contract; live `ZNZ6` is the 2026 contract); equal terminations fail.
  Catalog 165 -> 760 contracts, no existing row changed; WASM +190 KB.
  client 401bb1d pushed to main (signed). `just check rs-client-core` passes;
  `platform-api` and `ts-bundle` checks fail locally only (monorepo
  workspace layout), unrelated.
- stxr-client-app: `client` submodule bumped to 401bb1d; the app loads the
  archive through `require.resolve('@structure/client/market-info.rkyv')`.

## Open after the backfill

- Batch job lookup: Databento lists details for only the newest 100 batch
  jobs; a round with more than 100 tasks resubmits forever. Fix not built
  (remember the submitted job id per task range).
- 33 Treasury/gold contracts with Good Friday in the delivery window still
  need a manual check (market-info).
- Products outside the 11 (NQ, SR3, ...) likely miss days before ~2026-10-09
  from the marker era; the scheduled job only looks back 7 days.
