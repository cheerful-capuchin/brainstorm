# Decision: Historical Replay Ingress for Databento Files

Date: 2026-09-20
Status: accepted (demo scope)
Related:
- [Backtest Historical Replay walkthrough](../2026-09-20-hist-replay.md)
- [Bucket Structure for Databento Historical Market Data](2026-09-20-hist-replay-bucket-structure.md)

## Context

The bucket structure decision fixes where the Databento files live and how the strategy plans
which files to replay. It leaves open how the files enter the replayer: a new `HistDataStrem`
implementation, or a reworked `ArrowFileProvider` (`dsl-runtime/src/hist_data.rs`) with new file
resolution and no Arrow decoding.

The backtest will be rewritten later. This decision covers only what the demo needs.

Facts this decision relies on:

- `ArrowFileProvider` is about 870 lines. Most of it only makes sense for Arrow: the prefetch
  thread that groups `RecordBatch`es into chunks, the batch and row cursor, `extract_row_data`,
  the directory prescan, and the `btest-diag` counters. The part that does not depend on the file
  format is about 60 lines: the `peeked_data` cache, the `min_ts` / `max_ts` filter, and `pop`.
- `ArrowFileProvider` copies payload bytes through unchanged. A DBN provider has more to do per
  record, not less: decode zstd and DBN, build `WithTsOut<Mbp1Msg>` with `ts_out = ts_recv`, and
  wrap the result with `envelope::encode` from the feed codec crate.
- `ArrowFileProvider` skips missing and unreadable files silently (`hist_data.rs:391`, and
  `Err(_) => continue` on open and footer errors). The bucket structure decision makes a missing
  file an error.
- The envelope encoder lives in `data-feed-codec-dbn-…`. `structure-strat-template-core` already
  depends on that crate (`Cargo.toml:42`). `dsl-runtime` does not.
- `dsl-runtime` is its own git repository, consumed as a git dependency. Every change to it needs
  a rev bump in the consumers.
- The only callers of `ArrowFileProvider` are three sites in
  `structure-strat-template-core/src/helpers.rs` (lines 145, 248, 370).

## Decision

### A new stream in the strategy core

A new type, `DbnFileStream`, in `structure-strat-template-core` implements
`HistDataStream<DslHistTypeConfig<StratIngressMsg>>`. It reuses `DslHistTypeConfig`, `DslSeqNum`,
and `HistTickData` from `dsl-runtime` as they are. `dsl-runtime` is not edited.

`ArrowFileProvider` stays in place with no callers and is deleted with the backtest rewrite.

### Inputs

| Input | Source |
|---|---|
| `name` | stream name for logs and status updates |
| `subject` | `feed_topic(&route.feed_ref)` |
| `instrument_id` | `HistSource::DatabentoMbp1 { instrument_id }` |
| `files` | full paths from route driven planning, in date order |
| `priority` | the single market data constant from the bucket structure decision |
| `min_ts`, `max_ts` | replay window, inclusive lower and exclusive upper |

There is no `tick_type` argument. It has no meaning for a feed stream.

### State

- the index of the current file,
- an `Option` holding the DBN decoder over a zstd reader for that file,
- one `FlatBufferBuilder`, reused for every record,
- the peek cache, `Option<(StratIngressMsg, DslSeqNum, NanoTimestamp)>`.

### `peek_next`

1. If the cache holds an item, return its sequence number and timestamp.
2. If there is no decoder, open the next file. An open error is returned. It is never skipped.
   When no files remain, return `Exhausted`.
3. Decode the next `Mbp1Msg`. At the end of a file, drop the decoder and go to step 2.
4. If `ts_recv < min_ts`, go to step 3. If `ts_recv >= max_ts`, return `Exhausted`.
5. Build `WithTsOut::new(record, ts_recv)`, wrap its bytes with `envelope::encode` under the
   stream's `instrument_id`, and cache a `HistTickData` with the stream's `subject` and
   `seq_num = DslSeqNum { ts_nanos: ts_recv, block_seq: Generic { sn: ts_recv } }`.
6. Return `DataReady`.

The skip loop in step 4 runs over a finite file list and each pass consumes one record, so it
terminates.

### `pop`

Takes the cached item, as `ArrowFileProvider` does today.

### No prefetch thread

The DBN decoder streams a file in constant memory. Decoding runs on the replayer thread. If warmup
turns out too slow, a thread and a bounded channel can be added behind the same struct without
changing its callers.

### Call sites

The three `ArrowFileProvider::new` sites in `helpers.rs` become one route driven planning function
that builds `DbnFileStream`s. The calls to `warehouse::*`, `probe_existing_paths`, and
`venue_for_topic` are removed from those sites.

### Errors

`DslHistTypeConfig` fixes the stream error to `DslHistError`, which has no DBN variant. For the
demo, a `dbn::Error` is mapped into `DslHistError::Io` with `io::Error::other`.

This is a compromise to keep `dsl-runtime` untouched. The standards preferred design is a
dedicated variant, which comes with the backtest rewrite.

### Test

One test feeds a payload built by `DbnFileStream` through the real feed codec and checks that both
a book update and a trade decode. It covers the envelope, the synthesized `ts_out`, and the record
length in one place.

The record length is the reason this test is necessary. `WithTsOut::new` sets the header length
for the 88 byte layout. A record assembled by hand keeps the 80 byte value, and the codec pins the
layout to `WithTsOut<Mbp1Msg>`.

## Rationale

**A new type is less work than a rework.** Reusing `ArrowFileProvider` would keep its name and
replace its body. The shared part is small enough to write again, and a separate type leaves the
Arrow code compiling and untouched until it is deleted.

**Missing files fail loudly from the start.** Reversing the silent skip inside a shared type risks
leaving one of its `continue` paths behind. A new type has only the strict behavior.

**The strategy core is where the dependencies already are.** The provider needs the feed codec and
the domain instrument id. Putting it in `dsl-runtime` would pull a feed specific codec and
`market-info-core` into the generic runtime, and would cost a rev bump per iteration.

**No Arrow fixtures to replace.** The three existing provider tests run on `.arrow` test data and
decode through `TickDataType`. They stay valid for the type they test.

## Consequences

- `structure-strat-template-core` gains a direct dependency on `dbn` for decoding, next to the
  codec crate it already has.
- `dsl-runtime` keeps its `arrow` dependency and the unused `ArrowFileProvider` until the rewrite.
- A DBN decode error surfaces as `DslHistError::Io`, so logs show it under the IO error key.
- Replay decodes on the replayer thread. A warmup that starts late in a day pays for decoding that
  day from 00:00 UTC, as the bucket structure decision already accepts.

## Out of scope

- The route driven planning itself (`FeedRoute`, `HistSource`, the shared path crate). The bucket
  structure decision covers it.
- Live warmup across the current day. It is the open question in the bucket structure decision.
- Whether the DBN `sequence` should order records within one `ts_recv`. The stream orders by
  `ts_recv` alone and keeps file order for ties.
