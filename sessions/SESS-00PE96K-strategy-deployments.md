---
create_time: 2026-09-30T10:00:51Z
summary: "ISS-0AGTK design: StrategyDeploymentID is a snowflake, not a hash (no dedup of identical deployments); real StrategyDeployment entity + immutable StrategyDeploymentRevision per start/stop; deployment carries variable bindings + accounts; _time naming; table/connection/expand conventions; wildcard list across revisions/strategies; StrategiesService.start replaced by StrategyDeploymentsService.create"
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
