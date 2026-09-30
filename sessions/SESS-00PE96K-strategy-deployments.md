---
create_time: 2026-09-30T10:00:51Z
summary: "ISS-0AGTK design: StrategyDeploymentID is a snowflake, not a hash (no dedup of identical deployments); create takes start_policy like backtests, default immediate; strategy runtime revision + image pinned on the StrategyRevision (not the deployment), chosen at publish with latest fallback, released via a platform release pipeline that runs as an activity-worker workflow behind an internal endpoint with a system actor; real StrategyDeployment entity + immutable StrategyDeploymentRevision per start/stop; deployment carries variable bindings + accounts; _time naming; table/connection/expand conventions; wildcard list across revisions/strategies; StrategiesService.start replaced by StrategyDeploymentsService.create"
related_sessions: []
---

# SESS-00PE96K: Strategy Deployment

Related records: NOTE-09412, ISS-0AGTK (ENG-1881), ISS-08ZTF, ISS-0AS3Z, ISS-0002,
DEC-07ADK, REF:strategy, REF:client-views, client DEC-0BRB6 (performance life
starts at first start).

## Constraints the user set (2026-09-30)

1. **Restart history must not be lost.** The user wants an entity "like a
   deployment revision": immutable records of every start/stop cycle of the
   same deployment. The client (`stxr-client-app/src/vs/platform/stxrDeployment`)
   already keeps a stable deployment id across stop and restart and has
   `firstStartedAt`, `startedAt`, `stoppedAt`.
2. **The deployment carries the variable binding values.** Today
   `StrategiesService.start` only writes them into the config file. The user
   stated that `StrategiesService.start` goes away and becomes
   `StrategyDeploymentsService.create`.
3. **Application-server timestamps use `{verb}_time`, never `{verb}_at`.**
   The client may name things however it wants; do not copy its naming.
   (Written rule: structure-web/docs/domains/api/structure-api-rfc.mdx.)
4. **Responses follow the existing table / `*_connections` / `expand`
   convention** from `strategies-http.ts` (ListStrategiesQuery around line 250).
   Deployment queries should be able to include the trading-accounts
   connection.
5. **Wildcard list is required:** all deployments for all revisions of a
   strategy, and all deployments across all strategies. The user is not
   convinced by the backtests approach (nil domain id means wildcard,
   `backtests-repository.ts`) but wants a wildcard either way.
6. GCP API design is the reference style. Tech debt is tracked with the
   `[ISS-0AGTK]` marker (5 code hits: strategy-core rust + ts ids,
   `buildSource`, `strategies-service.ts` and `strategies-provision.ts`).
7. The existing `StrategyDeployment` entity (hash id from the Cloud Run service
   name, infra snapshot) must be reworked, not kept as-is.

## Proposal put to the user (not yet decided)

- Two entities: `StrategyDeployment` (stable identity, immutable inputs:
  strategy, strategy revision, bindings, policies, accounts, mode; mutable
  projection: status, latest revision id) and `StrategyDeploymentRevision`
  (one start-to-stop cycle: runtime revision, image, Cloud Run target,
  workflow ids, ready/stop times, status, error, stop reason).
- Old infra entity folded into `StrategyDeploymentRevision`; hash
  `StrategyDeploymentID` dropped; `NewStrategyDeploymentID` renamed to
  `StrategyDeploymentID`; old `strategy_deployments` rows not backfilled.
- Wildcard via `-` path segment (AIP-159) mapped to an explicit scope union in
  the repository, instead of nil ids.
- Cloud Run worker-pool id derived from the deployment revision id.

## Open questions (deferred to the user)

- Name: `StrategyDeploymentRevision` vs `StrategyDeploymentRun` (collision with
  `StrategyRevision` in prose and column names).
- Trading-account exclusivity: one active deployment per account? Does it
  apply to paper accounts?
- Is `mode` (live | paper) persisted on the deployment, derived from accounts?
- Is a strategy-wide "stop all" kept as a bulk operation?
- What happens to `strategies_trading_accounts_connections` rows for
  strategies with no active deployment (migration)?

## Decisions

### D1. Strategy deployment id is a snowflake, not a hash (2026-09-30)

The user does not want a content-addressed (hash) id for `StrategyDeployment`.
The application server allocates a snowflake id before provisioning, the same
way strategies and strategy revisions are allocated.

**Why (user's words):** a hash "introduces additional complexity without much
gain. Yeah, we could have deduplication, but if the user intends to create a
deployment, there is a reason for that."

**Consequences:**
- No "deployment of this revision already exists" check on create. Two
  deployments of one strategy revision with identical bindings and accounts are
  allowed; the second one is the user's intent.
- `computeDeploymentID` in id-wasm (`domain/crates/id/src/lib.rs`, hash of
  strategy id + revision id) and the client's temporary FNV hash of
  `strategyId\0revisionId` (`stxr-client-app/.../stxrDeploymentIdProvider.ts`)
  are retired; the client's `deployment_already_exists` conflict goes away.
- The 128-bit hash `StrategyDeploymentID` (sha256 of the Cloud Run service
  name) is deleted; `NewStrategyDeploymentId` (u64, prefix `strt_depl`) is
  renamed to `StrategyDeploymentId`.
- Any duplicate protection that is still wanted (accidental double submit)
  belongs to the request layer (idempotency key), not to the identity.
- Affects: strategy-core (rust + ts ids, generated code), domain id wasm crate,
  structure-web api (strategies-service start path, deployments service and
  repository, app-db schema), stxr-client-app id provider.

### D2. Deployment create takes a `start_policy`, normalized with backtests (2026-09-30)

`CreateStrategyDeploymentBody` gets the same `start_policy` union as
`CreateBacktestBody` (`structure-web/packages/api/src/backtests/backtest-http.ts`):
`"immediate" | "on_demand" | { scheduled: { start_time } }`. Default is
`immediate`.

**Why (user's words):** "we should normalize the backtest and deployment
regarding the way they start."

**Consequences (proposed shape, follows the backtest service):**
- `create` commits the deployment row in `Pending` with no revision. With
  `immediate`, the service then calls the same code path as `:start`, which
  appends the first `StrategyDeploymentRevision` and creates the start
  workflow. If that second step fails, the deployment stays `Pending` and the
  response reports it, so the client retries with `:start` (backtests return
  `execution: { state }` for the same case).
- `:start` becomes the single "append a revision and start it" primitive.
  Precondition: status in `pending | stopped | error`.
- `scheduled` is accepted by the schema but rejected with FailedPrecondition
  until implemented, as backtests do today.
- This replaces the earlier proposal of creating the deployment, its first
  revision and the workflow in one transaction.

## Findings recorded for later agents

### F1. Platform / runtime version is not part of the DSL 2.0 spec (verified 2026-09-30)

- A published DSL 2.0.0 revision carries `version`, `environment_id`, the
  canonical document and embedded node groups (DEC-0BQ6R D37;
  `structure-web/packages/api/src/strategies/native-revisions.ts` PublishBody).
  The environment id is the pinned DSL environment digest (spec + Structure
  library + catalog, pins E/F/G/H), and it lives on the strategy revision.
- The runtime shell version (`StrategyRuntimeRevision`: git SHA + context of
  the template repo) is NOT in the spec. It comes from application server
  config (`config.strategyRuntimeRevision`) at start time and is recorded on
  `StrategyImage.runtimeRevision`. Template id = f(environment_id,
  build_identity) and does not include it.
- Recommendation put to the user: drop `strategyRuntimeRevisionId` from
  `StrategyDeploymentRevision` and keep only `strategyImageId` (docker digest);
  the runtime revision is reachable through the image row.

### D3. Strategy runtime revision and docker image are pinned on the strategy revision (2026-09-30)

The user rejected keeping the strategy runtime revision (runtime shell version)
in the application server YAML config and rejected putting it on the deployment
revision (supersedes the F1 recommendation of a `strategyImageId` on
`StrategyDeploymentRevision`).

**Why (user's words):** having it in the YAML "is silly, since I have to
redeploy every time there is a new revision." The docker image "is built for
the strategy revision", so "the strategy runtime revision and docker image id
should be pinned to the strategy revision entity."

**Target flow decided:**
1. A release pipeline for the strategy platform builds all the images.
2. The release job then calls an application server endpoint to release a new
   strategy platform version. The version is stored in the database and marked
   as `latest`.
3. The client gets a field to choose the strategy platform version when
   publishing a **strategy revision**. If unspecified, the server falls back to
   `latest`.
4. The chosen runtime revision and the resulting docker image id are stored on
   `StrategyRevision`. `StrategyDeploymentRevision` carries neither; it only
   records what service/workflow ran.

**Affects:** application server config (remove the
`strategy_runtime_revision_*` keys), `StrategyRuntimeRevision` entity and
repository, `StrategyRevision` entity + `strategy_revisions` table, publish
(`NativeRevisions`), start workflow `ensure_image` / `buildStrategyRuntimeImageRef`,
backtests (same image lookup), infra release pipeline, client publish UI.

**Open:** what exactly "builds all the images" means, since strategy images
are per template (per strategy revision build identity) and cannot all be
prebuilt; see the analysis that follows this decision.

### D4. The platform release runs as an activity-worker workflow behind an internal endpoint (2026-09-30)

The release of a strategy platform version is a durable workflow in the
activity worker (a new `WorkflowType`, alongside StrategyBuild / StrategyStart /
StrategyStop / Backtest). An internal application-server endpoint triggers it
("go build the thing"); the workflow builds the images and then calls the
application server endpoints needed to register the release and mark it
`latest`.

**Why (user's words):** "I think that should be the activity worker workflow.
We'll add an internal endpoint to go build the thing and call the necessary
endpoints."

**Actor:** the user expects a system actor of some kind, such as a service
account, for these automated calls, and asked whether that is still good
practice. Answer given: it is; the existing internal endpoints already yield
an actor of type `system` from the static API key + discovery header
(`lib/api.ts` ApiKeyRequired / InternalEndpoint), and Cloud Tasks already
supports attaching a Google OIDC identity token from a service account
(`gcp/tasks.ts` buildInternalOidcHttpRequest). Recommendation: a dedicated
release service account whose identity token the server verifies (audience =
server origin), instead of sharing the worker's static key. Not yet decided.
