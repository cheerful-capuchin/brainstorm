## Context
We're using [databento](https://databento.com/docs/schemas-and-data-formats/mbp-1?historical=rust&live=rust&reference=rust) as our market data provider for the traditional financial markets.
We need to persist the historical data daily for the CME markets. Additionally, we need to persist the data for the past month.
We already have the infrastructure built in GCP, see: infra/pulumi.config.ts. Therefore, I think having GCP Cloud Run jobs downloading the data and putting it into the GCS is a valid approach.
The market info is loaded from the `market-info.rkyv`, see market-info/README.md.
The symbols are resolved via `security id`. See [subscription_key](databento-mkt-data/rust/crates/databento-mkt-data-server/src/domain/subscription_key.rs).

I imagine that we have a "core" that knows how to download data from databento and then we have the runtime entrypoint that parses the CLI flags, config files, etc and calls into that core.
The job would be created in databento-mkt-data/rust/crates/databento-mkt-data-download-job/src/main.rs.
There should be no post-processing of the mkt data. Ideally, we just flush the raw compressed bytes straight into the bucket.

### Storage
The storage pattern was already decided in the brainstorm/reports/backtest/decisions/2026-09-20-hist-replay-bucket-structure.md.
I think we'll need to import the databento-hist-layout from structure-strat-template-core/crates/databento-hist-layout/Cargo.toml

I guess the [runtime config](databento-mkt-data/rust/crates/databento-mkt-data-download-job/src/config.rs) should include something like
```rust
pub struct DatasetConfig {
    /// A Databento dataset id such as `GLBX.MDP3`.
    pub id: Arc<str>,
    /// Filter for the markets that are necessary to be loaded
    pub mkt_info_query: MktInfoQueryConfig,
    /// POSIX path specifying the root of the dataset storage
    /// The storage layout will be enforced by databento_hist_layout = { git = "ssh://git@github.com/stxr-prop/structure-strat-template-core.git", branch = "main" }
    pub storage_location: Box<Path>,
    /// Which time periods to load the data for
    pub time_ranges: Box<[TimeRange]>
}

pub struct TimeRange {
    pub start: NanoTimestamp,
    pub end: NanoTimestamp,
}
```

The storage location will point to the root of the object storage where we'll store the dataset, e.g. '/mnt/stxr-prop-asia-historical-data-qmdzj/data`.

### Sharding
Since we're running in GCP Cloud Run as a Job, we can parallelize the work, and therefore, should have the runtime config property
```
// [CLOUD_RUN_TASK_INDEX](https://docs.cloud.google.com/run/docs/create-jobs)
// We plan to run the jobs in parallel, therefore, we need some sharding logic
pub task_index: u16,
// [CLOUD_RUN_TASK_COUNT](https://docs.cloud.google.com/run/docs/create-jobs)
pub tasks_total: u16,
```
I think the simplest sharding would be to split by instrument id.
I guess doing `instrument_id.0 % tasks_total` will give us the sharding, and then we pick by index?


### Concurrency
This job is primarily I/O, therefore, we can have highly concurrent execution as long as databento allows us to do that.
However, I don't want to spawn a bunch of tokio tasks all over the place and then pull my hairs out trying to figure out the relationships.
```
Our historical API allows each IP address up to:

    100 concurrent connections.
    100 time series requests per second.
    100 symbology requests per second.
    20 metadata requests per second.
    20 batch list jobs requests per second.
    20 batch submit job requests per minute.

When a request exceeds a rate limit, an Error::Http will be returned with a 429 error code.
```
https://databento.com/docs/api-reference-historical/basics/rate-limits?historical=rust&live=rust&reference=rust

### Databento API
We'll use the databento download job API
https://databento.com/docs/api-reference-historical/helpers/batch-submit-job-params?historical=http&live=rust&reference=http.
Based on the calculations and the standard plan, the costs are included in the plan. See: databento-mkt-data/rust/crates/databento-mkt-data-download-job/download-costs.csv

### Upload
Databento's https URL is a GET with basic auth (the API key as the username).
The body is already the .dbn.zst file.
Send Accept-Encoding: identity so the HTTP client does not decompress it.
The SHA-256 in BatchFileDesc is of those compressed bytes.
Read the body as a chunk stream and update the hash as the bytes pass.
Both sides support resume: Databento with a Range header, GCS with the resumable session.

GCS should be a resumable upload to the final object name, with Content-Length set from BatchFileDesc.size.
Each PUT except the last must be a multiple of 256 KiB.
Accumulate the small HTTP reads into an 8 MiB buffer and flush that. Eight workers then hold 64 MiB of payload.

Hold back the last chunk until the hash matches.
That PUT is what makes the object readable.
If the hash does not match, cancel the session and the object never appears.
A dropped connection retries the same session and the same Range, inside the same worker slot.

todo: knowledge-base (mkt-data-download-job-gcs-grpc-vs-json-api)

### Queued or concurrent?

Every batch job moves through the same states: Received → Queued → Processing → Done → Expired. Expired comes 30 days after the job finishes. The docs don't say how many of your jobs Databento processes at the same time. Nothing says they run one at a time per account, and nothing promises they run in parallel. In the docs' example, a small job waited about 15 seconds between being queued and starting to process.

So don't build the design on either answer. Each task submits its job, polls get_job_details until the state is Done, then downloads. That works whether Databento runs your jobs in parallel or one after another; one after another just takes longer. If you want the real number, submit three small jobs and compare their ts_process_start and ts_process_done timestamps, or ask Databento support.

The limit that is documented is 20 submits per minute per IP address. Your Cloud Run jobs send traffic through the VPC with the egress tag, so all tasks probably leave through the same Cloud NAT address. If so, they share that one budget of 20. Retry a 429 with backoff.

### Idempotency

The API doesn't provide it:

SubmitJobParams has no idempotency key, tag or label (checked in the databento 0.60 source), and the returned BatchJob has none either.
Each submit creates a new job and is billed as a new request. What's free is downloading a finished job's files again during its 30 days.
The error table lists 409 Conflict, but nothing says batch submit returns it for a duplicate. Don't count on it.

So you deduplicate on your side.

1. The bucket decides what to request. Before submitting, drop every (instrument, date) whose object already exists. The request then covers only missing data. A rerun after a successful run submits nothing.

2. Reuse a Databento job that already covers the missing data. This handles a crash after submitting but before every upload finished:

Call list_jobs for all states except Expired, since 30 days ago. Then call get_job_details on each result (list_jobs_full does both in one call).
Reuse a job if it has the same dataset, schema, stype_in, encoding, compression and split settings, and its symbols include the ones you need, and its [start, end) covers the missing dates.
If it's Done, download only the files for missing objects. If it's still queued or processing, poll it instead of submitting again.

Match on "covers what I need", not on an exact copy of the request. After a partial success the missing set is smaller, so an exact comparison would miss the earlier job and you'd pay for the same data twice.

A dropped upload in the middle is cheap to recover as long as the process is still alive. Recovering after the process itself dies is expensive, so in that case start the file over.

### State kept for each file

Three numbers and one buffer describe an upload in progress:

- `read`: bytes received from Databento so far. The SHA-256 hasher has seen exactly these bytes.
- `confirmed`: bytes GCS has confirmed it saved.
- `buffer`: holds the bytes `[confirmed, read)`, at most 8 MiB.
- `session_uri`: the upload session, kept in memory only.

Keep one rule: **clear the buffer only after GCS confirms it saved the whole chunk.** With that rule, a drop on one side never touches the other side.

#### Case 1: the GCS connection drops (process still alive)

Ask GCS how much it saved. Send an empty `PUT` to the session URI with the header `Content-Range: bytes */{total}`.

| Reply | Meaning | What to do |
|---|---|---|
| `308` with `Range: bytes=0-K` | GCS saved `K+1` bytes | resend from byte `K+1` out of the buffer |
| `308` without `Range` | nothing saved yet | resend from 0 |
| `200` / `201` | the object is finished | done (only possible after the last chunk) |
| `404` / `410` | the session expired or was cancelled | start the file over |
| `429` / `5xx` | GCS is busy | back off, then ask again |

Don't assume GCS saved all of the chunk or none of it. It can keep part of a chunk, so resend exactly from `K+1`. Those bytes are still in your buffer, so you don't need anything from Databento and the hasher stays untouched.

#### Case 2: the Databento connection drops (process still alive)

Send the request again with `Range: bytes={read}-` and keep feeding the same hasher. Check the reply:

- **`206`** with a `Content-Range` that starts at `read`: continue.
- **`200`**: the server ignored the Range header and sent the file from byte 0. Either skip the first `read` bytes without hashing them, or start the file over.

If the file changed on Databento's side in between, the SHA-256 check at the end catches it. GCS isn't involved at all.

#### Case 3: a drop during the last `PUT`

This is the one case where you don't know the outcome. The object may already exist. Ask GCS for the status as in case 1. `200`/`201` means it's finished; `308` means send the last chunk again. The hash was already checked before you sent it, so a finished object is always a correct one.

#### Case 4: the process dies (crash, OOM, task timeout)

The hasher state, the buffer and the session URI are lost. Resuming would mean saving the session URI somewhere and rebuilding the SHA-256 state for the bytes GCS already has. That means either saving the hasher's internal state or downloading and hashing those bytes again. For daily files per instrument, it isn't worth the extra code.

Start the file over instead:

- **The next attempt finds the gap by itself.** Set `maxRetries` on the Cloud Run job. A retried task gets the same `CLOUD_RUN_TASK_INDEX`, so it takes the same instruments. It skips objects that exist, and a Databento job that is still `Done` gets reused (layer 2 from the previous answer). Only the unfinished files are downloaded again, at no extra Databento charge within the 30 days.
- **The abandoned session never becomes visible.** You held back the last chunk, so no object was created. GCS deletes the unfinished session after a week.
- **There is no half-written file for readers to see.** A missing object means "not downloaded yet", as the layout decision requires.

## Where retries happen

- **Inside one worker slot:** network drops in cases 1–3, with backoff and a retry limit. After that limit, give up on the file, record it as failed, and move on to the next file.
- **At the job level:** failed files make the task exit nonzero, and the next attempt (Cloud Run retry, the next day's run, or a manual run) redoes them.

That keeps error handling in two layers, and neither has to save state outside the bucket.

## Questions


----

### 1. What are the trade offs of using the JSON-RPC vs gRPC for the resumable uploads?
I think tonic was added to the grpc group https://grpc.io/blog/grpc-welcomes-tonic/ and now there is an official rust grpc client.
For my specific use-case, where I have to download a bunch of mkt data and upload it to the bucket, what is a more appropriate option?
Do I use the JSON api or gRPC?


### 1. Is there a difference in performance when loading multiple datasets from the same vs different buckets?
If I load multiple data sets over the network calls to the GCS, does it make a difference whether I call to the same bucket or multiple different ones?
Do I store all my datasets in a single "historical-data" bucket or a bucker per dataset?

### 2. What concurrency model can we use and how can we structure the application?
I want the bounded memory pools, bounded tasks.

### 3. What databento historical client methods should be called?
You can inspect the source code in ~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/databento-0.60.0/src/lib.rs and see the docs in https://databento.com/docs/api-reference-historical/basics/overview?historical=rust&live=rust&reference=rust


