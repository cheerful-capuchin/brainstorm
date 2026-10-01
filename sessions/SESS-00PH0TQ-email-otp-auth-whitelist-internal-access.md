---
create_time: 2026-10-01T10:56:23Z
summary: "Email+OTP sign-in: email as Identifier type; whitelist by identifier in DB with endpoints; shared API key rejected for admin; system actor gets principal; app server to issue API keys, Pulumi per-infra tokens wanted; OTP, email provider, org model open"
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
