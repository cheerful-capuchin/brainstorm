---
create_time: 2026-10-01T10:56:23Z
summary: "Email+OTP sign-in: email as Identifier type; whitelist by identifier in DB; RBAC accepted: principal -> role_bindings -> static role->permission table -> route check -> ownership in domain; closed sets in iam-core; root principals in config; Pulumi plan: infra-deployer SA + dynamic provider (AccessPolicy, ApiKey), bindings in infra access.ts; OTP, email provider open"
related_sessions: []
---

# SESS-00PH0TQ: Email OTP sign-in, database whitelist, internal access

## Decisions (stated by the user, 2026-10-01)

### Email + OTP sign-in
- Add a new authentication method: the user enters an email, receives a one-time
  code by email, and signs in with it.
- Email becomes a new kind in `Identifier.Type` (`iam-core`, TS entity at
  `ts/src/entities/identifier/identifier.ts`). The user designed the Identifier
  entity for this: several kinds of identifiers bind to one User.
- The auth service in `structure-web` (`packages/api/src/auth/auth-service.ts`)
  is extended to handle sign-in with email, next to the existing Solana
  wallet sign-in.

### Whitelist
- The signup whitelist must hold identifiers, not wallet pubkeys. Today
  `verifyChallenge` looks up `config.creditDeposits` by the raw identifier value
  (wallet address); the user calls this out as the thing to fix.
- The whitelist is removed from the YAML config (`credit_deposits`) and is
  maintained in the database, with endpoints to modify it.

### Internal access
- Changes to the whitelist should be attributable, ideally with audit logs.
- A shared API key is the "lazy option" and the user considers it unstable.
  Treat it as not chosen.

## Open questions (not decided)

- How the OTP is generated, stored and verified. The user suggested taking
  inspiration from openauth (anomalyco/openauth).
- Which email provider to use. Infra is on GCP; the user asked whether Google
  has a first-party service or an external one is needed.
- How permissions are managed inside the platform. The user's candidate:
  an Organization entity, users hold memberships in organizations, and a
  reserved Structure organization id grants full platform access (whitelists,
  settings, starting jobs). The user asked whether this is valid or whether
  there is a better way. Not accepted yet.

## Facts found while researching (2026-10-01, not decisions)

- Knowledge base: REF:iam describes Identifier/User; DEC-0BEKM and DEC-0BWMT
  (both proposed) say an authenticated user belongs to a group and entitlements
  attach to the group, and leave open what identifies a group. DEC-08NXH leaves
  open who writes admin updates and with what audit. No records exist on
  whitelist, organizations, roles, audit log or email.
- Application server actors are `public`, `user`, `system` only. Internal routes
  use a shared API key, some also a Google OIDC token whose identity is
  discarded. `argus.event` carries no actor.
- The whitelist is read in one place only, and only when no user exists yet for
  the identifier. Deployed environments share one hard-coded list in the infra
  repo's application-server service definition.
- No email sending code exists anywhere. GCP has no own transactional email
  service. stxr.io mail is on Google Workspace and DNS is on Cloudflare. A
  Cloudflare Access check for `@stxr.io` staff emails already exists in the
  structure-updates worker.
- openauth's code provider: 6 digits from `crypto.getRandomValues` with
  rejection sampling, constant-time compare, pending code kept in an encrypted
  cookie for 24h, no attempt limit.

The agent's recommendations were given in the conversation and are not accepted
yet: server-side OTP challenge row with expiry and attempt limit; a dedicated
transactional email provider behind a port; staff identity from the company
identity provider as a new actor kind with platform roles, kept separate from a
customer Organization/Membership model.

## Direction added by the user (2026-10-01, later in the conversation)

- The system actor gains more properties, at least a `principal` naming the
  calling service or key.
- API keys stay for internal services. The desired end state is that the
  application server issues the API keys itself, and the "super option" is
  Pulumi support so an access token can be generated per piece of infra.
- Not decided: key format, permission set, whether GCP OIDC identity replaces
  keys for in-GCP callers.

Facts: today one shared `convex-backend-api-key` (random password in Secret
Manager) is handed to application-server, activity-worker, target-exec, sim-gw,
drift position-server and strategy containers; most Cloud Run services run as
the same `cloud-run` service account; the infra repo has no Pulumi dynamic
provider yet.

## Accepted access-control model (user confirmed 2026-10-01)

The user restated the model and asked to persist it. Treat it as the agreed
direction for platform authorization. Not yet a knowledge-base record.

Request flow:
1. Authenticate the credential (platform JWT, Google identity token,
   Cloudflare Access assertion, or issued API key) into a principal.
2. Load the principal's active role bindings from the database.
3. Expand roles into permissions through a static table in code.
4. At the route, check that the required permission is present; declare the
   required permission where the route is registered, next to the auth
   middleware, so no route can omit it. Handlers receive an actor that has
   already passed.
5. In the service/domain layer, apply ownership: a resource is modified only by
   a principal in its owner set, enforced as a SQL predicate. Holding the
   permission to modify strategies does not allow modifying a strategy owned by
   another user or organization.

Definitions and storage:
- Permissions and roles are closed sets in `iam-core` (TS and Rust), following
  the `Identifier.Type` pattern: integer discriminants, display table, count
  assertion. Role -> permissions is a static table in code. Adding either is a
  code change.
- Persisted tables: `role_bindings` (principal_type, principal_value, role,
  created_by, create_time, revoke_time) and `api_keys` (id, secret_hash, label,
  roles, created_by, create_time, expire_time, revoke_time, last_used_time).
  Store integer discriminants, append-only variants; an unknown role in a row
  is denied and alerted.
- Root principals live in the application-server config rendered by Pulumi,
  not in the database. Ideally the only root is a dedicated deployer service
  account that humans impersonate; the GCP IAM impersonation binding and its
  audit logs are the authority chain for "who is root".
- Human role bindings are data written through an internal endpoint by the
  deployer identity from the infra repo (Pulumi dynamic provider), so changes
  go through pull requests and `pulumi up`.

Staff and ownership:
- Staff never bypass ownership silently. Acting on another owner's resource
  requires a separate explicit permission (for example `strategies.read_any`),
  passed down to the repository as a flag, and is visible in the audit log.
- Organization + Membership, if introduced, is the owner model for customer
  resources (members with an org role form the owner set), not the platform
  admin model.

Audit: every mutation and every denial is an `argus.event` carrying the
principal and the permission; `argus.event` must gain an actor field.

## Pulumi plan for permissions and API keys (user asked to persist, 2026-10-01)

Agreed as the plan for managing role bindings and API keys from the infra
repo. Pieces, in dependency order:

1. Application-server endpoints, internal, authenticated with a Google identity
   token whose audience is the server URL (same check Cloud Tasks uses). The
   principal is the service-account email in the token and must be listed in a
   new `root_principals` config key rendered by Pulumi. Each call emits an
   audit event with that principal.
   - Access policy: one declarative endpoint that replaces the full set of role
     bindings, guarded by an etag (GCP IAM setIamPolicy semantics).
   - API keys: create (returns secret once), read, revoke by id.
2. Deployer identity: service account `infra-deployer` in `infra/infra/iam.ts`;
   staff in `GcpMembers` get `roles/iam.serviceAccountTokenCreator` on it;
   stacks set `gcp:impersonateServiceAccount` so the GCP provider deploys as
   the deployer; the deployer email is rendered into `root_principals`.
   Impersonation is visible in the IAM audit logs already enabled.
3. Dynamic provider in TypeScript in the infra repo with two resource types:
   - `AccessPolicy` (inputs: bindings; output: etag; update in place).
   - `ApiKey` (inputs: label, roles, expiry, rotation string; outputs: id,
     secret as secret output; rotation string change replaces, create before
     delete).
   Mints identity tokens with the Google auth library impersonated client;
   takes the server URL and discovery key from stack config / Secret Manager;
   depends on the application-server Cloud Run service; minimal dependencies
   because dynamic provider code is serialized into state. Stack state is
   encrypted with the stack's KMS key.
   A `@pulumi/command` wrapper around the structure CLI was considered as a
   cheaper first step and rejected in favour of the dynamic provider (no diffs,
   no secret outputs).
4. Bindings as code: `infra/infra/access.ts` maps staff emails to roles and
   declares one `AccessPolicy` per stack. `ApiKey` resources live beside the
   consuming service and replace the shared backend key in Secret Manager.

Rollout: ship sets/tables/endpoints -> deployer account + impersonation + root
principal config -> provider + policy resource -> replace the shared
`convex-backend-api-key` one service at a time, then delete it.

## Whitelist decision (user, 2026-10-01)

- The "credit deposits" idea is dropped entirely (Credit.Deposit entity,
  `credit_deposits` YAML, `NewDepositRequiredError`). It is replaced by a
  proper whitelist flow: a database table of allowed identifiers (by identifier
  id), managed through endpoints under the RBAC model above.
- Still open: table/entity name; behaviour for an email that is not
  whitelisted (generic success vs explicit error).

## OTP storage (agent proposal, discussed 2026-10-01, not yet accepted)

- Do not reuse `auth_challenges` (consumed-ids guard, written at verify). Give
  OTP its own table with a snowflake id, identifier_id, client_id, keyed
  code_hash = HMAC(secret, id || code), expire_time, attempts, used_time.
- Verify is one atomic UPDATE that increments attempts and sets used_time on
  match, bounded by attempt limit and expiry.
- The challenge returned to the client is server-HMAC-signed (reusing the SIWS
  signing helpers); the client does not sign anything, it returns the token plus
  the code. Purpose: bind the verify call to a specific challenge so a guessed
  snowflake id cannot be used to burn or brute-force someone else's challenge.
