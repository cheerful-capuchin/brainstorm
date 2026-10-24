---
create_time: 2026-10-23T16:28:46Z
title: "Layers of a service contract: encoding, meaning, constraints, domain, specification"
summary: "Open, no decisions. Round 4: agent proposes text source + compiled JSON model + checked-in lock file (field ids pinned), separate model/encoding/transport/language-mapping files, generators in Rust for Rust/TS/Python, viewer generated from the compiled model. Round 3: CUE (and Pkl, Nickel) considered as the constraint language; agent: usable only as build-time authoring layer emitting the JSON model, recommends own DSL for contracts and CUE for config files. Round 2 (user direction, not yet a decision): Smithy-style split of model / encoding binding / transport binding in an own DSL, FlatBuffers tables for zero-copy, generate everything but I/O, same IDL for Rust engine services over NATS and later Zenoh (would supersede DEC-0C0TX's rejection of a text DSL and SESS-00QGNFK D18). Agent proposal R2: constraints only on named types, closed data vocabulary (no regex, no CEL), named checks with sample vectors as escape hatch, few cross-field forms, receive pipeline bytes -> verified -> checked view, domain mapping in per-language binding files, operation patterns (paginated, idempotent, unary/stream/event), examples as conformance, DSL emits a JSON model. Round 1: how to split a service contract into layers (transport, encoding, shape, value rules, domain types, rules needing server state, behaviour, protocol, deployment) so clients and servers are generated per language instead of rebuilt per service; market-info-server as the example. Two parallel agent answers (started by mistake in ~/personal/finance, moved here): A proposes protobuf + protovalidate + own domain options + shared google.rpc.Status style error envelope + conformance examples; B builds on the market-info-protocol prototype and DEC-0C0TX, adds protocol/deployment layers and language-neutral byte vector conformance. Findings: undecodable requests never answered, shared reply subject, limit clamped silently, domain types are the wire format. Open: definition form, wire vs domain type, operation patterns, client languages and outside-VPC transport, clamp vs reject limit."
related_sessions:
  - SESS-00Q639F
  - SESS-00Q613G
  - SESS-00QGNFK
  - SESS-00R5V49
  - SESS-00R0CQR
agents:
  - claude-code:a564375e-eba3-43b5-a734-dc64bc05e24e
  - claude-code:31734df2-97d5-42b8-823b-3a9caae8e23e
  - claude-code:03fa3d82-e7b3-4788-9a2c-5bf7e84016cc
---

# SESS-00RBMHY: Layers of a service contract: encoding, meaning, constraints, domain, specification

## Provenance (2026-10-23)

The user started this conversation by mistake in `~/personal/finance`, twice in
parallel (Claude Code sessions a564375e and 31734df2, same prompt 10 s apart).
Both agents wrote to one record in the finance brainstorm; it was moved here the
same day with its ID and create time kept. Answer A below is from a564375e,
answer B from 31734df2. The user pasted answer A back into the workspace.

## Trigger and the user's goals (2026-10-23)

Running example: `market-info/crates/market-info-server`, which serves
`market-info/assets/market-info.rkyv` over NATS request/reply. Its contract
crate `market-info-server-contracts` reuses the `market_info` domain types and
rkyv as the wire format.

The user, in their own terms:
- Every service inside the VPC and outside it must be able to query market info.
- The lines between layers blur: transport encoding, then meaning given to bytes
  (8 bytes are a number, 2 bytes are two flags, 4 bytes length + 20 chars text),
  then domain constraints on top (number within bounds, text length/structure).
- The GCP protobuf APIs are the best example seen so far (secretmanager
  `ListSecretsRequest` with `google.api.field_behavior` and
  `google.api.resource_reference`). Asked whether those annotations change any
  behaviour or act only as comments.
- Wants to stop hand-building request builders, encoders, response decoders and
  parsers for every service in every language.
- On the server side wants to work with domain types (`Venue`, `InstrumentId`,
  `InstrumentType`), not transport messages.
- Transport messages plus comments describe the contract poorly; wants a
  contract stated in a form tools can check, covering everything from invalid
  data to logical errors.

## What the Google annotations do (both answers agree)

Custom protobuf options. They change neither the wire bytes nor the code of the
standard generators; in proto3 a `REQUIRED` field can still be missing. They
matter because Google's tools read them: GAPIC client generators (REQUIRED +
`method_signature` become method parameters, `resource_reference` becomes
resource name helpers), `api-linter` (AIP-203 field behaviour, AIP-122/123
resource names), docs, gcloud, Terraform. The server must still check REQUIRED
and answer `INVALID_ARGUMENT` (AIP-203). google.api has no range or length
rules; Buf's protovalidate adds them as CEL options checked at runtime. The
prose "capped at 25000" on `page_size` is the part no tool sees.

Idea taken: a contract is a schema plus structured claims that generators,
linters and tests read. A claim no tool reads is still a comment.

## Answer A: seven layers, protobuf based (proposed, not accepted)

| # | Layer | Example in market-info | Failure | Who can check |
|---|---|---|---|---|
| 1 | Transport: subject, reply matching, size limit, timeout | request subject, fixed `reply_subject`, `request_id` | no reply, timeout | NATS client |
| 2 | Encoding: bytes to generic values | rkyv | malformed bytes | generated decoder |
| 3 | Shape: fields, types, optionality, enum tags | `limit: u32`, `cursor: Option<…>` | missing field, unknown tag | generated types |
| 4 | Value rules needing no server data: ranges, lengths, patterns, cross-field rules | `limit` 1..=100, cursor text `inst_…` | invalid argument with field path | generated validator on both sides |
| 5 | Domain types: checked values into types that cannot hold wrong values | `InstrumentId`, `Venue` | same as 4 | conversion code once per domain type per language |
| 6 | Rules needing server data: exists, allowed, still valid | cursor names an instrument still present | not found, failed precondition, permission | server only |
| 7 | Behaviour: what the operation means | sorted by `InstrumentId` asc; empty filter = any; AND across fields, OR within one list; `limit` 0 -> 100 | wrong results, no error | conformance tests |

Dividing line: layers 2-5 a client can check before sending with the same
generated code the server runs; 6 needs the server; 7 shows only over many
calls. Layer 7 lives in a conformance suite stored as data (server data fixture,
request, expected response), run against every server and every client; "fields
combine with AND" becomes three examples plus one property test, and the
comment points at them.

Generated per language from one schema file per service:
1. wire types and codec (existing tools);
2. validator from value rule annotations;
3. domain conversion via a custom option such as `(stxr.domain) = "InstrumentId"`
   that calls a conversion function from the domain library;
4. client `list_market_info(filter, limit) -> Result<Page, ListMarketInfoError>`
   that builds, correlates, validates before sending, decodes into domain types;
5. server trait receiving only checked domain values; the generated wrapper does
   decode -> validate -> convert and turns failures into the standard error reply;
6. one error envelope for all services (kind: malformed, invalid argument, not
   found, failed precondition, unavailable, internal; field path; failed rule;
   retryable), copied from `google.rpc.Status` + `BadRequest.FieldViolation`
   (AIP-193).

Cost: a generator once per language; conversion code once per domain type per
language, shared by all services (enums like `Venue` declared once in a shared
schema); per service only the trait implementation and the conformance examples.

Format: protobuf (2-3), protovalidate (4), own options (5), typed errors in a
`oneof` (6), conformance suite (7). Reasons: mature codecs everywhere, protoc
hands plugins the full schema with options, `buf breaking` guards evolution,
works over NATS. Unchecked: whether protovalidate exists for Rust (fallback:
own generator emits the validator). Smithy named as the cleanest model/protocol
split (`@range`, `@length`, `@pattern`, `@required`, `@paginated`, error shapes;
Rust server SDK hands validated values to handlers) but non-HTTP protocols must
be written by hand. Keep rkyv for reading `market-info.rkyv` from disk in Rust;
reference data gains nothing from zero-copy on a list request.

## Answer B: eight layers, building on the prototype (proposed, not accepted)

| Layer | Question | Who checks | Failure class | market-info today |
|---|---|---|---|---|
| Transport | which bytes belong together, who asked, where to reply | framing code | dropped frame, no reply | NATS subject, `request_id` in payload |
| Encoding | bytes to ints, strings, lists, variants | codec | undecodable | rkyv of the Rust type |
| Shape | fields, cardinality, closed enums; encoding neutral | generated code, schema id | schema mismatch | not separate: the Rust struct |
| Value rules | ranges, byte lengths, formats, item counts, "0 means unset" | generated check, same in every language | InvalidRequest with field path | limit clamped silently, nothing else |
| Semantics | what a value denotes (venue specific id, opaque cursor, empty filter = all) | handwritten domain type parsed at the boundary | adapter rejects | domain types are wire types |
| Operation | state dependent rules and promises (cursor issued here, ordered pages, no gaps) | server logic; property tests against a model | InvalidCursor; business failure is a reply | partly SPEC-7.x, partly code only |
| Protocol | who sends what, in which order, correlation | generated state machine | unexpected message | DEC-0C0TX, not applied here |
| Deployment | subjects, auth, payload caps, versions | config | operational | config.yaml |

Principle: each layer fails in its own vocabulary and the server answers at the
layer where the request failed.

Generated per language: codec, shape views and builders, value checks and their
constants, errors with field paths, pager for list operations, correlation
state machine. Handwritten per language: domain types and the shape-to-domain
adapter. Business logic stays in the server.

Cross-language answer is two language-neutral artifacts, not a generator per
language: the contract file and a conformance suite of byte vectors with
expected outcomes (as protobuf's conformance runner and SBE do). A hand-written
Python client is acceptable if it passes the vectors. The prototype already
generates the Rust half. Missing there: operation layer as declared patterns,
a language-neutral export, alignment with DEC-0C0TX (Rust `#[protocol]` macros,
text DSL rejected). The two can coexist if the Rust definition exports a
descriptor manifest as DEC-07NNN plans and the TS generator reads the manifest.

## Difference between A and B to settle

- A generates the shape-to-domain conversion from a `(stxr.domain)` option; B and
  DEC-0C0TX keep that adapter handwritten ("semantic types are never generated").
- A picks protobuf + options; B says protobuf cannot express sequences or
  correlation and leans on the prototype / DEC-0C0TX.
- A's conformance suite is fixture + request + expected response; B's is byte
  vectors with expected outcomes. They can be one suite at two levels.

## Findings in market-info-server (2026-10-23)

- `crates/market-info-server/src/handler.rs:29`: a request that fails to decode is
  logged and dropped. `request_id` is inside the payload, so the server cannot
  address the sender and the client waits for its timeout. Correlation belongs
  outside the payload (NATS header or the per-request `_INBOX` reply subject),
  then unreadable bytes can get a "malformed request" reply. Same conclusion as
  SESS-00R5V49 for sender identity.
- `config/config.yaml:5`: one fixed reply subject, so every client receives every
  reply and filters by `request_id`. Per-request inboxes fix this too.
- `src/logic/list_market_info.rs:60`: `limit` of 0 or above 100 silently becomes
  100; a behaviour rule the contract does not show.
- `InvalidCursor` is the only error; decode and value rule failures have no
  reply shape.
- The contract crate is rkyv of the Rust domain types, fusing encoding, shape,
  value rules and semantics: non-Rust clients must reimplement rkyv's layout,
  `Venue` numbering is already copied by hand into `market-info-core/ts`, and
  any `MarketInfo` field change changes the bytes for every client at once.
  This is where the blurring the user describes comes from.

## Prior work in this workspace

- SESS-00Q639F: user answered Q1 there with wide wire types + SBE-level
  constraints as data (not CUE) + handwritten domain types; built
  `prototypes/market-info-protocol` (text DSL `protocol/market_info.protocol`,
  named types with rules: range, bytes, format, items, unspecified; FlatBuffers
  codec crate named by digest; generated constraint checks and view traits;
  conformance property tests proving domain type == rule; server always replies
  MalformedRequest / InvalidRequest{field, kind} / InvalidCursor). It cites
  DEC-0C0TX but contradicts its Rust-macro definition form.
- DEC-0C0TX Protocol definition (proposed 2026-10-01; reviewed in SESS-00Q613G):
  `#[protocol]` Rust modules with sides, sequences, Tagged/Paired correlation,
  one generated codec crate per side and encoding; adapters map shapes onto
  domain types; rejected a DSL with its own grammar and YAML/TOML.
- DEC-07NNN Canonical Schema Identity: BLAKE3 of an encoding-neutral descriptor
  graph; envelope of schema_id + encoding + payload; checked-in manifest.
- DEC-08NXH: protobuf as interim wire format, rkyv desired, trait-based consumer
  contracts, adapters at the boundary.
- SPEC:market-info-server (draft, gRPC era): numbered behaviour rules (SPEC-7.x
  pagination, SPEC-14.x failures); "protobuf types describe the transport, the
  repository holds the facts".
- SESS-00QGNFK D18: Rust + macros for now, DSL later (feed catalog).
- SESS-00R0CQR: classifying 4xx as contract violation vs domain answer, which the
  error envelope's kinds would carry.

## Open questions

1. Definition form: protobuf + options, Smithy, the prototype's text DSL, or Rust
   `#[protocol]` (DEC-0C0TX) with an exported descriptor manifest.
2. Wire type vs domain type: does every service get a shape distinct from its
   domain, or may Rust-only internal services keep rkyv of the domain type?
3. Domain conversion generated from options (A) or handwritten adapters (B).
4. Which operation rules become declared patterns generators understand: list,
   keyset pagination, closed expansion sets; `limit` outside 1..=100 rejected or
   clamped (would be the first behaviour rule written into the contract).
5. Client languages needed now (Rust, TS, Python?) and whether outside-VPC
   clients reach NATS directly or through an HTTP gateway.
6. Does protovalidate have a usable Rust implementation (unchecked).

## Round 2 (2026-10-23): Smithy-style split, FlatBuffers, NATS and Zenoh

The user, in their own terms (direction, not yet recorded as a decision):
- Liked Smithy's idea. Wants the contract object decoupled from the transport
  and from the encoding.
- Wants FlatBuffers for zero-copy reads; tables are acceptable even with the
  pointer jumps.
- With AI, a custom DSL/IDL is cheap to change or create, so wants to explore
  an own IDL rather than adopt one as is.
- Ideal: generate everything except the I/O. Most generators assume HTTP; our
  services do not. The same IDL must serve the Rust engine services that talk
  over NATS, and Zenoh in the future.
- Asked how the constraints would be built in.

Conflicts to resolve if this becomes a decision: DEC-0C0TX rejected a DSL with
its own grammar (Rust `#[protocol]` macros instead); SESS-00QGNFK D18 chose
"Rust + macros for now, DSL later".

### Agent proposal R2 (not accepted)

Three declarations per service, each owning one concern:
- **Model** (protocol neutral, encoding neutral): named types with constraints,
  enums (closed or open), structures, errors with a category, operations with
  an interaction pattern (unary, stream, event), operation traits (readonly,
  idempotent, paginated), examples. No subjects, no byte layout, no field
  numbers, no payload caps. The prototype's `max_payload_bytes` in the protocol
  header and "field order is the wire order" move out of the model.
- **Encoding binding** (FlatBuffers first): stable field ids, table vs struct
  per shape (structs only for fixed-size shapes that never change), union
  mapping, generated `.fbs`. Other encodings (JSON for web/debug) can be added
  as further bindings of the same model.
- **Transport binding** per transport: NATS subject / Zenoh key expression per
  operation, correlation (NATS per-request inbox, Zenoh query id), where
  metadata goes (NATS headers, Zenoh attachment), payload cap, default timeout.
  Encoding is fixed per subject/key, never sniffed (one shape per subscription).
  Because every string and list is bounded, the generator can compute the
  largest encoded message and refuse a binding whose cap is smaller.

Constraints:
- Only on named types (refinement types), never on fields; each named type
  becomes a newtype in every language whose only constructor checks the rule.
  Same as the prototype and as smithy-rs "constrained types".
- Closed vocabulary stored as data, compiled by each generator to native code:
  range, unspecified/default, bytes (UTF-8 length), items, unique, format
  (named character classes, no regex: regex dialects differ across languages),
  closed/open enum. Cross-field rules limited to a few structural forms
  (exactly_one_of, at_most_one_of, requires, ordered a <= b).
- Escape hatch: a named check (`check: <name>`) implemented by hand per
  language, with valid/invalid sample vectors in the model that every
  implementation must pass. Every constraint carries samples, built-in or not.
- Rejected by the agent: CEL (a runtime per language, generators cannot reason
  about it); matches the user's SESS-00Q639F answer "constraints as data".
- Because constraints are data, the same rules also generate property test
  generators, docs, max message sizes, and a breaking-change check (request
  rules may only widen, response rules may only narrow).

Receive pipeline (Rust, zero-copy): bytes -> transport frame (correlation and
size outside the payload) -> FlatBuffers verifier (offsets in bounds, required
fields, UTF-8) -> `Verified<'a, T>` -> one constraint pass collecting a bounded
number of violations with field paths -> `Checked<'a, T>`; handler sees view
traits whose accessors return borrowed refined types infallibly. Zero-copy is
zero allocation, not zero work: the check walks the buffer once; lazy checks
on access rejected because errors would surface inside business logic. Send
side: builders accept only refined types, so invalid messages cannot be built.

FlatBuffers details that reach the model: enums are open on the wire (unknown
values pass the verifier, the check step rejects them unless the enum is open);
absent vs default needs `= null` optional scalars; no canonical encoding, so
never hash or compare FlatBuffers bytes (DEC-07NNN hashes the model descriptor);
field ids must be stable and explicit.

Domain types: the model names a type; a per-language binding file maps it to a
domain type (`InstrumentId -> market_info_core::InstrumentId`). The generator
emits a conversion call through a trait the domain crate implements; without a
mapping the generated refined newtype is the domain type. The sample vectors
prove the handwritten conversion agrees with the rule. This reconciles answers
A (generated conversion) and B (handwritten domain types). Owned domain types
(String) cost a copy; borrowed refined types keep zero-copy.

Operations: errors declared per operation with a category (client, state,
server) and retryable flag, all sharing one error envelope; `paginated` names
cursor/next/items/size so generators emit a pager and conformance cases (walk
all pages = full list, no duplicates); `idempotent` allows client retries;
`examples` (fixture, input, expected output or error) run in every language over
an in-memory transport; per-binding byte tests like Smithy protocol tests.

Generated vs handwritten: generated per language are refined types, codec,
views, builders, checks, errors, sans-I/O client (`OutgoingRequest`/incoming
reply) and sans-I/O server dispatcher, pager, conformance runner. Handwritten
once per transport per language: the I/O adapter (NATS Rust, NATS TS, Zenoh
Rust). Handwritten per service: handler and fixtures.

IDL choice: keep the own DSL (prototype parser exists and already forbids
unbounded strings/lists, recursion, regex), copy Smithy's model semantics and
trait split, and have the DSL compile to a JSON model that every generator in
any language reads (also the descriptor graph DEC-07NNN hashes). Alternative
named: Smithy IDL itself plus custom traits and own generators reading its JSON
AST; costs a JVM build tool and validators to forbid what Smithy allows
(unbounded strings, recursive shapes, `document`, ECMA regex).

Open after R2:
- Supersede DEC-0C0TX's definition form with the DSL, or keep `#[protocol]`.
- `limit`: model default 100 and reject outside 1..=100 (proposed) vs clamp.
- Whether trusted internal hot paths may skip the constraint pass (deployment
  setting, not model).
- Stream pattern over NATS needs an end-of-stream frame; Zenoh queryables give
  multiple replies natively.

## Round 3 (2026-10-23): CUE as the constraint language?

The user asked about a Go language "like KDL or CDL" that handles data and
constraints and is used for configs; that is CUE. CUE was already discussed in
SESS-00Q639F (agent recommended SBE-level rules over CUE, not decided).

Agent answer (not accepted):
- KDL is a document format (Zellij configs), with no real constraint support.
  CUE (Go) unifies types, constraints and data; Pkl (Apple, JVM/native, type
  constraints like `Int(isBetween(1, 100))`) and Nickel (Rust, contracts) are
  the same family.
- All of them check data inside their own evaluator, at build or config load
  time. None emits validators for Rust/TS code, and message checks must run in
  each service at runtime. Only CUE's Go evaluator is official.
- Possible use: CUE as the authoring language only, with a Go build step that
  walks the CUE values and emits the JSON model; a linter rejects any CUE
  constraint outside the closed vocabulary (regex, arbitrary expressions,
  disjunctions beyond enums). The SESS-00Q639F objection (no CUE runtime in
  Rust/TS/WASM) then no longer applies, because nothing at runtime runs CUE.
- Costs: a Go step in every build, using a small subset of CUE, constraints are
  read via the Go API (`cue export` gives concrete data, not the bounds), and
  bindings (subjects, field ids) are awkward in CUE.
- Recommendation: keep the own DSL for contracts; CUE fits service config files
  (config.yaml checks) better than message contracts.

## Round 4 (2026-10-23): what the DSL looks like, text or binary source

The user: wants to define the model in a DSL, add encoding-specific rules only
where needed, and generate Rust, TypeScript and Python types for the model plus
Rust, TypeScript and Python clients. Most model implementation will be in Rust.
Asked whether the source must be text or could be a binary file with a viewer
or an IDE plugin; sees little value in text except for agents and merge
conflicts.

Agent proposal R4 (not accepted):
- Text is the source; a compiled model (JSON) is the artifact every generator,
  the compatibility checker and a viewer read. Reasons for text: contract
  changes are reviewed in GitHub PRs, which cannot render a binary diff; merges
  of two branches adding operations work line by line, binary needs a merge
  driver in every tool; agents read and edit text directly; doc comments sit
  next to definitions; search works. Binary would need an editor, viewer, diff
  driver, merge driver and IDE plugin; text needs the existing parser, a
  formatter and optionally an LSP + tree-sitter grammar. Visualisation is
  generated from the compiled model (HTML docs, diagrams), not a source.
- Files per service: model (`market_info.stxr`), optional encoding overrides
  (`market_info.flatbuffers.stxr`), transport bindings
  (`market_info.nats.stxr`, later zenoh), per-language type mappings
  (`map rust { InstrumentId = market_info_core::InstrumentId }`), and a
  generated lock file checked in (`market_info.lock.json`: FlatBuffers field
  ids, enum values, schema ids, model hash), like Cargo.lock. Field ids are
  assigned on first compile and pinned in the lock, so encoding rules are
  written only to override defaults (struct instead of table, reserved ids).
  The compatibility check compares against main's lock.
- Shared types (Venue, InstrumentType, Decimal) live in a shared package
  (`stxr.common`) imported by services, so enum numbering is defined once.
- Operation input/output declared inline; `examples` blocks become the
  conformance suite.
- Generators written in Rust (one binary, one backend per language) reading the
  compiled model. Rust: one sans-I/O contract crate per service. TS: branded
  types with parse functions, u64 as bigint, flatbuffers TS runtime. Python:
  frozen dataclasses with checks, flatbuffers Python runtime.
- Alternative named: generate only Rust and expose it to TS (WASM) and Python
  (PyO3); one implementation, but per-platform wheels, a WASM bundle in the web
  client and copies at the FFI boundary. Agent prefers native TS/Python
  generation kept in line by the shared conformance vectors.
