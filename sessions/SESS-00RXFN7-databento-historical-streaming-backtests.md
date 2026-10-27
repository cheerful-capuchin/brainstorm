---
create_time: 2026-10-30T10:55:35Z
title: "Databento historical streaming for missing backtest data"
summary: "Research, no decision: historical HTTP streaming is feasible; recommend durable on-demand cache fills, batch for large gaps. Customer licensing, quotes, latency and data versions need validation."
related_sessions:
  - SESS-00QP5W3
  - SESS-00PYCE2
  - SESS-00QE2QN
agents:
  - omp:da5dc989-4df1-4981-8be0-20bf8b8900a1
---

# SESS-00RXFN7: Databento historical streaming for missing backtest data

## Request and scope (2026-10-30)

- User: backtesting currently relies only on data downloaded into our bucket.
  This limits product exploration and customer features.
- Databento is currently our only market data vendor.
- Research whether its streaming API can supply historical data missing from
  the bucket, and explain feasibility and tradeoffs.
- User explicitly requires a session file.
- Research only. No implementation, paid data requests, account-secret access,
  or knowledge-base changes.
- No implementation direction has been accepted by the user. Recommendations
  below must not be treated as decisions.

## Session provenance

Created with the decision-log session script and attached to dev-env. The
harness did not expose its session identifier; the `omp` agent entry uses a
UUID assigned to this research run, not a resumable harness transcript ID.

## Feasibility: yes, through the Historical API

Databento's `timeseries.get_range` is a finite historical HTTP response,
streaming DBN records for an explicit `[start, end)` range. It is not paced
at the original market speed. The official FAQ says streaming and batch
return the same data and are both suitable for market replay [S1, S2].

Do not confuse this with the Live API's intraday replay: normally the last
24 hours, then continuing into live data. GLBX.MDP3 MBO and definitions have
a weekly-session exception; MBP-1 does not. That cannot replace arbitrary
historical backtests [S3].

The Rust SDK already used in this workspace supports incremental decoding:
`TimeseriesClient::get_range` returns an `AsyncDbnDecoder` over the HTTP
response body. `get_range_to_file` instead drains the response to a file
before returning. The default Python `get_range` documented on the API page
also returns only after the download. Choosing a streaming service does not
automatically mean a particular client helper starts evaluation early [S1, S4].

### Public limits and availability

- Up to 2,000 explicitly selected symbols per request, one dataset and schema
  per request. Multiple symbols are time-merged within that request [S1].
- Per IP: 100 concurrent connections, 100 time-series requests/s,
  20 metadata requests/s. Shared egress IPs share those limits; 429 responses
  specify `Retry-After` [S5].
- No hard size limit. Databento recommends batch above 5 GB; this is guidance,
  not an API cutoff [S6].
- Query entitlement-aware `metadata.get_dataset_range` for each schema's
  actual available range. A bucket miss is not proof Databento has the data.
  Historical streaming does not make today's unpublished data available [S7].
- `metadata.get_dataset_condition` distinguishes available, degraded, pending
  and missing days, and exposes a last-modified date. Availability and data
  quality are separate questions [S8].

## Current integration constraints

The current path is:

```mermaid
flowchart LR
    A[Databento historical batch] --> B[Download job]
    B --> C[GCS DBN day objects]
    C --> D[Mounted warehouse]
    D --> E[File validation and replay]
```

Primary local evidence:

- `knowledge-base/docs/references/databento-market-data.md:23-53,140-227`:
  GLBX.MDP3 futures, DBN end to end, day files and definition-driven
  downloader identity mapping.
- `structure-strat-template-core/src/hist_replay.rs:1-22,140-153`:
  a missing day is a planning error, not a quiet market.
- `structure-strat-template-core/src/backtest/run.rs:320-363`:
  plans and validates the files before replay; status seeding also reads files.
- `structure-strat-template-core/src/hist_replay/day_file.rs:1-18`:
  validates dataset, schema, symbology, contract id and coverage; rejects
  truncated records and incomplete compression frames.
- `structure-strat-template-core/src/hist_replay/dbn_file_stream.rs:176-202`:
  MBP-1 and status replay at receive time; status snapshots are not events;
  OHLCV replays at bar close, not bar open.
- `structure-strat-template-core/Cargo.toml:69-80`: DBN replay is a normal
  dependency; the Databento client is currently optional, for download tools.

### Invariants a new source must preserve

1. Resolve the requested contract through point-in-time definitions, not a
   raw symbol or numeric security id alone. CME reuses ids and symbols.
   Reuse the downloader's resolver rather than inventing a second mapping.
   Current replay still checks against market-info's security id; accepted
   DEC-0CMNF and open ISS-0CMQ4 describe that limitation.
2. Supply every required schema, not just the visible strategy bars. Include
   execution quotes, status seed history (up to seven preceding days), and
   any warm-up interval the actual replay plan requires.
3. Preserve receive-time ordering, deterministic cross-stream tie handling,
   bar-close timing, and the status snapshot/event distinction. A slow or
   temporarily silent source cannot be treated as exhausted while another
   stream advances simulation time.
4. Keep missing, confirmed empty, partially resolved, unavailable and failed
   requests distinct. HTTP 206 can mean only some requested symbols resolved.
   A timeout or generic 422 is not proof of an empty day.
5. Reject an incomplete transfer. A claimed range in a DBN header is not
   evidence that the whole response body arrived. Never publish a partial
   day as a complete canonical object or mark a partial replay successful.
6. Do not place an arbitrary sub-day slice under the existing complete-day
   key. Fetch complete canonical days for reuse, or explicitly represent
   partial coverage with a different artifact/coverage model.

## Options and tradeoffs

These are research recommendations, not user decisions.

| Approach | First uncached run | Repeated runs | Main risk | Fit here |
| --- | --- | --- | --- | --- |
| Stream directly into replay, discard afterward | Can overlap download and evaluation | Repeats vendor transfer and possibly billing | Network failure, merge stalls and vendor dependence during computation | Technically feasible; highest runtime change |
| Fetch missing data through Historical streaming, persist, then replay | Waits for fetch before replay | Reuses existing bucket path | Larger initial fetch if canonical days exceed requested slices | Recommended starting point |
| Stream into replay while also persisting | Can overlap download and evaluation | Cache helps later runs | Requires both replay correctness and atomic cache publication | Consider only if measured startup benefit warrants complexity |
| Prepare missing data through batch, then replay | Vendor preparation delay | Reuses files; vendor batch can be re-downloaded for 30 days | Poor interactive latency for an uncached request | Large requests and background preparation |

Fetching on demand still removes the product constraint: users need not wait
for us to choose and download each date range beforehand. It does not require
making the simulation engine depend on a network socket.

### Latency and reliability

Streaming avoids batch preparation; it does not guarantee low time to first
byte. Existing internal evidence, not a new benchmark:

- ISS-0CVP9 records 5-20 s per historical request even below 1 KB, plus
  inactivity timeouts and socket errors (2026-10-20).
- The older download session SESS-00PYCE2 records batch preparation-to-download
  waits of 5-236 minutes across ten day downloads (2026-09-26..10-06).

Neither is a current SLA or a representative MBP-1 throughput benchmark.
Expect cold and cached runs to have different completion estimates.
Direct replay may hide transfer time behind computation, but cannot advance
past the slowest required input. Prefetch spends more time before evaluation
but isolates replay from later vendor outages and allows existing integrity
checks before results begin.

### Economics

Under usage-based pricing, Databento bills uncompressed binary bytes, not
the compressed `.dbn.zst` size in GCS. Streaming charges for bytes sent;
repeating a range or retransmitting an already sent prefix can charge again.
A batch request is billed once, with repeat downloads allowed for 30 days
[S2, S9].

Flat-rate plan discounts can make some requests cost zero. Do not assume
all historical streaming incurs incremental charges, or that a live
subscription includes every schema and all history. `metadata.get_cost`
respects plan discounts. Its estimates can over-report non-10-minute
ranges; definitions are accurate only on 24-hour multiples [S10].

The prior Treasury backfill session recorded a $0 quote for OHLCV-1m in our
account on 2026-10-12. That is evidence for that request then, not proof
about today's MBP-1 entitlement.

The cost comparison is therefore:

- Direct replay: vendor charges for every uncached/repeated transfer,
  plus replay compute and network waiting.
- Durable cache: vendor charges for unique missing coverage and refreshes,
  plus storage and cache reads; repeated simulations avoid the vendor.
- Batch: same storage benefit, plus no extra vendor download charge when
  retrying an existing prepared job within 30 days.

Use a request-specific quote, a per-request/per-organization allowance and a
bounded shared fetch queue. Deduplicate simultaneous misses by dataset,
schema, contract and coverage. Otherwise many users can pay to fetch the
same data at once. The portal monthly historical limit is an account-wide
safety net, not per-customer admission control [S11].

### Reproducibility and corrections

Fresh vendor data and existing bucket data can differ. Open ISS-0CVZ8
documents matching request headers but changed MBP-1 counts; affected runs
had different fills, while local replay of the bucket files reproduced the
platform results. The suspected cause is later vendor revision; the issue
does not prove that cause.

Persist the exact input artifact identity/checksum or bucket generation used
for each run. Keep refresh/version policy explicit rather than silently
combining a different vendor snapshot on each rerun. On-demand fetching
solves absent data, not the independent stale-data problem.

### Scope of the product benefit

This expands coverage to data Databento has and we are entitled to use. It
does not automatically add missing contracts to market info, introduce a
new feed schema, implement a new venue simulator, fix survivorship/roll
selection, or recover an upstream data gap. A wider catalog still requires
compatible domain metadata and replay support.

## Verification performed

- Read the official API/FAQ documentation and the installed Rust
  `databento-0.60.0` streaming implementation.
- Ran a local transport smoke using an existing real GLBX.MDP3 MBP-1 fixture:
  an in-memory HTTP server sent the compressed data in chunked responses;
  `curl --no-buffer` piped it into the actual `dbn` CLI.
- Observed 37,583 compressed bytes, 74 HTTP chunks and 2,000 decoded records.
  Decoded JSON matched a direct local-file decode byte for byte.
- Server and subprocesses were stopped; no throwaway source files created.
- This proves DBN transport/decoder compatibility only. It does not prove
  vendor latency, current account entitlement, billing, replay integration,
  retry correctness, or customer licensing. No paid/vendor data request ran.

## Primary web sources

- [S1: Historical timeseries.get_range](https://databento.com/docs/api-historical/timeseries/timeseries-get-range)
- [S2: Streaming vs batch](https://databento.com/docs/faqs/streaming-vs-batch-download)
- [S3: Live intraday replay](https://databento.com/docs/api-live/basics/intraday-replay)
- [S4: Official Rust streaming implementation](https://github.com/databento/databento-rs/blob/main/src/historical/timeseries.rs)
  (also inspected installed version 0.60.0, lines 36-155).
- [S5: Historical rate limits](https://databento.com/docs/api-historical/basics/rate-limits)
- [S6: Historical size limits](https://databento.com/docs/api-historical/basics/size-limits)
- [S7: Dataset range](https://databento.com/docs/api-historical/metadata/metadata-get-dataset-range)
- [S8: Dataset condition](https://databento.com/docs/api-historical/metadata/metadata-get-dataset-condition)
- [S9: Usage-based pricing](https://databento.com/docs/faqs/usage-pricing-and-data-credits)
- [S10: Cost quotes](https://databento.com/docs/api-historical/metadata/metadata-get-cost)
- [S11: Billing and account monthly limits](https://databento.com/docs/portal/billing)

## Orchestration findings from the integration research

- The server currently checks feed-type support, not time-range coverage:
  `structure-web/packages/api/src/backtests/backtests-service.ts:704`
  explicitly records that gap as `TECH-DEBT[ENG-1220]`. Missing files fail
  later inside the backtest job. SESS-00QP5W3's shared planner/preflight
  direction is not yet implemented.
- The same service's job template (`:1882-1930`) mounts historical data
  read-only and injects only `RUST_BACKTRACE`, not a Databento key.
  Direct fetching is therefore not a configuration-only switch.
- Its post-processor watchdog is 300 seconds (`:89-94`), counted from
  post-processor startup, including strategy setup. Only forwarded result
  feed records reset it
  (`backtest-post-processor/src/ingress/file_tailer.rs:230-255`).
  An in-job prefetch or prolonged stream stall can conflict with that
  lifecycle. Data preparation should happen before launching computation,
  or require an explicit lifecycle change.
- `MarketReader::peek` blocks on the next batch without a timeout
  (`structure-strat-template-core/src/backtest/run/replay/market_reader.rs:84-103`).
  A socket-backed replacement needs bounded I/O failure handling, not
  merely a different file path.
- The existing downloader is batch-based by design
  (`DEC-0BPWJ:179-213`): free repeat downloads of an existing batch and
  vendor file size/SHA-256 are deliberate benefits. A targeted streaming
  cache fill would need an explicit new retrieval path while reusing
  contract resolution and publication rules; do not imply the current
  job already provides this.
- The current downloader selects products, schemas and date windows, not
  an arbitrary list of individual requested contracts. Triggering it
  unchanged may fetch more than a single user's missing input.
- Before deciding missing coverage, validate the contract's listing
  window. The downloader does not create files outside it; streaming
  cannot manufacture data for an unlisted contract.

## Recommendation, pending user decision

Keep the bucket as the replay cache, but remove manual preparation as a
requirement:

1. Plan all required inputs and identify genuine cache misses before
   launching the backtest.
2. Check vendor schema availability, identity and the request-specific
   quote; reject requests outside supported coverage or allowance.
3. For a bounded interactive miss, use Historical HTTP streaming to fetch
   and validate missing canonical coverage, then publish it atomically.
   Share concurrent fetches rather than paying once per requesting run.
4. For large requests, use batch preparation and expose that wait separately
   from simulation. Reuse existing prepared jobs where possible.
5. Launch current file replay once the inputs are ready, recording the
   exact data versions. Keep vendor credentials in the data service.

Direct network replay remains feasible. Choose it only if representative
measurements show that overlapping transfer with evaluation delivers enough
benefit to justify changing the reader, merge, seed, failure and job
lifecycle contracts. Stream-and-cache is the later alternative if early
evaluation is a product requirement.

### Evidence still needed before implementation approval

- Current account-specific quotes and schema/history entitlements; no
  fixed dollar estimate can be justified from public prices alone.
- Written vendor/licensor confirmation for customer-operated hosted
  backtests, storage/reuse and the outputs customers can receive.
- Representative cold/cached measurements from the production region:
  one-session MBP-1, a long OHLCV run and a multi-instrument mix; separate
  time to headers, transfer, validation and replay.
- Compare same-snapshot event order and fills with bucket replay. Exercise
  a connection cut, equal-timestamp records, confirmed empty days, partial
  symbol resolution and concurrent requests for the same missing data.
  These checks were not performed during this research.

## Commercial and licensing findings

Databento's general licensing FAQ says historical access (its definition:
more than 24 hours old) usually needs no separate venue licence, but
explicitly excludes redistribution from that general rule [S12]. Do not
apply the Live API fee schedule automatically to T+1 backtests, or infer
that historical data is unrestricted.

[INFERENCE] Changing delivery from historical batch to historical HTTP
streaming does not itself change rights: Databento says both deliver the
same data. The controlling questions are our agreement, the data's age,
who uses it, and what outputs leave our organization.

The public documents inspected do not establish whether Structure may run
multi-tenant hosted backtests under our current agreement. Confirm:

- server-side historical computation on behalf of external customers;
- durable caching and sharing a fetched input among authorized tenants;
- which outputs may be delivered: aggregate P&L, detailed fills/prices,
  charts, raw records, or a replay feed;
- whether any outputs need historical-distribution or derived-data rights;
- retention and deletion duties, including after a plan/agreement ends.

Do not equate "only results leave the server" with a proven exemption.
The relevant customer-facing outputs need vendor/licensor review.
This question already exists for bucket-based customer backtests; moving
the fetch earlier or later does not resolve it.

The 30-day batch re-download window is a vendor delivery benefit, not
evidence of a 30-day cache retention limit or unlimited retention.
No retention conclusion was established.

Current CME plan prices/schema coverage were not reliably obtainable from
the public pricing page; snippets and old announcements disagreed. No
fixed tier price or current account entitlement is asserted here. The
signed Databento agreement and current CME contract terms were not reviewed.

Additional sources:

- [S12: Databento market data licensing FAQ, historical access and redistribution](https://databento.com/blog/introduction-market-data-licensing)
- [S13: Plans and live-data licensing categories](https://databento.com/docs/portal/live-data)
  (live/intraday guidance, not proof of T+1 customer-use rights).
- [S14: Metered historical pricing](https://databento.com/docs/api-historical/basics/metered-pricing):
  metadata and symbology calls are free; duplicate streams are metered again.

## Existing exploratory code

`prototypes/databento-md/src/infrastructure/databento_historical_replay.rs:140-247`
already builds MBP-1/status historical requests, quotes them and opens an
incremental `get_range` decoder. This is exploratory code, not an integrated
missing-file fallback. It requests raw symbols and logs a cost estimate;
the inspected code does not enforce a spending allowance. Its presence is
implementation precedent, not evidence of production correctness or the
required identity/integrity contracts.

## Outcome

Research completed. Technical feasibility is supported by the official API,
the installed SDK implementation, existing exploratory code and the limited
local HTTP/DBN smoke. Recommended direction: on-demand durable input
preparation, followed by existing replay; direct stream replay is possible
but adds runtime risk. No user architecture decision, implementation,
paid data request or knowledge-base edit occurred.
