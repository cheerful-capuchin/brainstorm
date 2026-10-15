---
create_time: 2026-10-19T10:07:52Z
title: "Knowing our code is broken during the beta: 4xx signals and client error reporting"
summary: "Open discussion, no decisions. Split from SESS-00R0BCD Q1: if 4xx stop paging (every NOT_FOUND/INVALID_ARGUMENT/FAILED_PRECONDITION is an ALERT today), how do we learn our code is broken during the beta? Server: classify 4xx (contract violation vs domain answer), NOTICE events + log-based metrics. Client app reports nothing (no version, trace id, error id). Proposal A-D and open questions Q1-Q8 for the next discussion."
related_sessions:
  - SESS-00R0BCD
  - SESS-00QKS30
  - SESS-00QKRBE
agents:
  - claude-code:4d6a7ca5-dd04-4c68-820c-98dfd392011a
---

# SESS-00R0CQR: Knowing our code is broken during the beta: 4xx signals and client error reporting

Split from SESS-00R0BCD (application-server weekend alerts), question 1.
That session holds the incident evidence; this one is only about the
approach. Decisions already made there that bound this one:
- SESS-00R0BCD D1: one ALERT per server failure that carries the cause
  (service, method, cause, stack) instead of a context-free ALERT plus a
  separate ERROR line.
- SESS-00R0BCD P1 (proposed, the trigger for this session): take the 4xx
  codes off the alert list.

## The user's question (2026-10-19)

"How would we know that there is an issue with our code for the beta? Do
we add alerts on the client?" The user does not want to be paged for 404s
(SESS-00R0BCD), but removing 4xx alerts removes the only signal that our
own client or server is misbehaving. The beta has external users on the
stxr-client-app. The user wants a separate discussion about approaches.

## Current state (verified 2026-10-19, structure-web d77e45b4e = main)

### Server: what pages today

- `packages/api/src/lib/api.ts`:
  - `ERROR_CODE_TO_REPORT` (~line 194): Timeout, Internal, Unknown,
    PermissionDenied, and under `/* For the release period only */`
    InvalidArgument, FailedPrecondition, NotFound.
  - `jsonHandler` (~207-252): an ApiError whose code is on the list ->
    `publishHandlerAlert`; any non-ApiError result or thrown error ->
    `publishHandlerAlert` + `NewInternalError(traceID)`.
  - `publishHandlerAlert` (~176): always `argus.alert(
    "<callSite>.response_error", {path, method, handler_name, error,
    stack}, {tags: ["application_error"]})`. Severity is always ALERT;
    there is no code -> severity mapping.
- `packages/api/src/execute/consume-failure.ts`: the execute endpoint
  (`POST /api/v0/execute`, one RPC-style route for many services) has
  three failure stages:
  - `rejected` -> `ApiError(InvalidArgument, "Invalid request")` (request
    did not decode / match a known service+method),
  - `adapter` -> InvalidArgument with a BadRequest field violation (wire
    -> domain conversion failed),
  - `handler` -> the handler's ApiError as is, otherwise
    `argus.error("consume_failure.to_api_error.internal", {service,
    method, cause: message})` + `NewInternalError()`.
  So for execute the server already knows when a request broke the API
  contract (`rejected`/`adapter`) versus a domain refusal from a handler.
  JSON REST routes validate in their handlers; whether they distinguish
  "malformed" from "domain refusal" was not checked.
- Pipeline: argus -> AlertSink (`packages/api/src/run.ts` ~1116, minSeverity
  ERROR, 1 s batches, 256 buffer) -> `AlertsFeedMessage` on Topic.Feeds ->
  Pub/Sub sub `notify-gw-alerts-feed-sub` (infra `infra/event-bus.ts`) ->
  notify-gw (stxr-prop/monitoring) -> Discord. ERROR entries reach Discord
  too. AlertSink tags ALERT as `critical` (`packages/alerts/src/alert-sink.ts`
  SeverityCategoryTable). No rate limit per event in this path.
- Rust services use a different path: log-based Cloud Monitoring policies
  per program event (SESS-00QKS30 D4/D7), JSON log lines with
  `jsonPayload.event`. The application-server still logs text lines
  (`[ALERT] event key=value;...;trace_id=..`), one Cloud Logging entry per
  stack line. Log-based metrics on the app-server need either JSON lines or
  regex extraction on `textPayload`.
- Trace id = per-request lowercase ULID (`routes.ts` ~76); an INTERNAL
  error's `error_id` is the trace id. Internal routes adopt the caller's
  `x-trace-id` after auth (`CallerTraceID`, `api.ts` ~499).

### Weekend numbers (2026-10-16..19, from SESS-00R0BCD)

677 ALERT lines: 193 pool_pressure, ~74 INTERNAL, 16 auth
(`auth_service.verify_challenge_*_signature.signature_mismatch`,
`auth_service.refresh_token.replay_attack`), ~394 4xx:
deleteStrategy FAILED_PRECONDITION ("has backtests"), execute
INVALID_ARGUMENT (22 in one hour on 10-18), NOT_FOUND on getStrategy /
getTradingAccount / getRevision, getChallenge/verifyChallenge
INVALID_ARGUMENT. Nobody checked which of the INVALID_ARGUMENT were
contract violations (`rejected`/`adapter`) versus value checks; worth
doing before deciding (query: `resource.labels.service_name=
"application-server" AND textPayload:"json_handler.response_error" AND
textPayload:"INVALID_ARGUMENT"`, then look at the error details).

### Client app (stxr-client-app, read 2026-10-19)

A VS Code based desktop app; API calls run in Node (electron main / node
layers). Findings:
- No telemetry or error reporting to our backend. No Sentry/PostHog/OTLP;
  `@structure/telemetry` unused in `src`; `product.json` has no telemetry
  keys. Errors are logged locally only (e.g.
  `src/vs/platform/stxrPortfolio/electron-main/stxrPortfolioMainService.ts:374`).
- `src/vs/platform/stxrApiClient/common/stxrApiError.ts:13-23`
  (`stxrApiErrorMessage`) turns an ApiError into a string (message + field
  violations, or `HTTP <status> <statusText>`); the code and the ErrorInfo
  metadata, including `error_id`, are dropped. Users cannot quote an error
  id.
- No version, client-name or trace headers. Only `Authorization`
  (`src/vs/platform/stxrAuth/electron-main/stxrAuthenticatedApi.ts:24-28`).
  `stxrApiFetch` (`src/vs/platform/stxrAuth/node/stxrApiFetch.ts:16-36`)
  adds a 15 s timeout and an 8-in-flight limit. User-Agent is Node's
  default `node`. Server logs cannot be tied to a client build or a user
  action.
- Failures hidden from the user: the deployment editor drops failed
  account lookups through `Promise.allSettled`
  (`src/vs/workbench/contrib/stxrDeployment/browser/stxrDeploymentEditor.tsx:1578-1579`).
- No HTTP retry helper. HTTP only; the client app does not use the
  realtime-gateway or structure-sdk.
- Per-id fan-out: `getAccounts(ids)` sends one `GET /trading-accounts/{id}`
  per id in parallel (`src/vs/platform/stxrDeployment/node/stxrDeploymentControlAdapter.ts:119-129`),
  called from `resolveDeployment` (`stxrDeploymentService.ts:899`) for
  getDeployment, getSnapshot, performance reads, acquireLiveValuation and
  lifecycle actions. On 2026-10-18 09:02-09:27 UTC each of ~50 trading
  accounts was fetched 54 times by a `node` client (likely this path, not
  proven).
- `resolveStrategy` has no negative cache; `refreshStrategy` stops on 404
  (`src/vs/platform/stxrStrategy/electron-main/stxrStrategyMainService.ts`).
- Pollers: deployment data 2 s, portfolio 2 s while transitioning / 30 s
  retry, strategies 5 s / 30 s staleness, logs 2 s.

## Framing proposed to the user (not decided)

A 4xx is one of two signals:
- **Contract violation: our code is wrong.** The request does not match the
  API contract (execute `rejected`/`adapter` stage, malformed JSON body,
  unknown field), or the client cannot decode a 2xx response. With our own
  client as the main caller, each of these is a bug in the client or a
  client/server version skew.
- **Domain answer: the user's data.** NOT_FOUND, FAILED_PRECONDITION,
  value-level INVALID_ARGUMENT ("strategy has backtests", unknown id). One
  is normal; a sudden rate change after a release can still mean a bug
  (e.g. the client sending stale ids).

## Proposals (not decided)

- A. Server, every 4xx as one NOTICE event (not ALERT) carrying handler or
  service+method, code, ErrorInfo reason, principal, client version (once
  sent). Needs a stable event name per class, e.g.
  `api.request.contract_violation` and `api.request.refused`.
- B. Server, alerting on aggregates, not events: log-based metric by
  (route, code, reason); alert immediately on contract violations (rate
  limited, e.g. once per route per hour); alert on rate jumps of domain
  refusals (per route, compared with the previous day or a fixed
  threshold); daily Discord digest of 4xx counts by route and reason.
  Open: Cloud Monitoring log-based metrics + policies (the infra pattern
  from SESS-00QKS30) versus counting in notify-gw (SESS-00QKRBE P8 rules).
- C. Client, make server logs attributable: `x-client-version` (build +
  commit) on every request; an `x-trace-id` per user action (one id for
  all requests that action causes, so a server log line maps to "user
  opened deployment X"); keep the code and `error_id` in
  `stxrApiErrorMessage` and show the error id to the user.
- D. Client, report only what the server cannot see: response decode
  failures (schema drift), unexpected exceptions in client services,
  failures swallowed by `allSettled`, client-side timeouts (15 s). Sent to
  an application-server endpoint (e.g. `POST /api/v0/client-reports`),
  which emits argus events into the same pipeline, rate limited per
  installation and deduplicated by (version, kind, location). Not a
  general log shipper.

## Open questions for the discussion

- Q1. Is "contract violation pages, domain refusal counts" the right line?
  Where do auth failures (signature mismatch, refresh replay) belong:
  security signal that pages, or counted?
- Q2. Do JSON REST routes need the same contract/refusal split as execute,
  or do they go away in favour of execute?
- Q3. Aggregation and alerting: Cloud Monitoring log-based metrics (needs
  JSON log lines in the app-server, see SESS-00QKS30 D7) or notify-gw rules
  over the alerts feed / monitoring NATS (SESS-00QKRBE)? Digest cadence?
- Q4. Client error reports: our own endpoint into argus, or a vendor
  (Sentry) for the client only? Privacy: what may leave a user's machine
  (strategy names, account ids)? Opt-in for beta users?
- Q5. Trace id per user action: who creates it (the UI command layer?),
  how far it propagates (client -> app-server -> internal calls already
  adopt `x-trace-id`).
- Q6. Version skew: should the server reject or flag requests from client
  versions it does not support (minimum version header)?
- Q7. Should per-principal rate anomalies (a client fetching the same 50
  accounts 54 times in 25 min) be a signal here or in the load discussion
  (SESS-00R0CQV covers the DB side only)?
- Q8. How does the beta team triage: Discord channel per severity, a
  daily digest, or Linear issues created from repeated reports?
