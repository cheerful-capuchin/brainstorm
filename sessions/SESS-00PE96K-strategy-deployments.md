---
create_time: 2026-09-30T10:00:51Z
summary: "ISS-0AGTK design recorded as DEC-0BZBC (proposed) with plans PLAN-0BZET (server), PLAN-0BZEW (runtime/topics/feeds), PLAN-0BZEY (SDK/client/CLI); no spec: deployments mutable (display_name, description, latest revision pointer), revisions immutable and carry accounts + bindings, :execute (renamed from :start, future rollout) may override them; mode fixed on the deployment, error/logging policy per revision; first_ready_time dropped; StrategyDeploymentRevision name; account exclusive to one active deployment (paper too); keep strategy-wide stop; no data migration, drop old tables; environments out of scope; StrategyDeploymentID is a snowflake, not a hash; create takes start_policy like backtests, default immediate; strategy runtime revision + image pinned on the StrategyRevision (not the deployment), chosen at publish with latest fallback, released via a platform release pipeline that runs as an activity-worker workflow behind an internal endpoint with a system actor; real StrategyDeployment entity + immutable StrategyDeploymentRevision per start/stop; deployment carries variable bindings + accounts; _time naming; table/connection/expand conventions; wildcard list across revisions/strategies; StrategiesService.start replaced by StrategyDeploymentsService.create"
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
- Wildcard via `*` path segment (user chose `*` over AIP-159's `-`, D10) mapped
  to an explicit scope union in the repository, instead of nil ids.
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

### F2. Release pipeline facts and the proposal put to the user (2026-09-30, not decided)

Facts (verified by code exploration):
- No automated release exists in structure-web, infra, structure-strat-template
  or backtest-post-processor. Releasing = template readme recipe: pin
  core/DSL revisions, `just build_builder`, paste builder digest into the
  template `Dockerfile` (needs a second "commit B"), paste that SHA into
  `infra/infra/services/application-server/application-server.ts`, `pulumi up`.
- Four images with different lifetimes: strategy-builder and strategy-runner
  (pinned by digest inside the template Dockerfile), backtest-post-processor
  (infra bake, digest in server config `backtest_post_processor_image`), and
  the per-template strategy image `tmpl-<template>:<runtimeRev>-pp-<digest>`
  built lazily by the StrategyBuild workflow on first start/backtest.
- The server holds exactly one runtime revision, from config, upserted at
  startup in `run.ts`; start and backtest read `config.strategyRuntimeRevision`.

Proposal:
- Evolve `StrategyRuntimeRevision` into `StrategyPlatformRelease` (snowflake
  id; version label; status Building/Available/Failed/Deprecated; template
  commit uri/revision/context; builder, runner, post-processor image digests;
  supported DSL environment ids). `latest` = newest Available by release_time,
  no stored pointer.
- `strategy_revisions` gains `strategy_platform_release_id` (publish chooses,
  latest fallback) and `strategy_image_id`.
- Template Dockerfile takes builder/runner/post-processor as build args so one
  commit = one release.
- New `WorkflowType.StrategyPlatformRelease` in the activity worker: build
  post-processor, builder, runner; smoke-build the dummy strategy; commit.
  Triggered by internal `POST /api/v0/strategy-platform/releases:release`
  (GcpCredentialRequired + discovery header), callback
  `POST .../releases/{id}:commit`. Public list/get for the client picker.
- Remove the four config keys and the startup upsert; StrategyBuild keyed by
  release id (fingerprint sha256(templateId + releaseId), tag without -pp-).
- Recommended: trigger StrategyBuild eagerly at publish; `ensure_image` stays
  as safety net in start/backtest.
- Infra: release service account, activity-worker Cloud Build SA needs writer
  on the `images` Artifact Registry repo (has only `strategies` today).
- Migration: one Available release from current config values; backfill DSL 2
  revisions to it; `strategy_images.runtime_revision` -> release id.

Open for the user: eager build at publish vs lazy; version label passed
explicitly vs derived from the commit.

### F3. Live vs paper is not in the DSL 2 spec nor in the runtime regimes (verified 2026-09-30)

- DSL 2 (`dsl-processor-core/docs/dsl-spec-next.json`, DEC-0BQ6R) has no
  live/paper notion. `account_id` is an opaque platform id parameter.
- The runtime regime set is closed: `live` and `backtest` only
  (`dsl-runtime/crates/dsl-runtime-contracts/src/runtime_config/regime.rs`
  RegimeKind). A paper deployment runs the `live` regime.
- Paper vs live is a property of the trading account
  (`TradingAccountType::Paper`, entity-core) and is applied at execution:
  trade_v2 order requests carry `is_paper` and route to sim-gw instead of the
  venue. DEC-0BQ6R item 214 notes the current platform check "deployments use
  paper accounts only".
- Consequence for the design: a deployment `mode` is a derived attribute of
  its (immutable) account set, not a runtime input. Persisting it is a
  denormalization for list filters and UI colour (REF:client-views wants it).

### D5. Environments (Stripe-sandbox style) are out of scope for now (2026-09-30)

The user explored a disposable "environment" container (a trader's testing
pipeline creates an environment, creates accounts and deployments in it, and
discards the whole environment at the end) and then decided not to spend time
on it now. Live vs paper stays a derived `mode` on the deployment, computed
from the account set at create (F3), with the "no mixed live and paper
accounts" rule.

**Why (user's words):** "forget about the environments for now, I don't want
to spend time thinking about it."

**Kept for later agents (proposal only, undecided):** an `Environment` entity
(kind Live | Sandbox, status Active | Deleting | Deleted) owning trading
accounts and deployments but not strategies or revisions; `environment_id` on
accounts and deployments as a field and list filter, not a path parent; one
undeletable live environment per user; delete as a durable cascade workflow
(stop deployments, soft-delete deployments and accounts, purge sim-gw state);
open points were ClickHouse data purge vs retention, and sandbox caps or
`expire_time`.

### D6. Per-start record is named `StrategyDeploymentRevision` (2026-09-30)

Chosen over `StrategyDeploymentRun`. Columns stay fully qualified
(`strategy_revision_id` vs `strategy_deployment_revision_id`) to avoid
confusion with `StrategyRevision`.

### D7. A trading account is exclusive to one active deployment (2026-09-30)

An account may be attached to at most one non-terminal deployment at a time.
No exemption for paper accounts. History is kept: the connection row survives
after the deployment reaches a terminal status; the rule is enforced in the
create/start transaction (lock the account rows, reject with
`TradingAccountBusy` if another non-terminal deployment holds one).

### D8. Keep a strategy-wide stop as a bulk operation (2026-09-30)

Stop-by-deployment-id stays the primitive. A strategy-level bulk stop remains
on top of it (stops every non-terminal deployment of the strategy).

### D9. No data migration; drop and recreate tables (2026-09-30)

**User's words:** "drop that shit, we're in the demo stage. We can drop the
whole db if need to. Ideally, just drop the unnecessary table and create a
new one."

Consequences: no backfill of active runs, no copying of
`strategies_trading_accounts_connections`, no compatibility window for v1
workflows, no dual-publishing of revision-status events. The migration drops
`strategy_deployments` and `strategies_trading_accounts_connections`, drops
`strategies.provisioned_revision_id`, `strategy_revisions.status` and
`idx_strategy_revisions_by_status`, and creates `strategy_deployments`,
`strategy_deployment_revisions` and
`strategy_deployments_trading_accounts_connections`. Existing deployed
strategies must be stopped (or the Cloud Run resources deleted) before cutover.

### D10. Wildcard path segment is `*`, not `-` (2026-09-30)

List paths use `*` for the wildcard parent segment:
`GET /api/v0/strategies/*/revisions/*/deployments` and
`GET /api/v0/strategies/{s}/revisions/*/deployments`. `strategies/*/revisions/{r}`
is still rejected (revision ids are only unique within a strategy).

**Why:** user preference over the AIP-159 `-` convention. Note for
implementers: `*` must be URL-encoded as `%2A` by clients that percent-encode
path segments; Hono route params accept it either way.

### D11. Decision record in the knowledge base (2026-09-30)

Written as DEC-0BZBC (`knowledge-base/docs/decisions/records/DEC-0BZBC-strategy-deployment-and-deployment-revision-entities.md`, branch `dec-0bzbc-strategy-deployment-entity`, status proposed, uncommitted). The user asked for a DEC record covering the `StrategyDeployment` and
`StrategyDeploymentRevision` entities and the RPC contracts, written as
TypeScript contracts with JSDoc that explains what each property is (when not
obvious) and why it exists. The platform runtime revision / release work is
excluded from that record for now.

### D12. Call topology added to DEC-0BZBC (2026-09-30)

The user asked for the topology / call stack of every deployment action in the
codebase-explorer node syntax (`Type::method <tags> [intent] path:line`),
exactness not required. Added as the "Call topology" subsection of DEC-0BZBC:
create, start (plus the StrategyStart re-entry), commit status, stop (plus
the StrategyStop re-entry), stop_deployments, list/get/list_revisions/
get_revision, delete. There is no `update` action: deployment inputs are
immutable. Existing nodes cite structure-web `path:line`; planned nodes are
marked `(new)`.

### D13. Three corrections to DEC-0BZBC (2026-09-30)

- `StrategyDeployment::Status_isStartable` is renamed to
  `StrategyDeployment::verifyStart` (Result-returning business rule, like
  `Backtest.verifyBacktestArgs`); `verifyDelete` added for symmetry (agent's
  extension, not explicitly requested).
- The internal status callback is a resource-shaped custom verb, not a flat
  route: `POST /api/v0/strategies/{s}/revisions/{r}/deployments/{d}/revisions/{dr}:commit_status`,
  operation `strategy_deployments.commit_revision_status`, ids in the path,
  body `CommitStrategyDeploymentRevisionStatusBody` (service_name,
  service_generation, status, error). User's words: "this should change to
  follow the same path as the POST .../deployments/{d}:start".
- `StrategiesService::checkNativeStart` clarified: it is the existing wrapper
  around `NativeRevisions.checkStart` (DSL 2 core validates bindings against
  the revision's declarations) plus `validateMarketReferences` (instruments and
  assets must be known to the application server); shared with backtests, so
  it moves out of StrategiesService to a shared module when `start` is deleted.

### D14. Revision operations live in their own namespace (2026-09-30)

`strategy_deployments.commit_revision_status` becomes
`strategy_deployment_revisions.commit_status` (user). Applied to the sibling
operations as well: `strategy_deployment_revisions.list` and
`strategy_deployment_revisions.get` replace `strategy_deployments.list_revisions`
/ `get_revision` (agent's extension for consistency). Handler namespace
`StrategyDeploymentRevisionsHttp`, service `StrategyDeploymentRevisionsService`.

Note on the "native" prefix (user question): it comes from DEC-0BQ6R /
DEC-0BSX5 "Execute DSL 2 Natively", where it separated the DSL 2 path compiled
by the Rust core from the retired DSL 1.1 bridge. With 1.1 gone (2026-09-27
cutover) the prefix carries no information; the new code should use
`StrategyRevisions.checkStart` / `checkStart` without it.

### D15. Deployments are mutable; configuration lives on the immutable revision (2026-09-30)

Supersedes the inputs-on-the-deployment model of the first DEC-0BZBC draft.

**User's words:** "You should be able to modify the trading accounts and the
variable values when restarting the deployment. We should preserve those
settings in the strategy deployment revisions. Then, when displaying the
deployment performance, we can plot on the time chart when you made updates
to the variables and how the performance of a particular deployment has
changed. You should be able to add the display name and description to each
of the deployments. Therefore, the deployments are mutable, the deployment
revisions are immutable. The deployment has pointer to the latest running
revision. Therefore, when you run strategy_deployments::start you can
optionally overwrite the previous variable values or trading accounts."

Applied in DEC-0BZBC:
- `StrategyDeployment`: id, strategy_id, strategy_revision_id (still
  immutable: a different strategy revision is a different deployment),
  display_name, description, latest_revision_id, projected status and mode,
  first_ready_time. New `update` operation (PATCH) and `Updated` event with
  values/prev_values, mirroring Strategy.
- `StrategyDeploymentRevision`: mode, error_policy, logging_policy,
  strategy_variable_bindings, strategy_spec_arguments, plus the run fields.
  Account connections keyed by (deployment, revision, account).
- create always writes revision 1 (Pending); `:start` body has optional
  trading_account_ids / bindings / policies; absent fields carry the latest
  revision's values forward. A Pending never-launched revision that gets
  overridden is closed with stop_reason `Superseded` (agent's design to keep
  revisions immutable; not explicitly requested).
- Chart annotations come from `strategy_deployment_revisions.list`
  (create_time + diff between consecutive revisions); no extra endpoint.
- Exclusivity (D7) now reads "one non-terminal deployment revision per
  account"; carrying an account forward on restart is not a conflict.

Resolved by D16: mode never changes.

### D16. Mode and policies are fixed on the deployment; `start` becomes `execute`; `first_ready_time` dropped (2026-09-30)

- **Mode never changes** (user: "if the deployment used to be paper, it
  should always remain paper, otherwise all the stats are fucked"). `mode`
  lives on `StrategyDeployment`, derived from the first revision's accounts
  at create; every later revision's accounts must match it
  (`ACCOUNT_MODE_MISMATCH`). Removed from the revision.
- **Arguments stay on the deployment** (user: "I don't think you can change
  the arguments. So, I'd keep 'em on the deployment entity"). Interpreted as
  `error_policy` and `logging_policy`: they move to `StrategyDeployment`,
  fixed at create, not overridable on execute. `strategy_variable_bindings`
  stay on the revision (changeable per D15); the resolved
  `strategy_spec_arguments` stay on the revision because they depend on the
  bindings. If "arguments" meant something else, this needs correcting.
- **Superseded** stop reason for a re-configured never-launched Pending
  revision: confirmed by the user ("superseeded is fine").
- **`:start` renamed to `:execute`** (`strategy_deployments.execute`,
  `ExecuteStrategyDeploymentBody`, `verifyExecute`, `DEPLOYMENT_NOT_EXECUTABLE`,
  `StrategyDeploymentsService::execute`). User's reason: in the future a new
  revision will be created and rolled out without requiring the user to stop
  the previous revision first. `start_policy` on create keeps the backtest
  name (D2). The `Starting` status and the `StrategyStart` workflow keep their
  names.
- **`first_ready_time` dropped** from the deployment (user: "wtf is this?").
  It was the earliest `ready_time` over the revisions, mirroring the client's
  `firstStartedAt` (client DEC-0BRB6: performance life starts at the first
  start). It is derivable from `strategy_deployment_revisions.list`; noted
  in the revisit triggers as a possible projection if the performance query
  needs it.

### D17. Error policy and logging policy are per deployment revision (2026-09-30)

Corrects the D16 interpretation of "arguments". The user meant the base
strategy spec arguments (the strategy revision's own parameters), which
already live on `StrategyRevision` and are not repeated on the deployment.
`error_policy` and `logging_policy` move back to
`StrategyDeploymentRevision`, are part of the create configuration, and may
be overridden on `:execute`. Only `mode` and `strategy_revision_id` stay fixed
on the deployment.

### D18. Implementation prerequisites answered (2026-09-30)

1. Runtime account lookup: the generated runtime config's live regime section
   carries the revision's `trading_account_ids`; the runtime loads those by
   id (`accounts_scope`) instead of `strategies_scope`, which is removed.
2. NATS topics keyed by strategy id on the deployment path (starting with
   `TargetExecutorTopic::TargetPositionStatusUpdate`) are re-keyed by
   deployment id. In scope.
3. Trading account events feed: break it. `strategy_attached/detached`
   become `strategy_deployment_revision_attached/detached` with strategy id,
   strategy revision id, deployment id, deployment revision id. event-gw fold
   follows.
4. `deployment_revision_id` goes into the runtime (LiveRegimeConfig, telemetry
   source, Rust and TS subjects).
5. Rust rename `NewStrategyDeploymentId` -> `StrategyDeploymentId` now; new
   `StrategyDeploymentRevisionId`.
6. Strategy revision delete is blocked by any deployment (history), via the
   existing `DeleteRequiresNoDeployments` reason.
7. Backtests bind accounts by id only; no exclusivity.
8. Delivery: server first, then regenerate application-server-client, then fix
   the client and CLI. One feature, three steps.
9. Client ClickHouse deployment queries filtering by deployment id: not a
   requirement of this work.

All folded into DEC-0BZBC as "Cross-repository effects" and "Delivery order".
Still open before a plan: governing SPEC (or waiver), DEC status accepted,
REF:strategy provenance row, Linear ticket for the plan, and committing the
knowledge-base branch.

### D19. Execution plans written for agents, no spec (2026-09-30)

User: plans go to `knowledge-base/docs/execution-plans/records`, written for
Claude Opus agents, format optimized for agents; no governing SPEC ("I think
they are no longer useful"). Traceability mode `request_backed` against the
new Requirement index (`BZBC-01`..`BZBC-36`) added to DEC-0BZBC.

Written (all `status: draft`, `linear_issue: none`, uncommitted on the
knowledge-base branch `dec-0bzbc-strategy-deployment-entity`):
- PLAN-0BZET Strategy Deployment Entities, Application Server (strategy-core
  ids and TS entities, entity-core, domain, app-db, api, workflow, activity
  worker, internal SDK). 9 tasks.
- PLAN-0BZEW Strategy Deployment Runtime, Topics And Feeds (Rust consumers of
  the rename, dsl-runtime LiveRegimeConfig, template account loading,
  messaging/strats_v2 topic re-key, data-feed-definitions feed, event-gw
  fold). 6 tasks.
- PLAN-0BZEY Strategy Deployment SDK, Client And CLI (regenerate
  application-server-client, client deployment platform, workbench and agent
  surface, CLI). 4 tasks.

Gaps left for the user: the `structure` CLI source is not in the workspace
(PLAN-0BZEY T4 says locate it); Linear tickets for the three plans; DEC
status still proposed; REF:strategy provenance row; pre-existing catalog
failure on duplicate id DEC-0BRC4 (two files) blocks `just catalog` until
fixed.

### D20. Implementation answers while the plans ran (2026-10-01)

Asked by the implementing agents, answered by the user, recorded in the
DEC-0BZBC Revisit Trigger:
- The subject child key is `strategy_deployment` on both sides; the Rust
  `StrategyDeploymentSubject` key was renamed.
- `idx_strategy_deployment_revisions_by_service` is dropped: a worker-pool
  name cannot be indexed without normalizing it; the lookup parses the ids
  out of the worker-pool id.
- Workflows take a completion callback: the caller supplies a context, the
  workflow engine calls back with the result and the context when the
  workflow finishes (completed or failed). Strategy start and stop pass the
  four ids and commit `failed` on the revision on failure.
- Trading account feed: `StrategyAttached/Detached` become
  `StrategyDeploymentAttached/Detached` carrying the strategy, strategy
  revision, deployment and deployment revision ids.
- Every reference to a deployment carries strategy id, strategy revision id
  and deployment id, plus the deployment revision id when one applies. "A
  deployment id without strategy id is useless." Topic addresses and
  in-memory keys stay as they are; message payloads carry the ids.
- The executor status update payload carries the four ids; it names whoever
  requested the target position, and a running strategy ignores updates not
  addressed to its own deployment revision.
- The `structure` CLI no longer exists; its skills were removed and
  PLAN-0BZEY T4 dropped.

### D21. A revision exists only once the deployment is executed (2026-10-01)

User: "if we don't start the deployment, the deployment revision is not
created"; "store the info on the deployment as well". Create stores the
deployment with its configuration and creates no revision. `:execute` merges
overrides onto the deployment's configuration, saves it, inserts a revision
snapshotting it and launches it. Revisions are never pending; `Superseded`
and the supersede step are gone. An account is not reserved by creating a
deployment, only by a revision that has not ended.

### D22. Accounts are the deployment's `account_id` parameters (2026-10-01)

Product owner: every trading account bound to a deployment is exclusive to
it; another strategy that needs an account id in a data feed gets it through
indirection. The server does not inspect target positions or evaluate the
graph: the values of every `account_id` parameter (bound or literal) are the
deployment's accounts. `trading_account_ids` is removed from the bodies and
the stored configuration, and the deployment-level account connection table
is dropped. "One account per venue" is explicitly not a rule. A strategy
shows no status derived from its deployments ("a strategy has many
deployments").

### D23. No status on the deployment; `error` becomes `failed` (2026-10-02)

User: the deployment status mixed "never ran" (`pending`) with run states
and made the client invent `stopped` and `error`. The deployment has no
`status` and no copied latest-revision status ("this is why we have
connections and expansions"); a client that needs the run state requests the
`latest_revision` expansion. A deployment that never ran has no latest
revision. The revision status `error` is renamed `failed`. The list
endpoint's `status` filter is dropped; "the client will filter whatever it
needs". Server guards (archive, strategy-wide stop, execute, delete) read the
revisions.

### D24. Performance over account moves (2026-10-02)

When an execute moves a deployment to other accounts, its performance values
each revision's accounts over that revision's run, and the deployment's life
joins them (option b).

### D25. Deployment configuration is stored as a local, versioned protobuf (2026-10-02)

User: the way configuration is stored differs from the way it is
transmitted; no JSON, and no import of msg-schemas. Requirements: versioned,
schema-backed and structured, supported by JS. Chosen: a protobuf message
local to structure-web (`packages/api/src/strategies`), with its own storage
types and generated TS, stored as one `strategy_config bytea` column on
`strategy_deployments` and `strategy_deployment_revisions`, replacing
`error_policy`, `logging_policy` and `strategy_variable_bindings`. The top
message is a `oneof` of versions (`v1`); a change of shape is a new version
with an upgrade function on read. Alternatives weighed: jsonb + zod
(rejected: no JSON), Avro, MessagePack + zod, FlatBuffers. The revision's
`strategy_spec_arguments` stays a separate column for now (assistant
default, matches backtests and strategy revisions).
