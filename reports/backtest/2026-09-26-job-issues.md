# Backtest Cloud Run job: the post-processor sidecar is killed before its export

Status 2026-09-26. Handoff for a fresh agent session. Everything below was
verified in-session unless marked "hypothesis".

## Goal

Prove the two-container backtest job shape before the application server
(`structure-web/packages/api/src/backtests/backtests-service.ts`) is changed to
build it:

1. `backtest` container: flip-positions strategy in `--regime backtest`, writes
   the results feed to a shared ephemeral disk (`/mnt/shm/feed.bin`).
2. `post-processor` container (sidecar): `backtest-post-processor` tails the
   feed, builds a DuckDB artifact on the same disk (`/mnt/shm/results.duckdb`),
   then copies it to the backtests bucket through a GCS Fuse mount
   (`results-export`), exits 0.

Success = `gs://stxr-prop-asia-backtests-gj7u4/tests/backtest-job/bt_FBVXBEGW7G8YE/results.duckdb`
exists after an execution.

## Current blocker

Cloud Run ends the task as soon as the strategy container exits, and kills the
post-processor while it is still copying the artifact to GCS. The DuckDB build
and validation finish; the copy never completes, so the bucket only holds the
two config objects.

Two executions, identical outcome, opposite `containers` order:

| execution | order in `containers` | strategy summary | post-proc last line (`results_sink.finalized`) | task completed | artifact |
|---|---|---|---|---|---|
| `flip-positions-backtest-test-kz7m5` | backtest, post-processor | 22:28:04.573Z | 22:28:04.585Z | 22:28:07.940Z (success) | no |
| `flip-positions-backtest-test-msgjc` | post-processor, backtest | 22:37:58.293Z | 22:37:58.271Z | 22:38:01.997Z (success) | no |

After `finalized` the post-processor logs nothing: no
`btest_post_proc.results_sink.exported`, no `export_failed`, no
`backtest_post_processor.main.shutdown`. Locally (`just e2e-backtest`) all three
appear, so in Cloud Run the process is killed between finalize and the end of
the export. `exit(…)` in `main.rs` runs only after `main.shutdown` is logged.

Cloud Run's system log stream (`run.googleapis.com/varlog/system`) had no
"container exited" entries for these executions; only stdout and the audit log.

## What was tried

1. **Reorder containers** (post-processor first): no effect (`msgjc`). So the
   task's "main" container is not chosen by position.
2. **`dependsOns: ["backtest"]` on the post-processor** so the strategy becomes
   a sidecar and the post-processor the container the task waits for. Rejected
   by the API at `pulumi up`:
   `spec.execution_template.spec.task_spec.containers[0].depends_on: Dependent container 'backtest' must have startup probe specified`.
   The strategy cannot satisfy a probe: its health server exists only in live
   mode (`structure-strat-template-core/src/live/run.rs:100-121,360-391`); in
   backtest mode it listens on nothing (`src/backtest/run.rs` has no server).
   Cloud Run job probes are httpGet/tcpSocket/grpc only.
3. **Current state (deployed? NO, only in code, `pulumi up` not run since):**
   `backtest` container runs a `sh -c` wrapper (`STRATEGY_SCRIPT` in
   `infra/infra/strategies/tests/backtest-job.ts`): run the strategy; on exit 0,
   poll `[ -f <export path on the results mount> ]` every 1 s for up to
   `ARTIFACT_WAIT_TIMEOUT_S=900`, then exit 0 (`wait_for_artifact.done`) or 75
   (`wait_for_artifact.timeout`). Script verified inside the pushed strategy
   image (both branches; `sh`, `sleep`, `date` present; user `runner`).
   Rationale: a GCS object appears only once its upload completes, so the
   file's presence means the export finished; keeping the strategy container
   alive keeps the task alive under either rule below.

## Open question that decides the production design

Which rule does Cloud Run apply to a job task with several containers and no
`dependsOn`?

- (a) the task ends when the *main* container exits, main chosen by some rule
  other than list position (unknown), sidecars are killed; or
- (b) the task ends when *any* container exits 0.

Both runs only show "strategy exit → task end"; the post-processor never
exited first, so (a) and (b) are indistinguishable so far. The wrapper
(step 3) works under both. Docs checked and silent on this:
`docs.cloud.google.com/run/docs/create-jobs` (sidecars section),
`/run/docs/configuring/jobs/containers`, `/run/docs/configuring/jobs/healthchecks`,
`/run/docs/configuring/jobs/ephemeral-disk`.

An existing prototype in the project, `multi-container-edisk-proto`
(asia-northeast1, containers consumer then producer, emptyDir Disk 10Gi at
`/mnt/shm`, succeeded 2026-06-01), was built by a teammate with gcloud; its
source is not in the workspace. It may encode how they handled termination.

## Next steps (suggested order)

1. `cd infra && pulumi up` (stack `production`; needs `gh auth` for the
   market-info fetch), then
   `gcloud run jobs execute flip-positions-backtest-test --region asia-northeast1 --project stxr-prop --wait`.
   Expect post-processor `results_sink.exported destination=… bytes=…` and
   `main.shutdown`, strategy container `backtest.wait_for_artifact.done`, the
   object in the bucket. The sighting can lag the upload by the fuse mount's
   stat-cache TTL (up to ~60 s).
2. If it still fails: check whether the post-processor now exits *before* the
   strategy wrapper (it should, once the export is done) and whether the task
   then ends with success. That run distinguishes (a) from (b).
3. Decide the production mechanism:
   - marker protocol: post-processor writes `<shared disk>/post-processor.exit`
     with its exit code; strategy image entrypoint waits for it (no fuse
     polling, works on failure too). Needs a post-processor change + rebake
     (`just bake backtest-post-processor` in `infra/`, 15-30 min cold) and a
     wrapper in the production strategy image (`structure-strat-template/Dockerfile`, CMD).
   - or add a health endpoint to the strategy's backtest regime so
     `dependsOn` + `startupProbe` (the documented mechanism) can be used; needs
     template-core change → rebuild `strategy-builder` (Cloud Build,
     `just build_builder`) → rebuild strategy image.
4. Reflect the verdict in `structure-web` when the application server job
   template is rewritten (see "Application server" below).

## Log queries

```sh
# all lines of one execution, with container name
gcloud logging read 'resource.type="cloud_run_job" AND labels."run.googleapis.com/execution_name"="<EXECUTION>"' \
  --project stxr-prop --order asc --limit 3000 --format json \
  | python3 -c 'import json,sys
for e in json.load(sys.stdin):
    l=e.get("labels") or {}
    print(e["timestamp"], l.get("run.googleapis.com/container_name"), (e.get("textPayload") or "")[:200])'

gcloud run jobs executions list --job flip-positions-backtest-test --region asia-northeast1 --project stxr-prop
gcloud run jobs describe flip-positions-backtest-test --region asia-northeast1 --project stxr-prop --format yaml
gcloud storage ls -l "gs://stxr-prop-asia-backtests-gj7u4/tests/backtest-job/**" --project stxr-prop
```

`gcloud config get-value project` is `stxr-prop-dev`; always pass
`--project stxr-prop`.

## The job as deployed (msgjc) / as in code

- Pulumi: `infra/infra/strategies/tests/backtest-job.ts` (job, IAM grant,
  config objects), `backtest-config.ts` (backtest settings, both YAML configs,
  mount paths; Pulumi-free), `backtest-id.ts` (id wasm; Pulumi-free). Loaded
  from `pulumi.config.ts` for `production` only.
- Job `flip-positions-backtest-test`, asia-northeast1, `launchStage: BETA`,
  gen2, `maxRetries: 0`, `timeout: 3600s`, service account `backtestAccount`.
- Volumes: `shared-disk` = `emptyDir { medium: DISK, sizeLimit: 10Gi }` at
  `/mnt/shm` (both containers); `config` = config bucket ro at `/mnt/config`;
  `historical-data` = `stxr-prop-asia-historical-data-qmdzj` ro at
  `/mnt/historical-data`; `results` = `stxr-prop-asia-backtests-gj7u4` rw at
  `/mnt/results` (both containers).
- `post-processor`: image `asia-docker.pkg.dev/stxr-prop/images/backtest-post-processor@sha256:6116c782ebd56d28a4247e92878ea6f1992b8e56f2e527a8602c7b5ef91e15f2`
  (built after the `results-export` change), `dumb-init -- /usr/local/bin/backtest-post-processor --config /mnt/results/tests/backtest-job/bt_FBVXBEGW7G8YE/post-processor.yaml`, 2 CPU / 4Gi, user `runner`.
- `backtest`: image `asia-docker.pkg.dev/stxr-prop/images/flip-positions-strategy@sha256:f6b7c107310904e936aa5a4909bfc3e3b786a8189010132bc19cb2536b72dad5`
  (`structure-strat-template/Dockerfile`, template-core `636fb73a4`, flip-positions
  `canonical-strategy-spec.json` as `strategy.jsonc`, features `strat_logging`),
  binary `/usr/local/bin/strategy`, CLI `--config <path> --regime backtest`
  only, 2 CPU / 4Gi, user `runner`. In code now wrapped by `STRATEGY_SCRIPT`.
- Config objects (already in the bucket, unchanged):
  `tests/backtest-job/bt_FBVXBEGW7G8YE/strategy.yaml`, `…/post-processor.yaml`.
  Post-processor config: `feed-source /mnt/shm/feed.bin`, `results-sink
  /mnt/shm/results.duckdb`, `results-export /mnt/results/tests/backtest-job/bt_FBVXBEGW7G8YE/results.duckdb`,
  `watchdog-timeout-ms 300000`.
- Backtest: ESZ6 `inst_2RCH3R49FDADF` (market-info `b34b5df`, pinned as
  production `market_info:revision`), 2026-09-24T00:00Z → 2026-09-25T00:00Z,
  flip every 60 s, USD `asst_0XRKH3G8PHPHC` 1,000,000, CME delay 100 ms,
  account `tacc_02KJD0X740400`, strategy `02KJD32GW0400` rev
  `rev_0000000000008`, id `bt_FBVXBEGW7G8YE` (computed by the id wasm; the
  strategy recomputes and verifies it at startup).

## What already works (do not re-debug)

- Strategy in Cloud Run: reads catalog + day file through fuse, replays
  9,517,467 ticks in ~55 s, 1380 simulated fills, writes 29,151 feed records,
  `strategy.backtest.summary … completion=Finished job=Succeeded`.
- Post-processor in Cloud Run: tails the feed while it is written, folds it,
  `results_sink.finalized` (DuckDB checkpointed, validated, renamed on
  `/mnt/shm`) ~0.2 s after the strategy's terminal record.
- Export code path locally: `backtest-post-processor/src/egress/artifact_export.rs`
  (copy + `sync_all`, partial destination removed on failure, exit category
  `Export` = 12); unit tests and `just e2e-backtest` green with the exported
  file byte-identical.
- Backtest id computation in infra (`backtest-id.ts`) matches the strategy's
  own check.
- Market data for 2026-09-24 is in the historical bucket (download job ran).

## Uncommitted work (as of this note)

- `infra`: `infra/docker-repository.ts` (`flip_positions_strategy()` pinned to
  the digest above, `backtest_post_processor()` digest updated by the user),
  `infra/strategies/tests/backtest-job.ts` (wrapper, no `dependsOns`),
  `infra/strategies/tests/backtest-config.ts`. Earlier work in this area was
  committed as `07a64ac backtest deployment`.
- `structure-strat-template`: `justfile` (`build` → Cloud Build via
  `misc/cloudbuild.strategy.yaml`, `build_locally` → docker buildx with
  `--build-arg BUILDPLATFORM=linux/amd64` because `strategy-builder` is amd64
  only, `STRATEGY_IMAGE` override), new `misc/cloudbuild.strategy.yaml`.
  `strategy.jsonc` (git-ignored) holds the flip-positions spec.
- `backtest-post-processor`: `results-export` feature (config field, export
  adapter, exit code 12, README, e2e check), on top of the committed
  `18bbdb8 duck db sink`.

## Application server (later, out of scope for the debug)

`backtests-service.ts:buildCloudRunJobTemplate/buildCloudRunJobExecution` still
pass the legacy CLI flags (`--warehouse-dir`, `--start-ts`, `--outfile`, …) that
the current binary rejects, use `historicalDataDir=/mnt/historical-data/warehouse`
while the download job writes at the bucket root, and know nothing about the
sidecar, the ephemeral disk or `results-export`. The workflow
(`structure-web/packages/workflow/src/reducers/reducer-model.ts:178`) and
`activity-worker/src/jobs.ts` still have the separate "statistics" job steps
that this job shape removes.
