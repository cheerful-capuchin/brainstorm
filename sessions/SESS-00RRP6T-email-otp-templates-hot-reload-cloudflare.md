---
create_time: 2026-10-28T15:16:42Z
title: "Email OTP sign-in: Cloudflare delivery, hot-reloaded email templates, Rust core split"
summary: "Email OTP: Cloudflare, Avro template bundle hot-reload, Rust core (otp, cloudflare build/parse), HKDF keys; PR review D15-D27: merged vendor/iam-core/messaging, retire older codes only, events in iam-core, Avro-compat schemas + binary invites.avro, ids-only send alerts, /auth/wallet routes, otp row retention via Cloud Scheduler, web template preview"
related_sessions:
  - SESS-00RP78Z
  - SESS-00PH0TQ
agents:
  - claude-code:e8341b6a-a51d-4255-9dde-1b4ad6c0b2fc
  - omp:01a18c59-6677-774a-ab13-bfa4c6c9d958
---

# SESS-00RRP6T: Email OTP sign-in: Cloudflare delivery, hot-reloaded email templates, Rust core split

Continues SESS-00RP78Z (invites + admission policy implemented, email left
out by D12) and SESS-00PH0TQ (OTP flow, challenge/proof naming, PoC).

## Starting point (user, 2026-10-28)

- Invites and the admission policy are implemented (SESS-00RP78Z D1-D26).
- Email delivery provider: **Cloudflare Email Service**. Decided earlier
  (SESS-00PH0TQ PoC); restated by the user today as settled.
- The 2026-10-01 proof of concept in `prototypes/otp-sign-in` was never
  committed and its source is gone. Only `out/` (rendered `otp.html`,
  `otp.txt`, `sent/*.json` request bodies) and `mnt/data/*.json` remain. The
  Claude transcript `f1139a2d-673b-413f-b738-c6fbde43c9a7.jsonl` is the only
  record of the code. To save tokens, the user asked to extract the important
  snippets once into a file and reference it from here:
  `brainstorm/sessions/assets/otp-sign-in-prototype-snippets.md`.
- Question brought today: how to store the OTP email templates. Requirements
  stated by the user:
  - hot-reloaded when the file in the bucket changes, "similar jazz" to the
    invite list;
  - not embedded in the code: a copy change must not need a recompile;
  - a recompile is acceptable only when a new variable is introduced;
  - can the Rust-core idea (SESS-00RP78Z D11) be kept, or must email be all
    TypeScript?

## Facts (2026-10-28, not decisions)

- The PoC email (from `out/`) uses these values: masked recipient
  (`f***@stxr.io`), the 6-digit code shown as `123 456`, expiry in minutes,
  request time in UTC, support address. The subject also carries the code
  (`271131 is your Structure sign-in code`). The sent body is
  `{from: {address, name}, to, subject, html, text}` with
  `from.address = no-reply@notifications.structure.fi`. The HTML is 8.3 KB,
  all styles inline except media queries, light/dark aware.
- SESS-00PH0TQ already records the user's acceptance (2026-10-01) of a plain
  HTML template with `{{placeholders}}` and a strict renderer; JSX/React Email
  and MJML were rejected for a single email.
- Invite hot-reload, as built: Rust `InviteCache` keyed by GCS `Generation`
  (`needs_refresh`, `apply` ignores older generations, keeps last good on
  error); TS `AdmissionService.refresh` does one metadata GET per admit and
  downloads only on change, alerts on failure, fails only when nothing was
  ever loaded. File lives in the config bucket under `admission/`, with an
  IAM condition on that prefix for the three editors (D19, D20) and a
  DATA_WRITE audit exclusion scoped to the prefix (D22). The CLI in
  `application-server/cli/` edits the file through pure Rust transforms.
- No template engine crate is vendored (vendor/ holds serde, serde_json,
  sha2, blake3, uuid, chrono, toml, ron, yaml-serde, bs58, ...). No `hmac`
  or `hkdf` crate is vendored either; `sha2` is.
- `application-server-core` is `cdylib + rlib`, wasm via wasm-bindgen
  0.2.121, consumed by structure-web api as
  `@structure/application-server-core`.
- PoC facts (from the snippets file; the plan, not the lost code): the PoC was
  TypeScript on Bun, not Rust. Code hash HMAC-SHA-256 over
  `${challengeId}\n${code}`; challenge blob `base64url(payload).base64url(HMAC)`
  with payload `{nonce, identifierId, issuedAt, expiresAt, version}`; TTL 10
  min, 5 attempts, single use, atomic claim with precondition
  `usedAt == null && attempts < MAX && expiresAt > now`; outcomes closed set
  `signed_in | invalid_code | expired | exhausted | already_used |
  malformed_challenge`. The user's note that the code used HKDF-derived keys
  could not be verified from the plan (source lost); treat the key scheme as
  open. Variables: `code`, `expires_minutes`, `destination`, `request_time`,
  `app_name`, `support_email`. Renderer strict both ways (placeholder without
  variable and variable without placeholder are errors), `{{{raw}}}`
  unsupported. Preview: Bun server re-reading the template per request.

## Email templates: agent proposal (2026-10-28, NOT accepted)

Answer to the user's three questions.

### Where the templates live and how they load

Copy the invite list mechanism one to one:
- One GCS object per email kind in the existing config bucket, under a new
  prefix, e.g. `email/otp-sign-in.json`. Same editor IAM condition (D20) and
  write-audit exclusion (D22), extended to the new prefix.
- The object is a JSON bundle written only by the CLI, never by hand
  (D17 rule): `{ kind, variables: {name: doc}, subject, html, text }`. The
  `variables` map is descriptive, copied from the core's table, so a Console
  reader sees what may be substituted. Humans edit three plain files
  (`subject.txt`, `body.html`, `body.txt`) in a directory; the CLI validates
  them through the core and uploads the bundle with `ifGenerationMatch`.
  Recommended: commit that directory in `application-server/templates/email/`
  next to `schemas/`, so copy changes are reviewed in PRs and the bucket is
  the runtime copy. Nothing is compiled in; a copy change is a CLI push.
- Runtime: Rust `TemplateCache` shaped like `InviteCache` (generation,
  `needs_refresh`, `apply` parses + validates, ignores older generations,
  keeps last good). TS `EmailTemplateService.refresh` runs before every send:
  one metadata GET, download on change, alert on failure, fail only when no
  template was ever loaded. Sends happen once per sign-in, so a GET per send
  is cheap. Call `refresh` once at startup so the first sign-in pays nothing.

### The contract: variables are a closed set in the core

- The core declares `EmailKind` (closed set, `OtpSignIn` today) and per kind
  its `Variable` closed set with Required | Optional (code is required in
  html and text; the rest optional). Display on every enum.
- `apply` refuses a bundle when: a placeholder names an unknown variable
  (this is exactly the "new variable, recompile" case, caught by the CLI
  before upload and by the server alert after), a required variable is
  missing from html or text, braces are unbalanced, or a size bound
  (64 KiB) is exceeded. Unused optional variables are allowed (relaxes the
  PoC's strict-both-ways rule, so copy can drop a value without a code
  change).
- Syntax stays plain `{{name}}`, no conditionals, loops or raw slots.
  `html` slots are HTML-escaped; `text` and `subject` are not; CR/LF are
  stripped from subject values. No template engine crate; nothing to vendor
  and the template cannot break the flow. If logic is ever needed, vendor
  `minijinja` (runs on wasm) rather than growing the own syntax.
- Templates are pre-parsed into segments at `apply`, so `render` is a join.

### Rust core vs TypeScript

The Rust-core idea holds; nothing in email forces TypeScript. Proposed split,
same as D11:
- Core (wasm + rlib): template bundle codec, validation, cache, `render(kind,
  vars) -> EmailMessage {subject, html, text}`; OTP logic as pure functions:
  code from host-supplied random bytes (rejection sampling), code hash,
  challenge sign/verify, the row claim as `claim(row, now, code) ->
  (row', Outcome)`, masked destination, outcome closed sets with Display.
  Needs `hmac` (and `hkdf` if kept) vendored; `sha2` already is.
- TS host: routes, Postgres `otp_challenges` row and the atomic UPDATE (the
  SQL stays TS, the precondition/effect comes from the core), GCS calls,
  `Mailer` port with the Cloudflare adapter (`send(EmailMessage) ->
  Result<Receipt, SendError>`, `SendError` closed set `network | rejected |
  rate_limited | invalid_message`), random bytes and time passed in.
  `from` address/name are app config rendered by Pulumi, not template data.
- CLI (`application-server/cli/`): `email validate`, `email push`, `email
  render --var k=v` and the PoC's browser preview as a subcommand over the
  same wasm, so the preview is byte-identical to what the server sends.
- The PoC being TS means the OTP logic is re-implemented in Rust; it is
  small (a few hundred lines).

### Considered and not recommended

- Template engine with logic in the bucket file: vendoring + ~300 KB wasm,
  and the editor could break the sign-in flow.
- Provider-hosted templates: ties the copy to Cloudflare, no local preview.
- Database table: same reasoning as D2 (no RBAC/endpoints yet).
- FUSE mount + file watch: rejected in SESS-00RP78Z already.

### Open for the user

- Prefix name (`email/` vs `templates/`), one object per kind (proposed yes).
- Commit the template sources in the application-server repo (proposed yes).
- Keep HKDF key derivation or a plain server secret per purpose.
- Where the OTP row lives (new `otp_challenges` table per SESS-00PH0TQ).
- Whether the invite check at email challenge time (D7) returns the explicit
  not-invited error (recorded as accepted in SESS-00RP78Z, applies here).

## D1-D4 (user decided 2026-10-28)

- D1: templates are stored as proposed above. Prefix in the config bucket is
  `assets/email/templates/` (object `assets/email/templates/otp-sign-in.json`).
  One object per email kind. Hot reload by generation check, template cache
  and validation in the Rust core, as in the proposal.
- D2: the template sources (subject, html, text per kind) are committed in
  git as well, in the `application-server` repo; the CLI pushes the bundle to
  the bucket. The bucket copy is the runtime copy, nothing is compiled in.
- D3: humans do not edit the HTML. Agents edit it; humans only want to see
  how the email looks. So the tooling is a CLI plus a simple visual preview
  (render with sample variables, open in a browser), no editing UI. The
  PoC's form-per-variable preview page is more than needed; a static render
  to a file plus `open` is enough.
- D4: the explicit not-invited error at email challenge time (SESS-00RP78Z
  D7) stands. No OTP is sent to an uninvited address.
- Open: key derivation. The user does not know what HKDF is; explained in
  the conversation, awaiting the choice (one existing challenge secret with
  HKDF-derived per-purpose keys, agent's recommendation, vs separate secrets).
  Fact: today the SIWS challenge is signed with one raw HMAC-SHA-256 secret
  (`signChallenge` in structure-web `auth-service.ts`), no derivation.

## D5: one secret, HKDF-derived keys (user decided 2026-10-28)

- Reuse the existing challenge secret (the one `signChallenge` uses for SIWS)
  as the single master secret. Derive two keys with HKDF-SHA-256 and distinct
  labels: one for signing the OTP challenge blob (label `otp-challenge`), one
  for hashing the code stored in the row (label `otp-code`). Exact label
  strings are the implementer's choice; they are part of the core and never
  change once a row exists.
- Rejected: a second secret in config (two secrets to rotate); one raw
  secret for both purposes (the PoC plan's approach; key reuse across
  purposes).
- Consequence: vendor `hkdf` and `hmac` (RustCrypto) into `vendor/`; derive
  inside the Rust core so the host passes only the master secret bytes.
- No open points remain in this session.

## Cloudflare logic in Rust, HTTP I/O injected from JS (user question 2026-10-29, agent answer, NOT accepted)

User asked whether the Cloudflare sending logic can live in Rust with only the
HTTP capability injected from JS, noting `application-server-core` is an
engine (`src/lib.rs`, `ApplicationServer` over `engine` + `ingress_egress`)
and asking whether a different approach fits.

Facts found:
- The core is already sans-IO; `admission` is a standalone wasm handle next
  to the engine, not a component. Same shape is available for email.
- `ipc/crates/http` (`stxr-http`) has `RequestOwned`/`ResponseOwned`
  (url, method, headers, body / status) with a `serde` feature. The TS
  `Http.Request`/`Http.Response` in `ipc/ts/net/src/http/http.ts` have the
  same fields and the same `Method` integer discriminants (OPTIONS 0 ...
  DELETE 6), so a request built in Rust can be performed by the existing TS
  `HttpClient` / `GcpClient.request`-style executor. `Headers` is a TS class,
  so a small bridge converts the generated plain shape.
- The engine route exists too: `ipc/crates/http-client::egress_consumer`
  defines `HttpClientRequest { request, correlation_id, timeout_ms }` and
  `HttpClientResponse { correlation_id, result }`; a component emits the
  request as egress and receives the response as ingress. But the wasm
  `drain_egress` is still `todo!`, and it needs correlation, async component
  state and ingress plumbing.
- The core has no async wasm (no wasm-bindgen-futures); the gcp TS adapter
  already uses the build-request / parse-response split
  (`Storage.buildGetObjectHttpRequest` + `parseGetObjectHttpResponse`).

Agent recommendation: build/parse pair in Rust, not the engine egress.
- Core exposes synchronous functions over `stxr-http` types:
  `build_send_request(config, message) -> RequestOwned` (URL, bearer header,
  JSON body `{from: {address, name}, to, subject, html, text}`) and
  `parse_send_response(ResponseOwned) -> Result<Receipt, SendError>`
  (`SendError` closed set: network | rejected | rate_limited |
  invalid_message, mapped from status + Cloudflare error body).
- Go one step further and make each OTP step a Rust driver so TS only
  executes effects: `OtpSignIn::start(email, now, random_bytes,
  master_secret, template) -> Started { row, send_request, challenge_blob,
  expires_at, masked_destination }`; host inserts the row, performs the
  request, calls `on_send_response`, deletes the row on send failure.
  `OtpSignIn::verify(blob, code, now, row) -> (row', Outcome)`; host runs the
  atomic UPDATE from `row'`. The TS host is a thin executor: Postgres, HTTP,
  GCS, secrets, routes, retries/timeouts.
- Engine egress route deferred until the application server really becomes
  an engine host (the Roc-platform vision in SESS-00RP78Z); one POST per
  sign-in does not justify correlation ids and ingress plumbing now.
- Cost: add `stxr-http` (serde feature) as a git dependency of the core;
  `bytes` 1.11.1 builds on wasm.

## D6: Cloudflare logic in Rust, option 1 (user decided 2026-10-29)

- Accepted "let's try option 1": the core builds the Cloudflare send request
  and parses the response over `stxr-http` `RequestOwned`/`ResponseOwned`;
  the TS host performs the HTTP call with its existing client. Each OTP step
  is a Rust driver (`start`, `on_send_response`, `verify`) returning the
  effects (row to insert or update, request to send) for the host to execute.
- The engine egress route (`http-client::egress_consumer`) is deferred, not
  rejected: revisit when the application server becomes an engine host.
- "Try" is the user's word: if the build/parse pair proves awkward in
  practice, the choice may be revisited.
- Affects: `application-server-core` (new `stxr-http` git dependency with
  the serde feature, email + otp modules, wasm handles), structure-web api
  (thin host: HTTP execution, Postgres, GCS, secrets, routes), the CLI.
- No open points remain in this session.

## Implementation plan notebook (2026-10-29)

`.dev-env/data/sessions/sess-00rrp6t/notebooks/01-email-otp-implementation-plan.md`,
with data files `otp-sign-in.bundle.json` and `templates/otp-sign-in/`
(subject, html, text rebuilt from the PoC's rendered output). Typechecks;
the mock run could not be saved because the app had not registered the
session yet.

Sources found while planning that outrank this record where they overlap:
- Knowledge base DEC-0D6TT (accepted 2026-10-28): the desktop app signs in
  with the emailed code inside the app; actions
  `authentication.email_challenge_create` / `email_challenge_verify`
  mirroring `POST /api/v0/auth/email/challenge` and
  `.../challenge:verify`; reasons `NOT_INVITED`, `INVALID_CODE`
  (`attempts_left`), `CHALLENGE_EXPIRED`, `CHALLENGE_EXHAUSTED`,
  `CHALLENGE_USED`, `MALFORMED_CHALLENGE`; demo and devnet wallets must be
  on the invite list; not-invited copy proposed to point at
  structure.fi/request-demo (item 7, proposed to the user, not accepted here).
- `email-otp-sign-in-ui-handoff.md` (workspace root, 2026-10-28): the
  contract the client is built against. Rules: 6 digits, spaces and dashes
  ignored, 10 min, 5 attempts, every verify spends one, single use, a new
  request retires older codes only once the new email was sent, trim +
  lowercase normalization, masked destination `c***@stxr.io`, new email =
  new user, no wallet linking. Check order on verify: authentic, used,
  exhausted, expired, code.

Corrections to SESS-00RP78Z as implemented: the invite schema is derived
from the Rust types (`apache-avro` derive), no committed `.avsc`; the
storage write audit exclusion is bucket wide, not prefix scoped;
`INVITE_LIST_PREFIX` lives in `infra/infra/services/application-server/invites.ts`.

Plan choices made by the agent (not user decisions): plain serde JSON for
the bundle (no Avro); `code` and `code_spaced` as two variables; HKDF info
strings `structure.otp.challenge.v1` / `structure.otp.code.v1`; invite
Avro schema v2 with the `email` symbol; `otp_challenges` table; dry-run
mailer for local runs; one code per identifier per 30 s; server refuses
to start without a bundle; Cloudflare `notifications.structure.fi` via
`cloudflare.EmailSendingSubdomain`, token via `pulumi config set --secret`.

Open points listed in the notebook: `CHALLENGE_USED` vs the existing
`CHALLENGE_ALREADY_USED`; not-invited copy (request-demo link); the rate
limit rule; refuse-to-start without a bundle; expiry in both payload and row.

## D7-D12: plan review in dev-env (user decided 2026-10-29)

Answers given as annotations on the plan notebook; applied to the notebook.

- D7: the template bundle is a **binary Avro object container file**
  (`assets/email/templates/otp-sign-in.avro`), not JSON. Reason (user):
  nobody needs to read it as text. Replaces the JSON bundle of D1; the
  schema is derived from the Rust record like the invite file.
- D8: code lifetime and attempt limit are **config file values**
  (`email.otp.code_ttl_sec`, `max_attempts`), not constants in code.
- D9: the Cloudflare target is a **config bag** in the Rust core
  (`CloudflareConfig { base_url, account_id, from_address, from_name }`),
  so a mock server can stand in by changing `base_url`. The TS mailer only
  adds the token and executes. The dry-run adapter is dropped for a mock
  Cloudflare server used locally and in tests.
- D10: rename the existing `CHALLENGE_ALREADY_USED` reason to
  `CHALLENGE_USED`, shared by the wallet and email flows (one producer in
  auth-service.ts, no client reads the old string).
- D11: the not-invited text keeps the landing page link
  https://structure.fi. Reason (user): request-demo may go away and leave
  a broken link. DEC-0D6TT item 7 is not taken.
- D12: rate limit accepted: one code per identifier per 30 s with
  `RetryInfo`, no per IP limit.
- Confirmed by the user, also applied: unused template variables allowed;
  `TemplateCache` built from the first bundle, no Option fields; the
  `otp_challenges` table goes through drizzle (schema.ts + generated
  migration); `email.templates` is a map keyed by email kind; the wire
  field is `client_id`, the service type `clientId`.
- Correction: startup without a bundle fails startup, the same as the
  invite list under `invite_only` (the earlier notebook text claimed the
  invite list failed only at admit time; wrong).
- Open: expiry in both the challenge payload and the row, or the row
  only. Agent recommends the row as the single source. Awaiting the user.

## D13 and review conventions (user decided 2026-10-29, second round)

- D13: the `otp_challenges` row is the single source of expiry and
  attempts. The signed challenge payload carries `{ v, id, identifier_id,
  client_id, issue_time }` only; `open_challenge` checks the signature,
  `claim` decides from the locked row.
- Conventions stated by the user while reviewing (apply to future plans
  and code):
  - Code snippets and code comments must not reference decision ids, plan
    parts or file paths; "this is rotting very quickly". Prose may.
  - The Cloudflare integration is "a durable thing that lasts and is well
    architected": a client module with one general `Config` (base URL,
    account id) and, per action, a request type plus build and parse
    functions. The email itself is a provider-neutral `EmailMessage` in an
    `email` module; the sender `Mailbox` is config (`email.sender`).
  - `Generation` is a GCS concept: `gcs::Generation` in the core, shared
    by the invite and template caches; the email module must not mention
    admission.
  - The table follows its neighbours: issue time from the snowflake id,
    `use_time = 0` for live rows (the `refresh_tokens` convention),
    `client_id` as `domain_id`.
- No open points remain in the plan.

## Independent review of the plan (2026-10-29)

The user asked for "the advisor" to review the plan; no such agent is
defined, so a fresh general-purpose reviewer read the plan against
DEC-0D6TT, the handoff, D1-D13, the Cloudflare facts and the real code.
Verdict: not ready; one blocker, fourteen should-fix items. All folded
into the notebook (section "Review findings applied"). Changes that are
not pure corrections, recorded here as agent proposals pending the user:

- Per identifier caps on codes next to the 30 s rule (D12): at most 5
  codes per rolling hour and 20 per rolling day, answered
  TOO_MANY_REQUESTS with RetryInfo. Reason: the attacker holds the
  challenge, so the 30 s rule alone allows 14,400 guesses a day and burns
  the Cloudflare monthly quota in a day. **Numbers to confirm.**
- The wallet producer of the renamed CHALLENGE_USED moves from
  INVALID_ARGUMENT to FAILED_PRECONDITION (the handoff's mapping).
- The not-invited description is worded per identifier type.
- Times cross the wasm boundary as milliseconds (i64), never nanoseconds
  (serde-wasm-bindgen refuses i64 above 2^53); the repository converts.
- The template bundle is written with a fixed Avro sync marker.
- No production invite edits with the v2-writing CLI before the v2
  capable image is live.
- The TypeScript sender is named CloudflareTransport (an authorised HTTP
  transport), not a port, because port signatures must stay free of HTTP
  types; the port-level abstraction is the core's EmailMessage.

## D14: per identifier code caps (user decided 2026-10-29)

- At most 5 codes per identifier in any rolling hour and 20 in any rolling
  day, next to the 30 s rule of D12; answered TOO_MANY_REQUESTS with
  RetryInfo. The user confirmed the reviewer's and agent's numbers ("these
  cap numbers are fine").
- The other review changes listed above stand as applied. No open points
  remain; the plan notebook is ready for implementation in its rollout
  order.

## PR review answers (user, 2026-10-30, annotations on notebook 02)

Implementation: nine PRs (vendor#3, iam-core#3, messaging#61, domain#22,
application-server#5, data-feed-definitions#38, structure-api#42,
structure-web#249, infra#96), review guide
`.dev-env/data/sessions/sess-00rrp6t/notebooks/02-email-otp-pr-review.md`.

- D15: vendor#3, iam-core#3 and messaging#61 approved. Signed (GPG, the
  user's key; main requires signatures) and merged with merge commits on
  2026-10-30. The workspace rule "do not sign commits" yields to the user's
  explicit request for these merges.
- D16: after a send, retire only the codes **older** than the one just sent
  (`id < kept id`), never a newer one. Affects the core's send effect and
  structure-web's repository.
- D17: the wallet flow answers `FAILED_PRECONDITION` for both
  `CHALLENGE_USED` and `CHALLENGE_EXPIRED`, like the email flow ("wallet can
  also be a failed precondition"). The review's recommendation of wallet
  wording separate from the email "code" wording stands unopposed.
- D18: events and subjects do not belong in domain; the "code emailed" event
  and its subject move to iam-core (OtpChallenge entity, one name
  `otp_challenges`). domain#22 drops them.
- D19: the verify request shape keeps the name `EmailChallengeVerifyRequest`.
- D20: the user sets the infra stack values (Cloudflare account, zone,
  tokens) himself.
- D21: infra-local gets a PR with the email config, the token env var and a
  reachable mock; merge it right away ("I don't really care about the infra
  local").
- D22: `otp_challenges` rows (they hold the plaintext address) get a
  retention policy: deleted a week after, by a Google Cloud Scheduler job.
- D23: replaces D3's "static render plus open": the template preview is a
  local web page where the user changes the variables and sees the rendered
  email ("I don't want to look at text").
- D24: replaces SESS-00RP78Z D17's acceptance rule and the JSON invite file.
  The server accepts an embedded writer schema when Avro's
  `SchemaCompatibility::can_read(writer, current types)` says so; one set of
  Rust types, no V1/V2 structs, no fingerprint allow-list. Applies to the
  invite file and the email template bundle. The invite file also becomes a
  binary Avro object container like the bundle. Reason (user): "I'm not
  going to read that file manually, I'll ask the agent to parse it", and the
  CLI already lists the entries. Object name `admission/invites.avro` (agent
  choice: old-image servers keep reading `admission/invites.json` during the
  rollout, so neither image refuses the other's file).
- D25: the `email.send.failed` alert carries ids, not Cloudflare's text:
  challenge id, identifier id, HTTP status, Cloudflare's numeric code.
  Cloudflare's free-form message is dropped. To reach a person, the
  `invites` CLI gets a lookup from an identifier id to the invite entry (only
  invited addresses ever get an email). Rejected: encrypting the address
  into the log; keeping the message with the recipient redacted.
- D26: the wallet HTTP routes move under the method:
  `/api/v0/auth/wallet/challenge` and `/api/v0/auth/wallet/challenge:verify`,
  next to `/api/v0/auth/email/...`. Every caller updated, old paths removed;
  no backwards compatibility (demo stage, user).
- D27: the production `EmailSendingSubdomain` is protected in Pulumi
  (`protect` on the production stage only).
