---
create_time: 2026-10-01T14:31:46Z
title: "Permissions, roles, IAM service, API keys, Pulumi and the organization model"
summary: "Direction (unconfirmed): Platform->Organization->Project hierarchy with inherited role bindings replaces meta-org; staff bound at Platform node; module contract (node, permissions, audit, ports/events); per-module permission registry compiled to bitsets, only Role names persisted (supersedes SESS-00PH0TQ closed permission set); AccessScope all|within|none as SQL predicate; invitations replace whitelist; dev stack kept for platform-level tests"
related_sessions:
  - SESS-00PH0TQ
---

# SESS-00PHDEJ: Permissions, roles, IAM service, API keys, Pulumi and the organization model

Continues SESS-00PH0TQ. The user wants to turn the accepted RBAC direction
into something specific, and raised one framing concern that shapes
everything below.

## Questions the user brought (2026-10-01)

1. Permissions and roles: how to structure and define them.
2. IAM server: how other services obtain roles and permissions; is this the
   application server's job or a separate iam/auth service.
3. API keys: how to issue internal API keys.
4. Pulumi: how to manage staff permissions and internal API keys from infra.

## Framing constraint stated by the user (2026-10-01)

- Organizations and Projects are coming soon as the resource hierarchy.
- Everything being built to control the application server internally
  (API keys, members, permissions, whitelist) is what any organization will
  want. The user does not want to special-case an internal "meta" org in
  code. Internal scope is only larger: e.g. staff can run the "build strategy
  template" workflow, customers can run deployment and backtest workflows;
  storing the GUI version of the DSL is only for the client app but its access
  model is not different.
- Goal: a model where the internal org is an ordinary org with more grants,
  so multi-tenancy and self-hosting fall out of the same design.

## Decisions

(none recorded yet)

## Facts found while researching (2026-10-01, not decisions)

- No Organization, Project, Tenant, Group, Role, Permission or ApiKey entity
  exists in iam-core, domain, entity-core or structure-web. The only tenancy
  concept is telemetry `ParentType { System, User }`.
- Ownership today is join tables: `user_strategies_connections`,
  `users_trading_accounts_connections`; deployments, revisions and backtests
  scope through the strategy join. DEC-0BZBC defers a `user_id` column.
- Actor is `public | user | system` (`domain/ts/domain/src/actor.ts`), held in
  an async context; handlers call `assertActor("user")`. `GcpCredentialRequired`
  verifies only issuer and audience and discards the service-account email.
  `client_id` from the JWT is dropped. API key compare is `!==`.
  `/api/v0/test:emit-event` has no middleware.
- Workflows (`WorkflowType` string set in structure-web/packages/workflow,
  unused numeric `WorkflowKind` in workflow-core) carry no actor or owner.
- `argus.event` has no actor field; `Subject` names the owning scope.
- Realtime gateway (DEC-0BWMT) already defines an `EntitlementSource` port
  with only an `UnrestrictedEntitlementSource` adapter; group model open.
  SESS-00P9RZK decided permissions are checked only at entry points.
- Infra: no dynamic provider; `GcpMembers` in projects.ts is unused; staff
  grants are hand-written per person in iam.ts; one shared
  `convex-backend-api-key` for every internal caller; dev stack config stale
  (missing members/rotation keys); no `root_principals`.
- Closed-set pattern reference: `iam-core/ts/src/entities/identifier/identifier.ts`
  (numeric const object, display table, `assertf` count check); Rust side uses
  `match` only, no count assertion.

## Proposal on the table (agent, 2026-10-01, NOT accepted yet)

Resource hierarchy with inherited role bindings, GCP IAM shaped:
`Platform (singleton root) -> Organization -> Project -> resource`. A binding is
(principal, role) attached to one node; permissions are inherited downward.
Staff are principals bound at the Platform root; Structure's own strategies
live in an ordinary Organization. No meta-org: the only thing that makes
internal access "larger" is where the binding sits and which roles may be bound
at which level (`bindable_at` on the role). Self-hosting = one Platform root with
one org. Permission names `service.resource.verb`, closed sets in iam-core,
roles are predefined with a static table. Principals: user, service account,
identifier (email binding before the user exists). API keys are credentials of
a service account resource; Google OIDC identity is a second credential kind for
the same service account. IAM stays a module in the application server behind
a port; realtime gateway uses it through `EntitlementSource`. Whitelist becomes
invitations (identifier -> org + role). Pulumi dynamic provider resources:
ServiceAccount, ApiKey, AccessPolicy(node). Would supersede the SESS-00PH0TQ
`read_any` flag: platform-level grant replaces it, audit records the grant
level.

Query shape discussed (agent answer, 2026-10-01, not accepted): bindings loaded
once at auth and attached to the actor; `Iam.scopeFor(actor, permission,
resource_type)` folds them in memory into `AccessScope = all | within {orgs,
projects, resources} | none`; repositories take the scope as a required
argument and render it as the WHERE predicate (`true` for a Platform grant);
every resource row denormalizes `organization_id` and `project_id`; single GET
uses the same predicate and returns 404 for out-of-scope rows.

## Environments vs tenancy (raised by the user 2026-10-01, answer not yet accepted)

User asked whether the "test environment" becomes just the Structure org and
its projects inside production. Agent answer: yes for product-level testing
(paper strategies, backtests, demo users -> invitations into a Structure org
with projects like playground/paper/live); no for platform-level testing
(migrations, snapshot formats, new service revisions, infra changes), which
keeps the dev stack as a second Platform root. Open: per-org quotas (shared
blast radius), org/project ids on Cloud Run labels, dev stack config is stale.

## "Everything a plugin?" (user question 2026-10-01, agent answer not accepted)

Agent framed it as kernel + module contract. Kernel: identity (users,
identifiers, credentials, sessions, service accounts), hierarchy nodes, policy
(permissions, roles, bindings, scope), audit. Module contract: (1) resources
attach to a node and carry ancestor ids, (2) operations are permissions in the
module's namespace, (3) mutations and denials emit audit. Invitations are a
module touching the kernel only through one sign-in port ("may this identifier
create a user, with which bindings"). No runtime loading and no per-org feature
enablement; `bindable_at` covers internal vs external for now.

## Cordis-style modularity (user raised 2026-10-01, agent answer not accepted)

User pointed at the Cordis plugin primer (deepseek-harness) and asked how much
of it applies so that dropping a feature like invitations is a delete, not a
refactor. Agent: copy declared dependencies (typed composition root, module
factory receives only its ports), hook points as ports with a default adapter
(`SignUpPolicy.admit` with open sign-up default; invitations provides the
adapter), events for reactions (argus events topic already exists); skip
effect disposal/hot reload and runtime loading. Module shape: one directory
with manifest (permissions owned, ports needed/provided, events), own schema,
own config section, own routes. Permissions stay a central closed set in
iam-core; module removal retires discriminants. Current coupling named:
monolithic routes.ts, whitelist inlined in auth-service, root-level config
keys like `credit_deposits`.

## Permission registry proposed by the user (2026-10-01, direction, not yet confirmed)

User proposed: a permission storage/aggregator handed to each module; modules
register the permissions they need and the roles they contribute to; role
names stay stable; permissions resolve to a bitset per role; each module
checks its own bits. Agent agreed with one rule: only role names are persisted
or sent over the wire, bit positions are process-local and recompiled per
boot. Shape: Role is the closed set in iam-core (TS + Rust, display table,
count assertion, bindable_at); modules register permissions at composition
time and get typed handles (`registry.module("invitations", {create: {roles:
[...]}})`); registry freezes after composition, duplicate or late registration
fails boot; route registration takes the handle; `GET /iam/roles` serves
resolved permissions to Pulumi/UI/CLI. Realtime gateway unchanged (flattened
entitlements). If confirmed this supersedes SESS-00PH0TQ "permissions are a
closed set in iam-core": only roles are.
