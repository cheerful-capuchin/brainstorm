---
create_time: 2026-10-27T16:49:35Z
title: "Email sign-in invite list: hot-reloaded file vs database"
summary: "Invite list implemented on per-repo branches (PRs open); file admission/invites.json with embedded Avro schema, invite_time RFC 3339 string (D26), v1 fingerprint 5f396d84bea86695"
related_sessions:
  - SESS-00RP78X
  - SESS-00PH0TQ
  - SESS-00PHDEJ
  - SESS-00PM9HX
agents:
  - claude-code:bbf40f1c-45a6-4d85-b9c8-52c5f62708f3
  - codex:01a17e43-bf8a-7402-a069-d1002b0c3ebe
  - claude-code:daddd497-2c2a-47f9-8905-e4e03bb50179
  - claude-code:2f3aa8fa-06b8-4ad1-b542-2aa3e166290d
---

# SESS-00RP78Z: Email sign-in invite list: hot-reloaded file vs database

## Coordination update from parallel Codex conversation (2026-10-27)

See SESS-00RP78X. After the same opening request, the user explicitly answered the removal-semantics question: **"Block new registrations only; existing users keep access."** This is a user decision, not an agent recommendation. Removal does not block existing-user sign-in/refresh or revoke sessions. Storage remains undecided. Codex owns SESS-00RP78X for its subsequent research; this note shares the answer across the parallel records.

Continues SESS-00PH0TQ (email OTP, whitelist as `allowed_identifiers` table),
SESS-00PHDEJ (invitations replace the whitelist, module contract) and
SESS-00PM9HX (invites CRUD as the first Rust-in-app-server service).

## Question brought by the user (2026-10-27)

Add email sign-in, allowed only for emails on an invite list. The list must be
dynamic: changing it must not require a redeployment.

The user wants to avoid the "complicated" route (invites table, CRUD endpoints,
permissions for who may edit) and proposes, by analogy with game asset
hot-reload: keep the invite list as a file in a bucket, maybe maintained by
Pulumi, and have the application server reload it whenever the file changes.

The `config.creditDeposits` check in `AuthService.verifyChallenge`
(`structure-web/packages/api/src/auth/auth-service.ts`) should go away; an
earlier agent proposed injecting an invite plugin/map and checking eligibility
through it.

Three questions:
1. Can the application server hot-reload the file without a restart?
2. Where to maintain the file: Pulumi, a small tool/MCP for the co-founders,
   or is that overkill and the database route is right after all?
3. How to restructure the auth service to honour invites?

## Facts found (2026-10-27, not decisions)

- Today the whitelist (`credit_deposits`) is part of the application-server
  YAML config. Infra renders the YAML into a GCS object
  (`config/application-server/application-server.config.yaml` in the config
  bucket) and mounts the bucket into Cloud Run as a GCS FUSE volume
  (`infra/infra/services/application-server/application-server.ts`). The
  revision annotation `app/config-hash` is the md5 of the config, so a
  whitelist edit forces a new revision today. The YAML lists wallet
  addresses only; the entries carry `deposit_time` and an optional label.
- The application server already has a GCS JSON API client
  (`gcp/ts/gcp/src/storage/mod.ts`: getObject returns `generation`,
  `metageneration`, `etag`, `updated`; downloadObject; no conditional
  `ifGenerationNotMatch` parameter yet).
- The app server has no periodic background loop pattern besides the pg
  client's retry loop; `Timer.IO` is available.
- `Identifier.Type` in iam-core still has only `SolanaPubkey`; no email kind.
- `Auth.NewDepositRequiredError` (domain) returns FailedPrecondition with
  reason `CreditRequired`.
- No invites/whitelist records exist in the knowledge base.
- Config bucket IAM: only service accounts have objectViewer; no human write
  grant is declared in infra.

## Decisions

- D1 (2026-10-28): closed sets keep their integer discriminants.
- D2 (2026-10-28): the invite list is a file in a GCS bucket "for now".
- D3 (2026-10-28): Pulumi manages the bucket; a CLI suite updates the file.
- D4 (2026-10-28, revised later the same day): the file contents are cached
  in the app server; refresh mechanism to confirm.
- D5 (2026-10-28): Apache Avro, JSON encoding, schema enforced.
- D6 (2026-10-28): the invite check applies to sign-in too, not only sign-up.
- D7 (2026-10-28): an uninvited identifier gets an explicit error whose
  description tells the person to request access at https://structure.fi.
- D8 (2026-10-28, corrected): the CLI suite lives in the `application-server`
  git repo (the one holding the Rust `application-server-core` wasm crate),
  not in structure-web `packages/misc`. Direction: move as much logic as
  possible into that Rust core; the TypeScript server calls into it.
- D9 (2026-10-28): cache refresh is a generation check on every admit
  (metadata GET, download on change, last-good kept, empty cache fails closed).
- D10 (2026-10-28): token refresh also checks the admission policy.
- D11 (2026-10-28): the Rust/TypeScript split proposed in "D8 corrected" is
  accepted: the Rust core owns the Avro schema, parsing and the admission
  logic; TypeScript bridges the wasm with generated types and keeps doing I/O
  through the existing TS platform abstractions (`Runtime.Trait` etc.) for
  this feature.
- D12 (2026-10-28): scope is invites only. No email sign-in in this work;
  the email identifier kind and OTP flow stay unresolved and go to another
  agent/discussion. Migration goal: move the wallet addresses from the infra
  `credit_deposits` YAML (application-server.ts:339) to the bucket file, and
  the app should behave the same.
Details in the sections below.

## Proposal on the table (agent, 2026-10-27, NOT accepted yet)

1. Hot reload: yes. Keep the invite list as its own GCS object, not inside the
   config YAML (the config md5 is the revision annotation, so an edit there
   redeploys). The app server loads it at startup through the existing
   `Storage` client, then re-checks `generation` with a metadata GET on a TTL
   and downloads only on change; atomic swap of the parsed map; keep the last
   good copy and `argus.alert` on fetch or parse failure; fail closed when
   nothing was ever loaded. Refresh on demand on the sign-up path (bounded by
   the TTL) rather than a background loop; a timer loop is the alternative.
   The FUSE mount was considered and not recommended (opaque cache, not
   testable locally).
2. Maintenance: Pulumi owns bucket, versioning, IAM and data-access audit
   logging; the object content is not Pulumi state. Humans write it through a
   small CLI (list/add/remove, validates, uploads with `ifGenerationMatch`),
   runnable from the Cloud Console as a fallback. MCP/chat wrapper only if
   co-founders ask for it. Database route rejected for now because the
   RBAC/endpoint plan (SESS-00PH0TQ/00PHDEJ) is not built and the final
   invitations shape (identifier -> org + role) is undecided.
3. Auth service: extract find-or-admit-and-create from `verifyChallenge` into
   one shared step used by SIWS verify and email OTP verify; replace
   `config.creditDeposits` with an `Invites` dependency (port with a named
   Admit/Deny decision, keyed by `IdentifierID` so wallets and emails share
   one list; the current wallet whitelist moves into the file). Check at email
   `createChallenge` too, before sending the OTP. Invite gates account
   creation only; existing users are not re-checked. Replace
   `NewDepositRequiredError` with an invite-required error and drop the
   Credit.Deposit entity.

## Open (user to decide)

- File vs database (and whether the file is a temporary adapter).
- Pulumi-rendered content vs direct writes with a CLI.
- On-demand TTL refresh vs background interval.
- YAML vs JSON for the file; whether wallet entries move into it.
- Invite checked at sign-up only, or on every sign-in.
- Explicit "not invited" error vs generic response at email challenge time.

## Direction raised by the user (2026-10-27, not yet confirmed)

The user recalled the sign-up policy idea from SESS-00PHDEJ (`SignUpPolicy.admit`
as a port with an open default, invitations as the adapter) and leans towards
the auth service operating on policies instead of looking up keys in a map.

Agent proposal in response (not accepted): `Auth.SignUpPolicy` as a closed-set
value in the auth domain, variants Open | Closed | InviteOnly { invites },
following the `StartPolicy`/`Identifier.Type` closed-set pattern. One pure
decision function returns Admission = Admitted | Denied { reason }; Admitted
is the place that later carries bindings (org + role) when invitations become
a real module. `InviteList.Data` is the only adapter that knows about the
file, the generation check and the TTL; it has a Static source variant for
tests. The auth service dependency becomes `signUpPolicy: SignUpPolicy.T`,
chosen by the composition root from a `sign_up` config section that is itself
a closed set. Both challenge issuance (email, before sending the OTP) and
account creation call the same `admit`.

## Policy as data vs as interface (user question 2026-10-27, agent revised answer, not accepted)

User asked whether the policy should be a closed-set value or an interface
with an `admit`/`verify` function that encapsulates its own data. Agent now
recommends the interface (port) shape, precedent `KV.Trait` +
`InMemoryKV.make` in `structure-web/packages/api/src/kv`: the auth domain
defines `SignUpPolicy.Trait { admit(identifier, now) -> Admission }` and the
closed sets are the *verdict* (Admitted | Denied { reason }) and the config
value that selects the adapter; adapters are OpenSignUp, ClosedSignUp,
InviteOnlySignUp(InviteList.Data). Reason: with a data union the auth domain
would reference the invites adapter type (dependency pointing outward); with
the port the invitations module implements the trait and can be deleted
without touching the domain. Fakes implement the trait in memory, as
`dev-docs/architecture/port-conventions.md` describes.

## Context argument and InviteList shape (user question 2026-10-27, agent answer, not accepted)

User asked whether the trait should take a context carrying time (Rust habit:
`fn admit<C: HasTime>(ctx: C, …)`) and what `InviteList.Data` holds and how it
updates. Agent: yes, as a structural slice `HasTime = Pick<Context, "tp">`
(core `Context` already has `tp`, `traceID`, `logger`), first argument of
`admit(ctx, identifier)`; no TS generics. Time flows from the caller into the
adapter's TTL check, so the adapter has no hidden clock (unlike `InMemoryKV`
which takes `tp` at make time). InviteList.Data = { source: Gcs | Static
(closed set), refreshInterval, idClient, state: Mutable<{ snapshot
{generation, loadTime, entries by IdentifierID}, lastCheckTime, inflight }> }.
Functions load (startup, fails process), lookup, refreshIfStale (TTL,
single-flight, metadata GET compares generation, download pinned to that
generation, atomic snapshot swap, on error alert + keep last good + stamp
lastCheckTime), parse (zod YAML, email normalization, IdentifierID via id
wasm, duplicate rejection). Argus event per swap with generation and count.

## Closed-set values print as numbers (user pain point 2026-10-27, agent answer, not accepted)

User dislikes that integer-discriminant closed sets have no Display: once a
value reaches the console it is a number literal. Asked whether Effect solves
it. Agent: `ErrorFamily.define` (ts-core `error.ts`) already attaches
toString/toJSON/NodeInspectSymbol/toPrimitive, so error objects display fine;
the gap is bare primitive closed-set values (`Identifier.Type`,
`KV.Operation`), which no sink can render. Options: (a) string literal
discriminants in memory, integers only in boundary codecs (wire, DB, id hash),
recommended; (b) frozen variant singletons carrying inspect/toString, by
reference equality; (c) fixing sinks, impossible for primitives. Effect is
reliable for errors because `Data.TaggedError`/`Schema.TaggedError` are
Inspectable class instances with string `_tag`; it does nothing for numeric
literals; adopting Effect in the app server for this rejected by the agent as
the wrong trade. If accepted, `DenialReason` and `Admission.kind` are strings.

## D1: keep numeric literals for closed sets (user decided 2026-10-28)

The user chose to keep integer discriminants for closed sets after the
display discussion above. String-literal discriminants in memory (agent's
recommendation) are rejected; variant singletons were not chosen either. No
further reason was given.

Consequences for this work:
- `DenialReason`, `Admission.kind`, `InviteList.SourceKind` and any new
  closed set follow the existing `Identifier.Type` pattern: integer values,
  `EnumVariantCount`, display table with a count assertion, `_display`
  function, zod literal union.
- Error display stays hand-written inside `ErrorFamily` variant display
  functions, calling the set's `_display` helper, as `KVError` does.
- Affects: structure-web `packages/api` (auth, invites), domain `auth.ts`,
  iam-core identifier types. Does not change dev-docs standards.

## D2-D6 (user decided 2026-10-28)

- D2 File in a bucket "for now": the database route (SESS-00PH0TQ
  `allowed_identifiers`, SESS-00PM9HX invites CRUD) is not pursued now. The
  file is understood as a temporary adapter behind the sign-in policy port.
- D3 Pulumi manages the bucket (and its IAM, versioning, audit). The file
  content is not Pulumi state; a CLI suite updates it. Location of the CLI not
  decided.
- D4 Fetch on every attempt, no TTL, no snapshot cache: the user expects a
  bucket download to be quick. Consequence (agent, to confirm): no
  `InviteList` state, no last-good fallback; a fetch or parse failure is an
  internal error on the auth path (fail closed) plus an argus alert.
- D5 Schema enforced, text based. User suggested Apache Avro and asked
  whether a text format with an enforced schema exists. Agent recommended
  Avro JSON encoding with a flat record and no unions (avsc 5.7.9 already in
  app-db, schemas as TS in `packages/app-db/src/avro`), alternative proto3
  JSON via @bufbuild/protobuf 2.11 with the schema in msg-schemas for Rust
  reuse. Format not chosen yet.
- D6 The check runs on sign-in as well as sign-up. Consequence: removing an
  entry locks the user out at the next sign-in; the port is a sign-in policy
  (name `SignInPolicy`, not `SignUpPolicy`). Open: whether token refresh also
  runs the check, otherwise a removed user keeps access until the refresh
  token expires.

## Still open

- File format (D5): Avro JSON vs proto3 JSON.
- Response to an email challenge request for an uninvited address: explicit
  "not invited" error (agent recommends; list is closed and small) vs generic
  "code sent" response that hides membership. User asked what this means;
  explained 2026-10-28, not yet answered.
- Whether refresh-token exchange also consults the policy.
- Where the CLI suite lives.

## D4 revised, D5, D7, D8 (user decided 2026-10-28, second round)

- D4 revised: "we can cache the contents of the file". Supersedes the
  no-cache choice earlier the same day. Agent proposal for the refresh (not
  confirmed): on every admit, one metadata GET compares the object
  generation with the cached one and downloads only on change; last-good copy
  kept; fetch failure alerts and uses the cached copy; no copy at all fails
  closed.
- D5: Apache Avro is fine. Agent's shape: JSON encoding, flat record, all
  fields required, no unions; one `.avsc` shared by the CLI and the server;
  `avsc` 5.7.9 already in app-db.
- D7: explicit error for an uninvited identifier, with a description telling
  the person to request access at https://structure.fi. Replaces the
  generic-response option. Applies at email challenge request too (no OTP
  sent).
- D8: the CLI suite lives in `structure-web/packages/misc`. The user wants
  more core logic to move there over time and asked what could. Agent's
  candidates listed in the conversation (app-db scripts, migrations runner,
  config render + validate, avro schema registry check, workflow fail loop
  from SESS-00RJW6T, user archive, later API keys). Note: misc today holds
  unrelated prototypes (ai chat UI, phantom wallet page, python ticket
  scripts).

## Policies (user question 2026-10-28, agent answer, not accepted)

User asked whether there are separate sign-in, sign-up and refresh policies.
Agent: one port, `AdmissionPolicy.admit(ctx, identifier) -> Admission`,
asked from three call sites: sign-up (new user, the trusted identifier),
sign-in (existing user, the trusted identifier), refresh (existing user: load
the user's identifiers, admitted if any one is admitted). Name chosen to
avoid `AccessPolicy`, already used for the Pulumi IAM resource in
SESS-00PH0TQ. Refresh checking is the agent's recommendation; the user's
question implies it but it is not recorded as decided.

## D8 corrected and the Rust-core direction (user 2026-10-28)

The agent misread "misc in the application-server repo" as structure-web's
`packages/misc`. The user meant the `application-server` repository
(stxr-prop/application-server), which holds `crates/application-server-core`,
a sans-IO Rust core compiled to wasm and consumed by structure-web's api as
`@structure/application-server-core`. The user intends to move more and more
logic there so the TypeScript part calls into Rust, and wants as much of this
feature as possible in Rust.

Agent proposal for the split (ACCEPTED as D11, 2026-10-28):
- Rust core (pure, sans-IO, shared by server and CLI): invite file schema and
  codec (Avro JSON), validation (email normalization, duplicates), identifier
  id computation (iam-core rust + domain `id` crate already exist),
  `AdmissionPolicy` closed set and `admit` decision with Display on every
  enum, the cache state (`generation` + list, `needs_refresh`, `apply`), the
  not-invited error text, and the CLI's list/add/remove edits as pure
  transforms returning new bytes.
- TypeScript host: GCS metadata/download/upload calls (egress), Postgres,
  OTP email, HTTP routes, JWT; `AuthService` calls the wasm for the decision.
- CLI: a host in the application-server repo. Recommended as a TypeScript
  (Bun) host over the same wasm plus `@structure/gcp` Storage with ADC, so
  server and CLI run byte-identical logic; a native Rust binary over the
  `rlib` is the alternative (Rust GCS adapters exist in databento-mkt-data,
  backtest-tools and structure-client-core).
- Fact: no `apache-avro` crate is vendored in the Rust workspace yet; Avro in
  Rust means adding it to the vendor repo. avsc exists only on the TS side.

## D9-D11 and the platform vision (user 2026-10-28)

- D9 Generation check chosen over a TTL.
- D10 Token refresh runs `admit` against the user's identifiers, so removing
  an invite ends access at the next refresh, not at refresh-token expiry.
- D11 The split in "D8 corrected" is accepted. Rust `application-server-core`
  holds the Avro schema, parsing and all invite/admission logic; some
  generated types bridge the wasm to TypeScript; the TypeScript server keeps
  its current platform abstractions for I/O. The user wants to focus on
  getting invites done, not on the platform migration.

Global vision stated by the user (direction, explicitly NOT to execute now):
model the application server like the Roc language's platform concept
(https://roc-lang.org/): a platform written in an imperative low-level
language hosts domain code written in the high-level language. Here: the
Rust core already holds some business logic; much business logic is still in
TypeScript; the infrastructure layer (HTTP, database, ...) could also move to
Rust, with calls through the TS `Runtime.Trait`-style abstraction going to
that Rust layer. Seen as the path to migrate the TypeScript application
server to full Rust. Relates to SESS-00PM9HX (Rust services inside the TS
application server).

## D12: invites only, no email (user decided 2026-10-28)

- Email sign-in is out of scope for this work. The user leaves it
  unresolved, for another agent. Items that stay open with it: `Identifier.Type`
  email kind, OTP challenge flow, email provider, the explicit not-invited
  error at email challenge time (D7 still applies to the wallet verify path).
- Concrete goal: move the 29 wallet addresses listed under `credit_deposits`
  in `infra/infra/services/application-server/application-server.ts` (and the
  local list in structure-web `packages/api/mnt/config/application-server.config.yaml`)
  into the bucket file, delete `credit_deposits` from the config schema, and
  keep the app behaving the same for those users.
- Facts for the migration (2026-10-28): every infra entry has a non-nil
  `deposit_time`, so `Credit.isActivated` is true for all 29 and the invite
  file needs no "activated" flag; `label` exists on two entries; readers of
  the old config are rt-config.ts (schema + mapping), run.ts
  (`makeAuthRequirements`), auth-service.ts (`Config.creditDeposits`, the
  check at line 252) and the domain `Credit` entity.
- Behaviour difference the user accepted implicitly via D6/D10 (flag for the
  plan): the old check ran only when no user existed; the new one also runs
  at sign-in and refresh. With the file seeded from the full list, nobody
  currently able to sign in is affected.

## Implementation plan (2026-10-28)

The plan is a dev-env notebook in session sess-00rp78z:
`.dev-env/data/sessions/sess-00rp78z/notebooks/01-invite-list-implementation-plan.md`.
Six parts: Rust core, CLI (Bun, application-server repo), gcp Storage
(`generation` on download, `ifGenerationMatch` on upload), domain
(`NOT_INVITED` replaces `CREDIT_REQUIRED`, Credit entity deleted), api
(`AdmissionService`, admit in verifyChallenge before the user lookup and in
refreshToken inside the tx before `rollRefreshToken`), infra (versioned
admission bucket, `credit_deposits` removed). Facts found while planning:
the infra list has 29 entries / 28 addresses (`7kJEE9…Pbie` twice); an
admit after the refresh roll would cause false `replay_attack` alerts.

## D13-D16 (user decided 2026-10-28, answers to the plan's open points)

- D13: in the invite file the identifier type is the Avro enum string symbol
  (`solana_pubkey`), since Rust parses it; inside the code the closed set
  stays numeric (`IdentifierType::SolanaPubkey = 1`). Consistent with D1.
- D14: the Rust core validates the file with the `apache-avro` crate at
  runtime: `serde_json::Value` -> `apache_avro::types::Value::try_from` ->
  `resolve(&schema)` against the committed `.avsc`. The user pointed out that
  no Rust struct per Avro record is needed. Replaces the agent's proposal
  (serde mirror structs + dev-only schema equality test), which assumed
  apache-avro cannot read JSON; that assumption was wrong. Agent fact
  (apache-avro 0.22.0 source, `resolve_record`): fields absent from the
  schema are ignored silently, so a typo'd field name passes resolve; an
  extra key check is needed if unknown fields must be rejected.
- D15: vendor `bs58` into `vendor/` for the canonical base58 check.
- D16: local development (structure-web `mnt/config`, infra-local) uses the
  `open` admission policy. The user frames it as a capability chosen by
  config (`admission.policy`).

Still open:
- Storage write audit (open point 3). User asked whether write audit logs
  can be enabled for one bucket only. Agent answer: GCP data access audit
  config is per service (storage.googleapis.com) per project, not per bucket;
  the same effect comes from DATA_WRITE for storage plus an exclusion on the
  `_Default` sink (already owned in `infra/infra/logging.ts`) dropping storage
  data access entries for every other bucket. Not yet confirmed.
- Who gets objectUser on the admission bucket.
- Pre-production check (open point 6, re-explained): query production for
  users whose identifiers are all missing from the seed; they would be locked
  out by D6/D10. Who runs it and what to do with hits is not decided.

## D17: the invite file embeds its schema (user decided 2026-10-28)

The user found the bare data file unclear ("it's unclear what's going on in
the file") and asked to embed or reference the schema. Agent proposal,
accepted by the user ("yeah"):
- File = JSON object `{ "avro.schema": <full schema with doc on the record
  and every field>, "data": <InviteList in Avro JSON encoding> }`, mirroring
  the `avro.schema` header key of Avro object container files.
- The embedded schema is descriptive, not authoritative. The core accepts a
  file only when the embedded schema's CRC-64-AVRO (Rabin) fingerprint of
  its Parsing Canonical Form matches a version the core knows (v1 today,
  `schemas/invite_list.v1.avsc`), then resolves `data` against its own copy.
- Schema evolution: keep old versions as known writer schemas and resolve
  into the new one; `SchemaCompatibility::can_read` tested. No version field.
- The CLI/encoder always writes the core's committed `.avsc` text verbatim;
  nobody edits the embedded schema by hand.
- Rejected (agent, not discussed further): reference only (name +
  fingerprint) because a Console reader still cannot see field meanings;
  schema in GCS object metadata because a downloaded copy loses it.
- Fact (apache-avro 0.22.0 `pcf_map`): the canonical form strips `doc`,
  `default`, `aliases` and `logicalType`, so those changes keep the
  fingerprint.
Affects: application-server-core admission module, CLI, notebook Part 1.

## D18-D21 (user decided 2026-10-28, review of the plan notebook)

- D18: no `None` variant in `DenialReason` ("a relic of typescript"); the
  Rust invite cache holds a plain `Vec<IdentifierId>`, not a HashSet.
- D19: the invite file goes in the existing config bucket (`configBucket`,
  infra `buckets.ts`), not a new bucket; the user saw no reason for a new
  one. Agent plan: object `admission/invites.json`; config bucket gets
  versioning + lifecycle (keep 50 noncurrent versions, bucket wide);
  backendAccount already has objectViewer. The app config points at the
  object with the existing `BlobObjectRef` (`@structure/domain/blob-storage.ts`,
  as `market_info_catalog` does), user's suggestion. Replaces the agent's
  dedicated admission bucket proposal.
- D20: editors of the list are cheerful-capuchin, grumpy-gorilla and
  babies-with-aids. Agent plan: `roles/storage.objectUser` on the config
  bucket with an IAM condition on the `admission/` prefix (first IAM
  condition in infra).
- D21: the CLI lives in `application-server/cli/`.

User question answered (no decision): the wasm `Admission.admit` is
synchronous; `AdmissionService.admit` is async only because `refresh` does
GCS I/O. Notebook snippet rewritten to show it.

Still open: write audit (DATA_WRITE + `_Default` exclusion now scoped to
config bucket + `admission/` prefix); the pre-production lockout query.

## D22-D23 (user decided 2026-10-28)

- D22: storage write audit accepted: `DATA_WRITE` IAMAuditConfig for
  storage.googleapis.com plus a `_Default` sink exclusion keeping only
  config bucket `admission/` entries. User asked to define it in
  `infra/infra/audit.ts` and import the rule (or part of it) into
  `infra/infra/logging.ts`. Agent plan: `audit.ts` exports
  `storageDataAccessExclusion`; `bucketName`/`bucketLocation` move from
  `buckets.ts` to a resource-free module with `configBucketName()` and
  `INVITE_LIST_PREFIX` so audit.ts does not import buckets.ts (which creates
  resources on load; pulumi.config.ts loads audit -> logging -> buckets).
- D23: no pre-production lockout check. Reason (user): there is no real
  production yet, all users are demo users, so losing access changes nothing.
  Replaces the open point about the step 7 query.

No open points remain in the plan.

## D24-D25 and the apache-avro wasm spike (2026-10-28)

- D24 (user): the dev stack is not in use. Plan verification moved to a
  local API run with `invite_only` against a test object
  (`admission/invites.test.json` in the local config's bucket
  `impartial-fish-94`), then production smoke checks after deploy. No dev
  infra steps.
- D25 (user left it to the agent, "whatever is the best one"): integer
  codes cross the wasm boundary as `u8` fields cast from `#[repr(u8)]`
  enums, with `#[tsify(type = "0 | 1")]` overrides; no `serde_repr`; a bun
  test pins the values against the TS display tables.

Spike results (user asked to test apache-avro on wasm; scratch crate inside
the workspace so `.cargo/config.toml` vendor patches applied; deleted after):
- apache-avro =0.22.0 builds for wasm32-unknown-unknown with
  wasm-bindgen =0.2.121 and runs under bun (wasm-pack --target web).
- BLOCKER FOUND, with fix: apache-avro 0.22.0 needs serde_json >= 1.0.150;
  vendored serde_json is 1.0.149, so the build gets two serde_json crates
  (vendor path + crates.io 1.0.154) and fails with E0308/E0277 at
  `Schema::parse(&Value)` / `Value::try_from(serde_json::Value)`. Fix: bump
  `vendor/serde_json` to the newest 1.0.x first (plan rollout step 0, with
  the bs58 vendoring). With one serde_json it builds.
- Behaviour confirmed on the real 28 addresses: decode ok; doc edit keeps
  fingerprint 808a07ee094b68c7 (v1 schema as in the notebook); adding a
  symbol gives 3f9137e0dcc7a42c and is refused; stray key `lable` is
  ACCEPTED by resolve (reject_unknown_keys required); missing field,
  unknown symbol ("Enum default ... not among allowed symbols", misleading
  wording), wrong type, missing avro.schema are refused; empty list ok.
- Rust Rabin fingerprint equals app-db TS `Crc64Avro.fingerprintBytes`
  over the same canonical form.
- Size (opt-level z + LTO): 68.6 KB without apache-avro vs 374.2 KB with
  (+306 KB raw, +114 KB gzip); core is 1.4 MB today.
- Transitive deps on wasm include quad-rand and the vendored uuid 1.28.0.

The plan notebook is updated (Part 1 spike table, rollout steps 0-8). No
open points remain.

## D26: invite_time is an ISO string in the file (user decided 2026-10-28)

The user asked for `invite_time` as an ISO string date instead of epoch
milliseconds, after the first implementation. Replaces the
`long`/`timestamp-millis` field of D17's v1 schema.

- Schema: `invite_time` is `"type": "string"` with a doc naming the form
  (RFC 3339 UTC with milliseconds). Avro has no logical type for a string
  timestamp, so the core checks the value (utils `time::iso`).
- Reading: any RFC 3339 timestamp, `Z` or an offset, is read as the same
  instant; precision finer than a millisecond is refused.
- Writing: always UTC, three fraction digits, `Z` (`Date.toISOString` form).
- Code and the wasm boundary keep milliseconds since the epoch (D1/D13
  pattern: the string exists only in the file).
- v1 was edited in place instead of adding v2, since no file had been
  written to GCS yet; the v1 fingerprint is now 5f396d84bea86695 (was
  808a07ee094b68c7).
- Affects: application-server `schemas/invite_list.v1.avsc`,
  `src/admission/invite_time.rs`, codec, tests; the seed in dev-env
  sess-00rp78z was regenerated.
