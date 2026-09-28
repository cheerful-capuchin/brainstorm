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
