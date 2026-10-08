---
create_time: 2026-10-09T10:09:52Z
title: "DEC-0C0TX protocol definition explained and reviewed"
summary: "Explainer notebook `protocol-definition` for DEC-0C0TX (proposed) plus review: TS app server and TS codecs not covered, Tagged wallet sign-in would make the app server stateful (today signed challenge + authChallengeRepo), no digest exchange between peers, macro output unspecified, stale vs forged tags share one error, record_other/discard race, dropped turns, adapter purity, no observability or conformance tests, wire sample fixes; suggested gateway first, Execute later. No user decisions yet."
related_sessions: []
---

# SESS-00Q613G: DEC-0C0TX protocol definition explained and reviewed

The user asked for an explanation of DEC-0C0TX (Protocol definition, proposed
2026-10-01) as a dev-env notebook, followed by suggestions. Notebook:
`.dev-env/data/sessions/sess-00q613g/notebooks/protocol-definition.md` in the
workspace project.

No decisions made by the user yet. Record their answers to the suggestions
below as decisions when they come.

## Facts checked in the code (2026-10-09)

- Execute services today: `ServiceDefinition` / `MethodDefinition` in
  `data-feed-definitions/rust/crates/data-feed-definitions/src/protocol.rs`.
  Methods pair request, response and error shapes; codec named after
  `codec_hex` of the service shape digest.
- Content definitions are `LazyLock<FeedContentDefinition>` statics built at
  run time (for example `authentication/wallet.rs`).
- The Execute server is TypeScript: `structure-web/packages/api`, for example
  `auth/authentication-handler.ts`, using the generated TS codec
  `@structure/content-shape-codec-protobuf-b92bd3265cfe596dd962130224f90d15`.
  Handlers are async and return `Result`.
- Wallet sign-in today: three independent methods (`WalletChallengeCreate`,
  `WalletChallengeVerify`, `SessionRefresh`) failing with
  `AUTHENTICATION_REJECTED` (the DEC example says `EXECUTE_REJECTED`). The
  server returns a signed challenge and verifies through `authChallengeRepo`,
  so any instance can verify.
- Gateway: `client_tag` is `Option<&[u8]>` on every tagged message trait
  (`realtime-gateway/rust/crates/messaging/definition/src/traits.rs`); the
  client uses 8-byte tags (`Tagged { client_tag: [u8; 8] }` in
  `realtime-gateway-client/src/client_protocol.rs`); the client supports
  `cancel_request`. `ServerResponseHeader` has only `client_tag` and
  `payload_len`; `subscription_id` is on `ServerSubscriptionEventHeader`.

## Suggestions given (not decided)

1. Cover TypeScript codecs (the Execute server and its codec are TS), or
   scope the DEC to Rust and keep Execute on `ServiceDefinition` until then.
2. Model wallet sign-in as two `Paired` exchanges; a `Tagged` in-memory
   server table needs sticky routing on the multi-instance app server.
3. Exchange the protocol digest (with side and encoding) once per connection.
4. Say what `#[protocol]` emits (a `ProtocolDefinition` value read by the
   generator); the macro cannot evaluate `LazyLock` content statics.
5. Split `ProtocolViolation::Correlation` into stale and unknown/missing, so
   late replies after a discard or cancel are not alarms.
6. Fix the `record_other` after CAS vs concurrent `discard` race in the
   default table; state the generation width and wrap bound.
7. `#[must_use]` turns and an explicit `abandon`.
8. Adapters take `&self` or are documented as side-effect free.
9. Add observability and a generated conformance property test, loom tests
   for the table.
10. Connection-level protocol error message before closing.
11. Wire sample and naming fixes.
12. Phase: realtime gateway first (Rust on both sides), Execute later.
