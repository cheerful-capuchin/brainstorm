I want you to spawn workflows to implement the strategy deployments.
You can orchestrate the worklfows how you see fit. The key is that the tasks are completed

## workflow one:
You are implementing PLAN-0BZET "Strategy Deployment Entities, Application Server".

Workspace: /Users/doichevkostia/work/stxr/workspace (git submodules; each repo has a justfile).
Plan: knowledge-base/docs/execution-plans/records/PLAN-0BZET-strategy-deployment-entities-application-server.md
Decision it implements: knowledge-base/docs/decisions/records/DEC-0BZBC-strategy-deployment-and-deployment-revision-entities.md
Decision history (why things are the way they are): brainstorm/sessions/SESS-00PE96K-strategy-deployments.md

Read, in this order, before touching code: the plan (all of it), the decision (all of it, especially Domain entities, Lifecycle, Database schema, RPC contracts, Call topology, Requirement index), then the standards the plan's "Agent Instructions" list. Follow the plan's tasks T1..T9 in order; T1 is in strategy-core and domain, the rest in entity-core and structure-web.

Rules:
- The decision is the contract. If a task needs behaviour the decision does not define, stop, append the question to the decision's "Revisit Trigger" section, and tell me. Do not invent it.
- Delete the old model; no compatibility shims, no deprecated aliases (BZBC-11).
- Every task ends with the repo's `just check` green for the packages touched and the task's proof tests written and passing (they must have been seen failing first).
- Commit per task in each repo with the message prefix "[PLAN-0BZET T<n>]". Never push. Never edit knowledge-base except the plan's status field and the decision's Revisit Trigger.
- Two places depend on the sibling plan PLAN-0BZEW (the runtime regime type in T5 step 4, the feed events in T8 step 2). If that plan has not landed, leave the `// [PLAN-0BZEW]` marker exactly as the plan says and continue.
- Postgres for api tests comes from packages/api/src/test/db.ts; if no database is reachable, say so and stop rather than skipping tests.
- Do not start PLAN-0BZEW or PLAN-0BZEY work.

When done, or blocked: report per task what changed (files), which proofs exist, the exact `just check` commands run and their result, and every open question you appended to the decision.


## workflow two:
You are implementing PLAN-0BZEW "Strategy Deployment Runtime, Topics And Feeds".

Workspace: /Users/doichevkostia/work/stxr/workspace (git submodules; each repo has a justfile; .cargo/config.toml patches strategy-core to the local checkout).
Plan: knowledge-base/docs/execution-plans/records/PLAN-0BZEW-strategy-deployment-runtime-topics-and-feeds.md
Decision it implements: knowledge-base/docs/decisions/records/DEC-0BZBC-strategy-deployment-and-deployment-revision-entities.md (sections Cross-repository effects, Infrastructure identity, Requirement index)
Decision history: brainstorm/sessions/SESS-00PE96K-strategy-deployments.md

Precondition: PLAN-0BZET task T1 (strategy-core Rust ids: StrategyDeploymentId, StrategyDeploymentRevisionId, subject and source with the revision id) must be committed in strategy-core/rust. Check `rg -n "StrategyDeploymentRevisionId" strategy-core/rust/src` first; if it is absent, stop and tell me.

Read the plan and the decision sections above before editing. Follow tasks T1..T6 in order. All work is Rust across feed-info, data-feed-core, strats_v2, dsl-runtime, messaging, structure-strat-template-core, data-feed-definitions, event-gw.

Rules:
- No `dyn Trait`; generics. Closed sets are enums with exhaustive matches.
- Lint one crate at a time with `cargo clippy -p <crate> --no-deps`; the workspace clippy fails on unrelated pre-existing lints.
- Never add a git dependency on a sub-crate; the patch table only covers facade crates.
- Regenerated artifacts (data-feed-definitions `just generate`, event-gw snapshot with the pinned seed) are committed deliberately; if a snapshot changes, explain why in the commit message.
- Each task ends with the repo's `just check` (or the crate's `check-rs-*` target) green and the task's proof tests passing.
- Commit per task per repo with the prefix "[PLAN-0BZEW T<n>]". Never push. Never edit knowledge-base except the plan's status field and the decision's Revisit Trigger.
- If a task needs behaviour the decision does not define, stop, append the question to the decision's Revisit Trigger, and tell me.

When done, or blocked: report per task the files changed, proofs, the check commands and results, whether the trading account feed id changed (T5) and the new event names, and every open question.


## workflow 3:
You are implementing PLAN-0BZEY "Strategy Deployment SDK, Client And CLI".

Workspace: /Users/doichevkostia/work/stxr/workspace.
Plan: knowledge-base/docs/execution-plans/records/PLAN-0BZEY-strategy-deployment-sdk-client-and-cli.md
Decision it implements: knowledge-base/docs/decisions/records/DEC-0BZBC-strategy-deployment-and-deployment-revision-entities.md (sections RPC contracts, Call topology, Cross-repository effects, Delivery order)
Decision history: brainstorm/sessions/SESS-00PE96K-strategy-deployments.md

Precondition: PLAN-0BZET through task T6 is committed in structure-web and a local application server from that branch is running (you need it for `just generate_client` in application-server-client, with BACKEND_DISCOVERY_KEY and BACKEND_BASE_URL set). Verify with `curl` that `GET /api/v0/strategies/*/revisions/*/deployments` exists; if not, stop and tell me.

Read the plan, the decision sections above, and the client's AGENTS.md, ARCHITECTURE.md, CONTRIBUTING.md and docs/decisions/records/DEC-0BRB6-*.md before editing. Follow tasks T1..T4 in order: T1 in application-server-client, T2 and T3 in stxr-client-app, T4 for the CLI.

Rules:
- The server representation is the truth: the client never invents a deployment id or a status. Delete the local configuration file, the hashed id provider and the ClickHouse start-time query as the plan says.
- Keep IStxrDeploymentService as the seam for the workbench; rename start to execute through the channel, main service and agent platform.
- Record client-only choices as a decision in stxr-client-app/docs/decisions (the client repo keeps its own records); do not put them in knowledge-base.
- Run the client's own checks and the tests of every platform folder touched; the manual acceptance flow in T2 must be performed against the local server and reported.
- Commit per task per repo with the prefix "[PLAN-0BZEY T<n>]". Never push. Never edit knowledge-base except the plan's status field and the decision's Revisit Trigger.
- T4: the `structure` CLI source is not in this workspace. Before T4, ask me for its repository; do not guess.
- If a task needs behaviour the decision does not define, stop, append the question to the decision's Revisit Trigger, and tell me.

When done, or blocked: report per task the files changed, the tests run and results, the manual flow outcome (create, execute with override, stop, delete, list showing two deployments of one revision), and every open question.


## Context
- Session file: brainstorm/sessions/SESS-00PE96K-strategy-deployments.md (see decision-log skill)

I want to fix the tech debt we've recorded in the knowledge base when it comes to the strategy deployments.
Currently, the stxr-client-app and the application server (structure-web/packages/api) mock the "strategy deployment" entity, since it doesn't exist.
I want to fix that and create the real entity. Currently, we already have the Strategy Deployment entity in strategy-core/ts/src/entities/strategy_deployment/strategy_deployment.ts
and service in structure-web/packages/api/src/strategy-deployments/strategy-deployments-service.ts.
However, this entity was representing the old idea of tracking the infra resources.
So, apart from creating the necessary entity for representing a strategy deployment (domain entity), we need to rework
the existing entity that would track the infra resources for those deployments.

I think the main resource is [NOTE-09412: Introduce Strategy Deployment](knowledge-base/docs/notes/records/NOTE-09412-introduce-strategy-deployment.md)
The intended model was:

- `Strategy` stays the stable container; `StrategyRevision` stays an immutable input.
- Each start creates a deployment with its own ID, revision, effective runtime arguments, account attachments, service, status, and errors.
- Create the deployment before provisioning starts. Use its ID across infrastructure, workflows, runtime config, telemetry, feeds, logs, and client state.
- Attach trading accounts to a deployment, not the strategy.
- Start and stop a specific deployment by ID; don’t use revision status or a strategy-level pointer as the lifecycle control.
- Migrate active runs and account attachments, then retire the old strategy/revision lifecycle fields and APIs.

The issue tracking that work is [ISS-0AGTK: Introduce Strategy Deployment As Runtime Entity](knowledge-base/docs/issues/records/ISS-0AGTK-introduce-strategy-deployment-as-runtime-entity.md), linked to Linear ENG-1881.
The client app already has some ideas about the strategy deployments as well in `stxr-client-app/src/vs/platform/stxrDeployment`.

The domain id is already built in strategy-core/rust/src/entities/strategy_deployment.rs.
You can probalby track the tech debt using the `[ISS-0AGTK]` marker.

I think GCP APIs are a good example to follow when it comes to design

## Requirements

### 1. I don't want to lose any information when it comes to the restarts of the deployment
In the current [StxrDeployment](stxr-client-app/src/vs/platform/stxrDeployment/common/stxrDeployment.ts) the client has a field
"first started at", "stopped at", etc.
I think the right thing to do would be to introduce an entity like "deployment revision" that tracks all the times the user has
restarted the same deployment.
The deployment revisions are immutable and just give us the history of what was going on.

### 2. Strategy deployment should carry the values of the variable bindings
Currently, the `StrategiesService::start` structure-web/packages/api/src/strategies/strategies-service.ts:1135
just creates the config file, but doesn't really persist the variable bindings in a useful way for the deployment to be restarted.
Generally, the `StrategiesService::start` will go away and instead it would be `StrategyDeploymentsService::create`

### 3. All the "{}_at" timestamps should be aligned with convention of "{}_time".
This is in the application server. The client can do whatever it wants, but do not follow its naming

### 4. When returning responses, we should follow the expansion and connection ideas from the existing APIs in structure-web/packages/api/src/strategies/strategies-http.ts:250
When querying the deployments, we'll probably want to include the trading accounts connection.

### 5. There should be wildcard list operation for the deployments
The user may request all the deployments for all the revisions within a strategy
The user may request all the deployments across all the strategies

We should be able to satisfy those. I think we have something like this in the backtests-service, where if id is nil, then we fallback to wildcard
structure-web/packages/api/src/backtests/backtests-repository.ts

I'm not sure that that's the best approach, but I badly want a wildcard list operation, so we have to figure something out.

## Questions

### 1. What's the structure of the strategy deployment and strategy revision entities?
I want you to show me the domain entity in TypeScript and the database schema.

### 2. How do we handle the old strategy deployment entity?
Do we just create the strategy deployment revision that includes the infra information or do we have a different entity?

### 3. What's the RPC contract?
What actions can you do with the strategy deployment?
What actions should change in the strategy revision and strategies services?


---

### 4. Activity Worker?
